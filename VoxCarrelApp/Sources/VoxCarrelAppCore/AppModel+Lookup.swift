import Foundation
import VoxCarrelCore

// Looking a book up online (plan 5, Task 5). A1–A8.
//
// A lookup only ever reads from the network and changes an unsaved draft or an entry of
// an import being reviewed: nothing here writes to the library, the files or the journal.

/// An Audible store as the settings list it.
public struct AudibleStoreChoice: Identifiable, Equatable, Sendable {
    public var store: AudibleStore
    /// The country's name: "United Kingdom".
    public var title: String

    public var id: AudibleStore { store }
}

extension AppModel {
    // MARK: Whether a lookup can begin

    /// A1: whether the inspected book can be looked up: a library is open, exactly one
    /// book is inspected, nothing is running, and no question or other sheet is in the way.
    public var canLookUp: Bool {
        guard case .one = inspecting else { return false }
        return isQuietForLookup && review == nil && result == nil && libraryCheck == nil
    }

    /// A2: whether this entry of the import being reviewed can be looked up.
    public func canLookUpEntry(_ id: UUID) -> Bool {
        isQuietForLookup && review?.entry(id) != nil
    }

    private var isQuietForLookup: Bool {
        isLibraryOpen && busyLabel == nil && storedPrompt == nil && lookup == nil
    }

    /// The lookup when it is for the inspected book: its sheet belongs to the window.
    public var inspectorLookup: LookupSession? {
        if case .book = lookup?.target { return lookup }
        return nil
    }

    /// The lookup when it is for an import entry: its sheet belongs over the import sheet.
    public var importLookup: LookupSession? {
        if case .importEntry = lookup?.target { return lookup }
        return nil
    }

    // MARK: The sources, in words

    /// "Results from Open Library and Audible (United Kingdom)"
    public var lookupSourcesText: String {
        "Results from \(LookupSource.openLibrary.title) and \(LookupSource.audible.title) (\(audibleStore.title))"
    }

    /// The Audible stores for the settings, by country name.
    public static let audibleStoreChoices: [AudibleStoreChoice] = AudibleStore.allCases
        .map { AudibleStoreChoice(store: $0, title: $0.title) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

    // MARK: Beginning

    /// A1: opens a lookup for the inspected book, with the draft's values as they are
    /// now, typing not yet saved included, and searches at once unless there is nothing
    /// to search for. Does nothing unless `canLookUp`.
    public func beginLookup() {
        guard canLookUp, case .one(let detail, let draft) = inspecting else { return }
        open(
            LookupSession(
                target: .book(detail.row.id), current: draft.typedMetadata, hasCover: draftCover != .none,
                hasAudio: detail.row.hasAudio))
    }

    /// A2: the same for an entry of the import being reviewed, with its details and cover.
    public func beginLookup(forEntry id: UUID) {
        guard canLookUpEntry(id), let entry = review?.entry(id) else { return }
        open(
            LookupSession(
                target: .importEntry(id), current: entry.candidate.metadata, hasCover: entry.cover != nil,
                hasAudio: entry.hasAudio))
    }

    private func open(_ session: LookupSession) {
        lookupGeneration += 1
        forgetLookupThumbnails()
        lookup = session
        startLookupSearch()
    }

    // MARK: Searching

    /// Changes what will be searched for. A search that is running is for the query as
    /// it was: it is cancelled, and the sheet waits for Search.
    public func updateLookupQuery(_ change: (inout LookupQuery) -> Void) {
        guard var session = lookup, session.phase != .applying else { return }
        let before = session.query
        change(&session.query)
        guard session.query != before else { return }
        lookupSearch?.cancel()
        lookup = session
    }

    /// A3: searches every source for the query as it is now, and returns when they have
    /// answered. A search already running is superseded. With nothing to search for,
    /// nothing is asked.
    ///
    /// The sheet shows its own progress (`lookup.phase`): `busyLabel` is not set, and
    /// the library goes on answering meanwhile.
    public func searchLookup() async {
        guard let search = startLookupSearch() else { return }
        await search.value
    }

    @discardableResult
    private func startLookupSearch() -> Task<Void, Never>? {
        guard let worker, var session = lookup, session.phase != .applying, !session.query.isEmpty else { return nil }
        lookupSearch?.cancel()
        session.beginSearch()
        lookup = session
        let query = session.query
        let preferAudio = session.preferAudio
        let language = lookupLanguage
        let generation = lookupGeneration
        let search = spawn {
            let results = await worker.lookUp(query, preferAudio: preferAudio, language: language)
            // A cancelled search comes back looking like one that found nothing, and
            // this may no longer be the lookup, or the query, it was made for (K2).
            guard !Task.isCancelled, self.lookupGeneration == generation, var session = self.lookup,
                  session.query == query
            else { return }
            session.finishSearch(results, for: query)
            self.lookup = session
            await self.fetchLookupDetails()
        }
        lookupSearch = search
        return search
    }

    // MARK: Choosing

    /// Selects one of the results (nil for none), and fetches anything more its source
    /// has about it (K7).
    public func selectLookupCandidate(_ id: String?) async {
        guard var session = lookup else { return }
        session.select(id)
        lookup = session
        await fetchLookupDetails()
    }

    /// More about the selected candidate, when its source has more. What cannot be
    /// fetched is simply not offered.
    private func fetchLookupDetails() async {
        guard let worker, let session = lookup, session.phase == .results, let candidate = session.selected,
              candidate.hasMoreDetails
        else { return }
        let generation = lookupGeneration
        guard let detailed = try? await worker.lookupDetails(for: candidate) else { return }
        guard lookupGeneration == generation, var session = lookup else { return }
        // Ignored by the session when another candidate has been selected meanwhile.
        session.replaceSelected(with: detailed)
        lookup = session
    }

    public func setLookupTicked(_ ticked: Bool, for field: MetadataField) {
        guard var session = lookup else { return }
        session.setTicked(ticked, for: field)
        lookup = session
    }

    // MARK: Applying and closing

    static let coverNotDownloaded = "The cover could not be downloaded."

    /// A4: puts the ticked values where the lookup was begun: into the inspected book's
    /// draft, as if they had been typed, or into the import entry. Nothing is saved or
    /// imported by this. A ticked cover is downloaded first; if it cannot be, the other
    /// values are still applied and `alert` says so. The lookup then closes.
    ///
    /// Does nothing unless `lookup.canApply`. While the cover is on its way
    /// `lookup.phase` is `.applying`, and nothing about the lookup can be changed; if it
    /// closes meanwhile, nothing is applied.
    public func applyLookup() async {
        guard var session = lookup, session.canApply, let candidate = session.selected else { return }
        let (metadata, wantsCover) = session.applied()
        let fields = session.tickedFields
        let target = session.target

        var cover: CoverImage?
        if wantsCover {
            guard let worker else { return }
            lookupSearch?.cancel()
            session.beginApplying()
            lookup = session
            let generation = lookupGeneration
            cover = try? await worker.lookupCover(for: candidate)
            // A5: closed meanwhile, whatever is open now.
            guard lookupGeneration == generation, lookup != nil else { return }
        }

        switch target {
        case .book(let id):
            guard case .one(let detail, _) = inspecting, detail.row.id == id else { break }
            updateDraft { $0.take(fields, from: metadata) }
            if let cover { setCover(data: cover.data) }
        case .importEntry(let id):
            updateReview { review in
                review.update(id) { entry in
                    entry.candidate.metadata.take(fields, from: metadata)
                    if let cover {
                        entry.cover = cover
                        entry.coverChanged = true
                    }
                }
            }
        }
        closeLookup()
        if wantsCover, cover == nil {
            alert = fields == [.cover]
                ? Self.coverNotDownloaded : Self.coverNotDownloaded + " The other details were applied."
        }
    }

    /// A6: closes the lookup and applies nothing. A search still running is cancelled.
    public func cancelLookup() {
        closeLookup()
    }

    func closeLookup() {
        lookupSearch?.cancel()
        lookupSearch = nil
        guard lookup != nil else { return }
        lookupGeneration += 1
        forgetLookupThumbnails()
        lookup = nil
    }

    /// A5: the lookup closes, and nothing is applied, when the book it was for is no
    /// longer the one book inspected, or the entry it was for is no longer under review.
    func closeLookupIfItsTargetHasGone() {
        switch lookup?.target {
        case .book(let id):
            if case .one(let detail, _) = inspecting, detail.row.id == id { return }
        case .importEntry(let id):
            if review?.entry(id) != nil { return }
        case nil:
            return
        }
        closeLookup()
    }
}

extension BookMetadata {
    /// Takes the values of `fields` from `other`, and leaves everything else alone.
    mutating func take(_ fields: [MetadataField], from other: BookMetadata) {
        for field in fields {
            switch field {
            case .title: title = other.title
            case .subtitle: subtitle = other.subtitle
            case .authors: authors = other.authors
            case .narrators: narrators = other.narrators
            case .series: series = other.series
            case .seriesNumber: seriesNumber = other.seriesNumber
            case .genre: genre = other.genre
            case .year: year = other.year
            case .publisher: publisher = other.publisher
            case .summary: summary = other.summary
            case .language: language = other.language
            case .isbn: isbn = other.isbn
            case .asin: asin = other.asin
            // A cover is not part of the details.
            case .cover: break
            }
        }
    }
}

extension BookDraft {
    /// The book's details as the draft's fields say them now, saved or not. A year that
    /// is not a year is none. The length and page count are the book's own.
    var typedMetadata: BookMetadata {
        var metadata = original.metadata
        metadata.title = title.trimmed
        metadata.subtitle = subtitle.trimmedOrNil
        metadata.authors = NameListText.names(from: authors)
        metadata.narrators = NameListText.names(from: narrators)
        metadata.series = series.trimmedOrNil
        metadata.seriesNumber = seriesNumber.trimmedOrNil
        metadata.genre = genre.trimmedOrNil
        if case .year(let value) = YearText(year) { metadata.year = value } else { metadata.year = nil }
        metadata.publisher = publisher.trimmedOrNil
        metadata.summary = summary.trimmedOrNil
        metadata.language = language.trimmedOrNil
        metadata.isbn = isbn.trimmedOrNil
        metadata.asin = asin.trimmedOrNil
        return metadata
    }

    /// Puts the values of `fields` from `metadata` into the draft's fields, as text.
    mutating func take(_ fields: [MetadataField], from metadata: BookMetadata) {
        for field in fields {
            switch field {
            case .title: title = metadata.title
            case .subtitle: subtitle = metadata.subtitle ?? ""
            case .authors: authors = NameListText.text(from: metadata.authors)
            case .narrators: narrators = NameListText.text(from: metadata.narrators)
            case .series: series = metadata.series ?? ""
            case .seriesNumber: seriesNumber = metadata.seriesNumber ?? ""
            case .genre: genre = metadata.genre ?? ""
            case .year: year = metadata.year.map(String.init) ?? ""
            case .publisher: publisher = metadata.publisher ?? ""
            case .summary: summary = metadata.summary ?? ""
            case .language: language = metadata.language ?? ""
            case .isbn: isbn = metadata.isbn ?? ""
            case .asin: asin = metadata.asin ?? ""
            // The cover is set through the model, which checks the image.
            case .cover: break
            }
        }
    }
}

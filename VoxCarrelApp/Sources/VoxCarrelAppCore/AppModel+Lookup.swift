import Foundation
import VoxCarrelCore

// Looking a book up online (plan 5, Task 5). A1–A8.
//
// Beginning, searching, selecting, ticking and cancelling only ever read from the network:
// nothing is written by them. Applying puts the ticked values into the inspected book's
// draft and saves it, as Save does, or into an entry of an import being reviewed, which
// is written when the import is.

/// An Audible store as the settings list it.
public struct AudibleStoreChoice: Identifiable, Equatable, Sendable {
    public var store: AudibleStore
    /// The country's name: "United Kingdom".
    public var title: String

    public var id: AudibleStore { store }
}

/// A lookup source as the settings list it (A8b).
public struct LookupSourceRow: Identifiable, Equatable, Sendable {
    public var source: LookupSource
    /// "Library of Congress"
    public var title: String
    /// What it is good for: "Cassette and CD editions with their narrators".
    public var detail: String
    /// A second line, for a source there is something to warn about (A8c); nil otherwise.
    public var note: String?
    public var isOn: Bool

    public var id: LookupSource { source }
}

/// An Audible store as the settings' list of stores to search shows it (A8).
public struct AudibleStoreRow: Identifiable, Equatable, Sendable {
    public var store: AudibleStore
    /// The country's name: "United Kingdom".
    public var title: String
    /// Whether lookups search it.
    public var isOn: Bool
    /// The user's own store: always searched, and not to be switched off here.
    public var isOwn: Bool
    /// Whether its tick can be changed: Audible is on, and it is not the user's own.
    public var isEnabled: Bool

    public var id: AudibleStore { store }
}

extension AudibleStore {
    /// A6: the store as a result's row names it: "US", "UK", "Australia".
    public var shortTitle: String {
        switch self {
        case .us: "US"
        case .uk: "UK"
        default: title
        }
    }
}

extension LookupSource {
    /// A8b: what the source is good for, in a line.
    public var detail: String {
        switch self {
        case .openLibrary: "Books and their print and audio editions; covers"
        case .audible: "Audiobook editions, narrators, series and covers"
        case .libraryOfCongress: "Cassette and CD editions with their narrators"
        }
    }

    /// The source in the middle of a sentence: "the Library of Congress".
    var nameInSentence: String {
        self == .libraryOfCongress ? "the \(title)" : title
    }
}

extension LookupCandidate {
    /// The Audible store the result's ASIN belongs to: the first of the stores that
    /// list it. Nil for a result of another source, or of a store this version does
    /// not know.
    public var audibleStore: AudibleStore? {
        guard source == .audible else { return nil }
        if let first = edition.stores.first.flatMap(AudibleStore.init(rawValue:)) { return first }
        // "audible:<store>:<asin>"
        let parts = id.split(separator: ":")
        return parts.count == 3 ? AudibleStore(rawValue: String(parts[1])) : nil
    }

    /// A6: the stores that list the result, "US, UK, Australia", when that is more
    /// than the user's own store; nil for a result only their own store lists, and for
    /// a result of another source.
    public func storesText(own: AudibleStore) -> String? {
        let stores = edition.stores.compactMap(AudibleStore.init(rawValue:))
        guard source == .audible, !stores.isEmpty, stores != [own] else { return nil }
        return stores.map(\.shortTitle).joined(separator: ", ")
    }
}

extension AppModel {
    // MARK: Whether a lookup can begin

    static let noLookupSourceReason = "Turn on a lookup source in Settings."
    static let noAudibleReason = "Turn on Audible as a lookup source in Settings."

    /// A1: whether the inspected book can be looked up: a library is open, exactly one
    /// book is inspected, a lookup source is on (A8b), nothing is running, and no
    /// question or other sheet is in the way.
    public var canLookUp: Bool {
        guard case .one = inspecting else { return false }
        return isQuietForLookup && canAskLookupSources && review == nil && result == nil && libraryCheck == nil
    }

    /// A8b: why Look Up cannot be used whatever is selected: every lookup source is
    /// off. Nil when one is on.
    public var lookUpDisabledReason: String? {
        canAskLookupSources ? nil : Self.noLookupSourceReason
    }

    /// A8b: why Add Audible Book cannot be used whatever else is so: Audible is off.
    /// Nil when it is on.
    public var addAudibleBookDisabledReason: String? {
        lookupSources.contains(.audible) ? nil : Self.noAudibleReason
    }

    /// A2: whether this entry of the import being reviewed can be looked up.
    ///
    /// Not an entry whose files are to join a book already in the library: that book
    /// keeps its own details, and anything found for the entry would be thrown away.
    public func canLookUpEntry(_ id: UUID) -> Bool {
        guard isQuietForLookup, canAskLookupSources, let entry = review?.entry(id) else { return false }
        return !entry.isAddedToExisting
    }

    var isQuietForLookup: Bool {
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

    /// The sources a search of the open lookup asks, in the order they are asked: the
    /// ones that are on, or Audible alone when an Audible book is being added.
    private var askedSources: [LookupSource] {
        LookupSource.allCases.filter { source in
            lookupSources.contains(source) && (lookup?.sources?.contains(source) ?? true)
        }
    }

    /// Where results come from, "Results from Open Library and Audible (UK, US,
    /// Australia)", and once a search has finished what each source made of it:
    /// "Open Library: no matches · Audible (UK, US, Australia): 2 matches".
    ///
    /// A7: a source that found nothing read by the book's narrator and searched again
    /// without the name says so: "nothing read by Frank Muller; showing other editions".
    public var lookupSourcesText: String {
        guard let outcomes = lookup?.outcomes, !outcomes.isEmpty else {
            let names = askedSources.map(sourceName)
            return names.isEmpty ? "No lookup source is turned on" : "Results from \(Self.list(names))"
        }
        return outcomes.map { outcome in
            let said: String
            if let failure = outcome.failure {
                said = UserMessage.shortText(for: failure)
            } else if let narrator = outcome.narratorNotFound, outcome.found > 0 {
                said = "nothing read by \(narrator); showing other editions"
            } else {
                switch outcome.found {
                case 0: said = "no matches"
                case 1: said = "1 match"
                default: said = "\(outcome.found) matches"
                }
            }
            return "\(sourceName(outcome.source)): \(said)"
        }.joined(separator: " · ")
    }

    /// "Open Library", "Audible (United Kingdom)", "Audible (UK, US, Australia)"
    private func sourceName(_ source: LookupSource) -> String {
        switch source {
        case .openLibrary, .libraryOfCongress: return source.title
        case .audible:
            let stores = audibleStores
            let named = stores.count == 1 ? audibleStore.title : stores.map(\.shortTitle).joined(separator: ", ")
            return "\(source.title) (\(named))"
        }
    }

    /// "a", "a and b", "a, b and c".
    nonisolated static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A6: the stores that list a result, for its row: "US, UK, Australia"; nil when
    /// only the user's own store does.
    public func lookupStoresText(for candidate: LookupCandidate) -> String? {
        candidate.storesText(own: audibleStore)
    }

    /// A6: what a result's row is marked with: "Your edition", "Different edition", or nil.
    public func lookupBadgeText(for candidate: LookupCandidate) -> String? {
        lookup?.badgeText(for: candidate.id)
    }

    /// A6: why a result is marked "Different edition", for the badge's tooltip.
    public func lookupBadgeHelp(for candidate: LookupCandidate) -> String? {
        lookup?.badgeHelp(for: candidate.id)
    }

    // MARK: A8 The settings

    static let unencryptedNote =
        "Searches to this source are sent unencrypted, so the title, author or ISBN you look up can be seen on your network."

    /// A8b: one row for each lookup source, with what it is good for and whether it is
    /// on. A8c: the Library of Congress carries a second line.
    public var lookupSourceRows: [LookupSourceRow] {
        LookupSource.allCases.map { source in
            LookupSourceRow(
                source: source, title: source.title, detail: source.detail,
                note: source == .libraryOfCongress ? Self.unencryptedNote : nil, isOn: lookupSources.contains(source))
        }
    }

    /// A8b: turns a lookup source on or off.
    public func setLookupSource(_ source: LookupSource, on: Bool) {
        var sources = lookupSources
        if on { sources.insert(source) } else { sources.remove(source) }
        lookupSources = sources
    }

    /// A8: the Audible stores, by country name, each with whether lookups search it.
    /// The user's own store is always searched. A8b: with Audible off the list is
    /// shown disabled.
    public var audibleStoreRows: [AudibleStoreRow] {
        let searched = Set(audibleStores)
        let audibleIsOn = lookupSources.contains(.audible)
        return Self.audibleStoreChoices.map { choice in
            let isOwn = choice.store == audibleStore
            return AudibleStoreRow(
                store: choice.store, title: choice.title, isOn: searched.contains(choice.store), isOwn: isOwn,
                isEnabled: audibleIsOn && !isOwn)
        }
    }

    /// A8b: whether the Audible stores list can be changed: Audible is on.
    public var audibleStoresAreEnabled: Bool {
        lookupSources.contains(.audible)
    }

    /// A8: has lookups search this store too, or no longer. The user's own store is
    /// always searched: switching it off here does nothing.
    public func setAudibleStore(_ store: AudibleStore, searched: Bool) {
        var others = otherAudibleStores
        if searched { others.insert(store) } else { others.remove(store) }
        otherAudibleStores = others
    }

    /// A8, A8b, A8c: what the settings say a lookup sends, and where from it fetches,
    /// naming only the sources that are on.
    public var lookupPrivacyText: String {
        Self.lookupPrivacyText(for: lookupSources)
    }

    static func lookupPrivacyText(for sources: Set<LookupSource>) -> String {
        let on = LookupSource.allCases.filter(sources.contains)
        guard !on.isEmpty else { return "Look Up is off. Turn on a lookup source to use it." }
        var text = "Look Up sends the title, author, narrator, ISBN or Audible ID you search for to "
            + list(on.map(\.nameInSentence))
        // The Library of Congress has no covers.
        let covers = on.filter { $0 != .libraryOfCongress }.map(\.title)
        if !covers.isEmpty { text += ", and downloads cover images from \(list(covers))" }
        text += ". Nothing is sent until you press Look Up."
        if sources.contains(.libraryOfCongress) { text += " Searches to the Library of Congress are not encrypted." }
        return text
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
        // A year that is not a year is no year in the details, but it is in the field.
        var typed: [MetadataField: String] = [:]
        if YearText(draft.year) == .invalid { typed[.year] = draft.year }
        open(
            LookupSession(
                target: .book(detail.row.id), current: draft.typedMetadata, hasCover: draftCover != .none,
                hasAudio: detail.row.hasAudio, typed: typed,
                // What results are judged against: the measured length, and the edition as the draft has it.
                audioSeconds: detail.row.measuredAudioSeconds, editionKind: draft.editionKind,
                partsAppearMissing: detail.row.book.partsAppearMissing))
    }

    /// A2: the same for an entry of the import being reviewed, with its details and cover.
    public func beginLookup(forEntry id: UUID) {
        guard canLookUpEntry(id), let entry = review?.entry(id) else { return }
        open(
            LookupSession(
                target: .importEntry(id), current: entry.candidate.metadata, hasCover: entry.cover != nil,
                hasAudio: entry.hasAudio,
                // The measured length of its audio, when that is known (`measuredAudioSeconds`).
                audioSeconds: entry.measuredAudioSeconds))
    }

    func open(_ session: LookupSession) {
        lookupGeneration += 1
        forgetLookupThumbnails()
        lookup = session
        startLookupSearch()
    }

    // MARK: Searching

    /// Changes what will be searched for. A search that is running is for the query as
    /// it was: it is cancelled, and the sheet waits for Search. More that is on its way
    /// about a result still shown is not cancelled.
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
    /// Nothing is asked, either, when the results shown are already every source's
    /// answer to this query (`lookup.canSearch`): Return in a search box must not throw
    /// away what has been selected and ticked. A search that found nothing, or that a
    /// source failed to answer, can be made again.
    ///
    /// The sheet shows its own progress (`lookup.phase`): `busyLabel` is not set, and
    /// the library goes on answering meanwhile.
    public func searchLookup() async {
        guard lookup?.canSearch == true, let search = startLookupSearch() else { return }
        await search.value
    }

    @discardableResult
    func startLookupSearch() -> Task<Void, Never>? {
        guard let worker, var session = lookup, session.phase != .applying, !session.query.isEmpty else { return nil }
        lookupSearch?.cancel()
        session.beginSearch()
        lookup = session
        let query = session.query
        let preferAudio = session.preferAudio
        let language = lookupLanguage
        // N1: an Audible book is looked for in Audible alone.
        let sources = session.sources
        // What the results are judged and ranked against.
        let book = session.bookContext
        let generation = lookupGeneration
        let search = spawn {
            let results = await worker.lookUp(
                query, preferAudio: preferAudio, language: language, sources: sources, book: book)
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

    /// More about the selected candidate, when its source has more; returns when it has
    /// arrived. What cannot be fetched is simply not offered, and is asked for again
    /// when the candidate is next selected.
    ///
    /// Each request is a task of its own, one for a candidate at a time: a search that
    /// is cancelled or superseded does not take it down.
    private func fetchLookupDetails() async {
        guard let worker, let session = lookup, session.phase == .results, let candidate = session.selected,
              candidate.hasMoreDetails
        else { return }
        let id = candidate.id
        if let running = lookupDetailLoads[id] {
            await running.value
            return
        }
        let generation = lookupGeneration
        let load = spawn {
            let detailed = try? await worker.lookupDetails(for: candidate)
            guard self.lookupGeneration == generation else { return }
            self.lookupDetailLoads[id] = nil
            guard let detailed, var session = self.lookup else { return }
            // Ignored by the session when another candidate has been selected meanwhile.
            session.replaceSelected(with: detailed)
            self.lookup = session
        }
        lookupDetailLoads[id] = load
        await load.value
    }

    /// A3: ticks or unticks a value of the selected result. Ticking it unticks the
    /// same value on every other result.
    public func setLookupTicked(_ ticked: Bool, for field: MetadataField) {
        guard var session = lookup else { return }
        session.setTicked(ticked, for: field)
        lookup = session
    }

    /// Ticks or unticks the edition offer.
    public func setLookupEditionTicked(_ ticked: Bool) {
        guard var session = lookup else { return }
        session.setEditionTicked(ticked)
        lookup = session
    }

    /// A4: what Apply will take, across results; nil when nothing is ticked.
    public var lookupApplySummary: String? {
        lookup?.applySummary
    }

    // MARK: Applying and closing

    static let coverNotDownloaded = "The cover could not be downloaded."
    static let appliedNotSaved =
        "The details were applied but not saved, because something else was running. Press Save to save them."

    /// A4: puts the ticked values where the lookup was begun: into the inspected book's
    /// draft, as if they had been typed, or into the import entry. A ticked cover is
    /// downloaded first; if it cannot be, the other values are still applied and `alert`
    /// says so. The lookup then closes.
    ///
    /// For a book in the library the draft is then saved, exactly as `save()` saves it:
    /// anything typed before the lookup goes with it, as the one operation Undo reverses.
    /// When it cannot be saved (the draft has a problem, something else is running) or
    /// the save fails, what was applied stays in the draft as unsaved edits and `alert`
    /// or `result` says why. Nothing is imported by applying to an import entry.
    ///
    /// Does nothing unless `lookup.canApply`. While the cover is on its way
    /// `lookup.phase` is `.applying`, and nothing about the lookup can be changed; if it
    /// closes meanwhile, nothing is applied. The lookup has closed before the save
    /// begins: from then on `busyLabel` is the progress shown.
    public func applyLookup() async {
        guard var session = lookup, session.canApply else { return }
        // A5: every ticked value, from whichever result it is ticked on.
        let applied = session.applied()
        let metadata = applied.metadata
        let fields = applied.fields
        let wantsCover = applied.wantsCover
        let target = session.target

        var cover: CoverImage?
        // A5: the cover of the result whose cover is ticked.
        if let candidate = applied.coverCandidate {
            // The row's picture, when it is the cover itself, has been fetched already.
            if let url = candidate.coverURL, let data = lookupThumbnails[url] {
                cover = Self.coverImage(data)
            } else {
                guard let worker else { return }
                lookupSearch?.cancel()
                session.beginApplying()
                lookup = session
                let generation = lookupGeneration
                cover = try? await worker.lookupCover(for: candidate)
                // A5: closed meanwhile, whatever is open now.
                guard lookupGeneration == generation, lookup != nil else { return }
                // The cover could not be had: the smaller picture of it is better than none.
                if cover == nil, let data = cachedLookupThumbnail(for: candidate) { cover = Self.coverImage(data) }
            }
        }

        var savesDraft = false
        switch target {
        case .book(let id):
            guard case .one(let detail, _) = inspecting, detail.row.id == id else { break }
            updateDraft {
                $0.take(fields, from: metadata)
                // In the catalogue only, and as it was found: not the user's own word.
                if let kind = applied.editionKind { $0.editionKind = kind }
            }
            if let cover { setCover(data: cover.data) }
            savesDraft = true
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
        case .newAudibleBook:
            // Nothing is offered or ticked for a book that is being added (`canApply` is false).
            break
        }
        closeLookup()
        var coverProblem: String?
        if wantsCover, cover == nil {
            coverProblem = fields == [.cover] && applied.editionKind == nil
                ? Self.coverNotDownloaded : Self.coverNotDownloaded + " The other details were applied."
            alert = coverProblem
        }
        if savesDraft { await saveAppliedLookup(after: coverProblem) }
    }

    /// Saves the draft a lookup has just been applied to. `coverProblem` is what `alert`
    /// already says about the cover; whatever stops the save is said after it.
    private func saveAppliedLookup(after coverProblem: String?) async {
        // Nothing was changed: only a cover was ticked, and it could not be had.
        guard hasUnsavedChanges else { return }
        guard busyLabel == nil else {
            alert = [coverProblem, Self.appliedNotSaved].compactMap { $0 }.joined(separator: " ")
            return
        }
        await save()
        if let coverProblem, let said = alert, said != coverProblem {
            alert = "\(coverProblem) \(said)"
        }
    }

    /// A6: closes the lookup and applies nothing. A search still running is cancelled.
    public func cancelLookup() {
        closeLookup()
    }

    /// Bytes that were fetched as a picture, as a cover; nil if they are not a JPEG or PNG.
    static func coverImage(_ data: Data) -> CoverImage? {
        guard let mime = CoverImage.sniffedMIME(data), mime == "image/jpeg" || mime == "image/png" else { return nil }
        return CoverImage(data: data, mime: mime)
    }

    func closeLookup() {
        lookupSearch?.cancel()
        lookupSearch = nil
        lookupDetailLoads.values.forEach { $0.cancel() }
        lookupDetailLoads = [:]
        if let fetch = addCoverFetch {
            // An Audible book was being added and its cover is still on its way: the
            // add is called off here, and nothing is busy any more.
            fetch.cancel()
            addCoverFetch = nil
            busyLabel = nil
        }
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
        case .newAudibleBook, nil:
            // An add is for no book: only the library changing, or an import, closes it.
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

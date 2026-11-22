import Foundation
import VoxCarrelCore

/// The lookup sheet's state: what is searched for, what was found, the chosen match and a
/// tick for each of its values that could be taken.
///
/// A plain value: it asks nothing of the network or the library. `applied()` says what
/// the book's details would be with the ticked values; putting them anywhere is the
/// model's work, and nothing is saved by it.
public struct LookupSession: Equatable, Sendable {
    /// What the found values are for.
    public enum Target: Equatable, Sendable {
        /// The inspector's draft of this library book.
        case book(Int64)
        /// An entry in the import sheet.
        case importEntry(UUID)
        /// Nothing yet: the chosen result is added to the library as a book that is on
        /// Audible and has no files here.
        case newAudibleBook
    }

    public enum Phase: Equatable, Sendable {
        /// Nothing has been searched for yet, or the query was changed while a search ran.
        case idle
        case searching
        case results
        case noResults
        /// The ticked values are being applied, or the book is being added (a cover is
        /// being fetched): nothing can be changed.
        case applying
    }

    /// One detail of the selected result, to read: "Narrators", "Marcus Lindqvist".
    public struct DetailLine: Identifiable, Equatable, Sendable {
        public var label: String
        public var value: String

        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// One value of the selected match that could replace the book's own.
    public struct Offer: Identifiable, Equatable, Sendable {
        public var id: MetadataField
        /// "Narrators"
        public var label: String
        /// What the book has now, as text; "" when empty.
        public var current: String
        public var found: String
        public var ticked: Bool
    }

    /// What one source made of the last search: how many it found, or why it gave no answer.
    public struct SourceOutcome: Equatable, Sendable {
        public var source: LookupSource
        /// How many of the results are this source's; 0 when it failed.
        public var found: Int
        /// Nil when the source answered.
        public var failure: LookupError?
    }

    public let target: Target
    /// The book's details when the lookup began: what found values are compared with.
    public let current: BookMetadata
    /// Text in the book's fields that `current` could not hold when the lookup began (a
    /// year that is not a year): it is what is there, and is not written over unasked.
    public let typed: [MetadataField: String]
    public let hasCover: Bool
    public let hasAudio: Bool

    /// Editable in the sheet. Changing it while a search runs leaves that search behind:
    /// its answer will be for another query, and is ignored (K2).
    public var query: LookupQuery {
        didSet {
            if query != oldValue, phase == .searching { phase = .idle }
        }
    }
    public var preferAudio: Bool
    public private(set) var phase = Phase.idle
    /// Best first.
    public private(set) var candidates: [LookupCandidate] = []
    /// "Audible could not be reached."; nil when every source answered.
    public private(set) var failureText: String?
    public private(set) var selectedId: String?
    /// For the selected candidate.
    public private(set) var offers: [Offer] = []
    /// What each source that was asked made of the last finished search, in the order
    /// they were asked; empty until a search has finished, and while another runs.
    public private(set) var outcomes: [SourceOutcome] = []
    /// The query the results shown are the answer to; nil when there are none, or when
    /// they are no longer what a search now would find.
    public private(set) var answeredQuery: LookupQuery?
    /// True once any search of this session has finished, whatever it found, and
    /// whether or not every source could be reached.
    public private(set) var hasSearched = false

    /// K1
    public init(
        target: Target, current: BookMetadata, hasCover: Bool, hasAudio: Bool, typed: [MetadataField: String] = [:]
    ) {
        self.target = target
        self.current = current
        self.typed = typed.compactMapValues(\.trimmedOrNil)
        self.hasCover = hasCover
        self.hasAudio = hasAudio
        query = LookupQuery(
            title: current.title.trimmed, author: current.authors.lazy.compactMap(\.trimmedOrNil).first ?? "",
            isbn: current.isbn?.trimmedOrNil, asin: current.asin?.trimmedOrNil)
        preferAudio = hasAudio
    }

    public var selected: LookupCandidate? {
        selectedId.flatMap { id in candidates.first { $0.id == id } }
    }

    // MARK: Adding an Audible book

    /// True when the session is for adding an Audible book: there is no book to compare
    /// with, so nothing is offered or ticked, and the chosen result is added whole.
    public var isAddMode: Bool {
        target == .newAudibleBook
    }

    /// The only sources a search of this session asks; nil for all of them. What Open
    /// Library finds cannot be added as an Audible book.
    public var sources: Set<LookupSource>? {
        isAddMode ? [.audible] : nil
    }

    /// Whether the Add button applies: adding, with a result selected and nothing in progress.
    public var canAdd: Bool {
        isAddMode && phase == .results && selected != nil
    }

    /// Whether adding the book from what is typed, with no result chosen, is on offer:
    /// adding, once the catalogue has been tried (a search has finished, whatever it
    /// found or failed to reach), and nothing in progress.
    public var offersAddByHand: Bool {
        isAddMode && hasSearched && phase != .searching && phase != .applying
    }

    /// Whether the book can be added from what is typed: it is on offer, and both a
    /// title and an author are in the search boxes. (A book with no author could not
    /// be told from another of the same title, nor be filed when its files arrive.)
    public var canAddByHand: Bool {
        offersAddByHand && query.title.trimmedOrNil != nil && query.author.trimmedOrNil != nil
    }

    /// The Audible ID typed in its box, tidied, when it is a well-formed one; nil for
    /// anything else. It goes with a book that is added by hand.
    public var typedAudibleID: String? {
        query.asin.flatMap(AudibleProvider.asin)
    }

    /// The book is being added; until the session closes nothing can be changed and it
    /// cannot be added again.
    public mutating func beginAdding() {
        guard canAdd || canAddByHand else { return }
        phase = .applying
    }

    /// The selected result's details, to read: title, authors, narrators, series and
    /// number, length, year, publisher, language and description, each only when the
    /// result has it. Empty when no result is selected.
    public var detailLines: [DetailLine] {
        guard let found = selected?.metadata else { return [] }
        var series = found.series?.trimmedOrNil
        if let name = series, let number = found.seriesNumber?.trimmedOrNil { series = "\(name) #\(number)" }
        let lines: [(String, String?)] = [
            ("Title", found.title.trimmedOrNil),
            ("Authors", Self.names(found.authors).joined(separator: ", ").trimmedOrNil),
            ("Narrators", Self.names(found.narrators).joined(separator: ", ").trimmedOrNil),
            ("Series", series),
            ("Length", LengthText.text(seconds: found.durationSeconds)),
            ("Year", found.year.map(String.init)),
            ("Publisher", found.publisher?.trimmedOrNil),
            ("Language", found.language?.trimmedOrNil),
            ("Description", found.summary?.trimmedOrNil),
        ]
        return lines.compactMap { label, value in value.map { DetailLine(label: label, value: $0) } }
    }

    /// A candidate is selected and something is ticked, and it is not being applied already.
    public var canApply: Bool {
        phase == .results && selected != nil && offers.contains(where: \.ticked)
    }

    /// The fields whose found values are to be taken, in the offers' order.
    public var tickedFields: [MetadataField] {
        offers.filter(\.ticked).map(\.id)
    }

    // MARK: Searching

    /// A search for `query` has been started: what the last one found is cleared.
    public mutating func beginSearch() {
        guard phase != .applying else { return }
        phase = .searching
        candidates = []
        failureText = nil
        selectedId = nil
        offers = []
        outcomes = []
        answeredQuery = nil
    }

    /// True when the results shown are every source's answer to the query as it is now:
    /// searching again would only ask the same thing, and lose the ticks.
    public var isAnswered: Bool {
        phase == .results && answeredQuery == query && failureText == nil
    }

    /// The sources are not the ones the results came from (another Audible store):
    /// the same query may be searched for again.
    public mutating func sourcesChanged() {
        answeredQuery = nil
        outcomes = []
    }

    /// K2: the answer to a search for `query`. Ignored when the query has changed since.
    public mutating func finishSearch(_ results: LookupResults, for query: LookupQuery) {
        guard query == self.query, phase != .applying else { return }
        candidates = results.candidates
        phase = candidates.isEmpty ? .noResults : .results
        // In the order the sources were asked, then any other.
        let sources = results.searched + LookupSource.allCases.filter { !results.searched.contains($0) }
        let sentences = sources.compactMap { source in
            results.failures[source].map { UserMessage.text(for: $0, source: source) }
        }
        failureText = sentences.isEmpty ? nil : sentences.joined(separator: " ")
        outcomes = results.searched.map {
            SourceOutcome(source: $0, found: results.found[$0] ?? 0, failure: results.failures[$0])
        }
        answeredQuery = query
        hasSearched = true
        selectedId = candidates.first?.id
        offers = defaultOffers()
    }

    // MARK: Choosing

    /// K4: selects a candidate; its offers start with their default ticks. Nil selects
    /// none. An id that is not among the candidates, or is the selected one, changes nothing.
    public mutating func select(_ id: String?) {
        guard phase != .applying, id != selectedId else { return }
        if let id, !candidates.contains(where: { $0.id == id }) { return }
        selectedId = id
        offers = defaultOffers()
    }

    /// K7: more has arrived about the selected candidate. Offers it adds have their
    /// default ticks; the ticks of offers already shown are left as the user has them.
    /// Ignored when `detailed` is not the selected candidate.
    public mutating func replaceSelected(with detailed: LookupCandidate) {
        guard phase != .applying, let selectedId, detailed.id == selectedId,
              let index = candidates.firstIndex(where: { $0.id == selectedId })
        else { return }
        candidates[index] = detailed
        let before = Dictionary(offers.map { ($0.id, $0.ticked) }) { first, _ in first }
        var fresh = defaultOffers()
        for index in fresh.indices {
            if let ticked = before[fresh[index].id] { fresh[index].ticked = ticked }
        }
        // K5: a newly offered half of the series pair follows the half already shown.
        if let series = fresh.firstIndex(where: { $0.id == .series }),
           let number = fresh.firstIndex(where: { $0.id == .seriesNumber }) {
            if let ticked = before[.series] ?? before[.seriesNumber] {
                fresh[series].ticked = ticked
                fresh[number].ticked = ticked
            }
        }
        offers = fresh
    }

    /// K5: series and series number are ticked and unticked together when both are offered.
    public mutating func setTicked(_ ticked: Bool, for field: MetadataField) {
        guard phase != .applying else { return }
        let pair: Set<MetadataField> = [.series, .seriesNumber]
        let fields: Set<MetadataField> = pair.contains(field) ? pair : [field]
        guard offers.contains(where: { $0.id == field }) else { return }
        for index in offers.indices where fields.contains(offers[index].id) {
            offers[index].ticked = ticked
        }
    }

    // MARK: Applying

    /// The ticked values are being applied; until the session closes nothing can be
    /// changed and `canApply` is false, so they cannot be applied twice.
    public mutating func beginApplying() {
        guard canApply else { return }
        phase = .applying
    }

    /// K6: the current values with every ticked offer applied, and whether the cover is
    /// wanted. Duration and page count are always the book's own.
    public func applied() -> (metadata: BookMetadata, wantsCover: Bool) {
        var metadata = current
        guard let found = selected?.metadata else { return (metadata, false) }
        var wantsCover = false
        for field in tickedFields {
            switch field {
            case .title: metadata.title = found.title.trimmed
            case .subtitle: metadata.subtitle = found.subtitle?.trimmedOrNil
            case .authors: metadata.authors = Self.names(found.authors)
            case .narrators: metadata.narrators = Self.names(found.narrators)
            case .series: metadata.series = found.series?.trimmedOrNil
            case .seriesNumber: metadata.seriesNumber = found.seriesNumber?.trimmedOrNil
            case .genre: metadata.genre = found.genre?.trimmedOrNil
            case .year: metadata.year = found.year
            case .publisher: metadata.publisher = found.publisher?.trimmedOrNil
            case .summary: metadata.summary = found.summary?.trimmedOrNil
            case .language: metadata.language = found.language?.trimmedOrNil
            case .isbn: metadata.isbn = found.isbn?.trimmedOrNil
            case .asin: metadata.asin = found.asin?.trimmedOrNil
            case .cover: wantsCover = true
            }
        }
        return (metadata, wantsCover)
    }

    // MARK: Offers

    /// K3: the order offers are shown in.
    static let offerOrder: [MetadataField] = [
        .title, .subtitle, .authors, .narrators, .series, .seriesNumber, .genre, .year, .publisher, .language,
        .summary, .isbn, .asin, .cover,
    ]

    static func label(_ field: MetadataField) -> String {
        switch field {
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .authors: "Authors"
        case .narrators: "Narrators"
        case .series: "Series"
        case .seriesNumber: "Series number"
        case .genre: "Genre"
        case .year: "Year"
        case .publisher: "Publisher"
        case .language: "Language"
        case .summary: "Description"
        case .isbn: "ISBN"
        case .asin: "ASIN"
        case .cover: "Cover"
        }
    }

    /// K3, K4: the selected candidate's offers with their default ticks.
    private func defaultOffers() -> [Offer] {
        // N2: a book that is being added has no values of its own to replace.
        guard !isAddMode, let candidate = selected else { return [] }
        var offers = Self.offerOrder.compactMap { offer($0, from: candidate) }
        // K5: the pair has one tick, the series': a found number is not put on a series
        // the book already has unless the user says so.
        if let series = offers.firstIndex(where: { $0.id == .series }),
           let number = offers.firstIndex(where: { $0.id == .seriesNumber }) {
            offers[number].ticked = offers[series].ticked
        }
        return offers
    }

    /// Nil when the candidate has no value for the field, or the value is the book's own.
    private func offer(_ field: MetadataField, from candidate: LookupCandidate) -> Offer? {
        let found = candidate.metadata
        func text(_ theirs: String?, _ ours: String?) -> Offer? {
            guard let theirs = theirs?.trimmedOrNil else { return nil }
            // What is typed in the field, when that is not what the details could hold.
            let ours = typed[field] ?? ours?.trimmed ?? ""
            guard theirs != ours else { return nil }
            return Offer(id: field, label: Self.label(field), current: ours, found: theirs, ticked: ours.isEmpty)
        }
        func names(_ theirs: [String], _ ours: [String]) -> Offer? {
            let theirs = Self.names(theirs)
            let ours = Self.names(ours)
            let differs = theirs.map { $0.lowercased() } != ours.map { $0.lowercased() }
            guard !theirs.isEmpty, differs else { return nil }
            return Offer(
                id: field, label: Self.label(field), current: NameListText.text(from: ours),
                found: NameListText.text(from: theirs), ticked: ours.isEmpty)
        }
        switch field {
        case .title: return text(found.title, current.title)
        case .subtitle: return text(found.subtitle, current.subtitle)
        case .authors: return names(found.authors, current.authors)
        // K6: narrators are for a book that has audio.
        case .narrators: return hasAudio ? names(found.narrators, current.narrators) : nil
        case .series: return text(found.series, current.series)
        case .seriesNumber: return text(found.seriesNumber, current.seriesNumber)
        case .genre: return text(found.genre, current.genre)
        case .year: return text(found.year.map(String.init), current.year.map(String.init))
        case .publisher: return text(found.publisher, current.publisher)
        case .language: return text(found.language, current.language)
        case .summary: return text(found.summary, current.summary)
        case .isbn: return text(found.isbn, current.isbn)
        case .asin: return text(found.asin, current.asin)
        case .cover:
            guard candidate.coverURL != nil else { return nil }
            return Offer(
                id: field, label: Self.label(field), current: hasCover ? "Has a cover" : "",
                found: "Cover from \(candidate.source.title)", ticked: !hasCover)
        }
    }

    /// The names without the spaces around them, and without empty ones.
    private static func names(_ names: [String]) -> [String] {
        names.compactMap(\.trimmedOrNil)
    }
}

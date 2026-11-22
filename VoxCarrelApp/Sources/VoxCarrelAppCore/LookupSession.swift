import Foundation
import VoxCarrelCore

/// The lookup sheet's state: what is searched for, what was found, whether each result
/// is the book's own edition, the chosen match, and for every result a tick for each
/// of its values that could be taken. Values can be taken from several results at once.
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
        /// A2: why the value may not be the book's, for a value that belongs to an
        /// edition (narrators, year, publisher, ASIN, ISBN) of a result that is plainly
        /// another edition: "Different edition: read by Rory Kinnear, not Frank Muller".
        /// Nil for every other offer.
        public var reason: String? = nil
    }

    /// What kind of edition the book is taken to be from what was found, offered beside
    /// the other values: "Abridged", with why.
    public struct EditionOffer: Equatable, Sendable {
        /// "Edition"
        public var label: String
        /// What the book has now, as text; "" when its edition is not known.
        public var current: String
        /// "Abridged", "Probably unabridged"
        public var found: String
        /// How that is known: "Audible lists your edition as abridged. Matched with a result from Audible."
        public var reason: String
        public var ticked: Bool
        /// What applying it gives the book.
        public var note: EditionKindNote
    }

    /// What one source made of the last search: how many it found, or why it gave no answer.
    public struct SourceOutcome: Equatable, Sendable {
        public var source: LookupSource
        /// How many of the results are this source's; 0 when it failed.
        public var found: Int
        /// Nil when the source answered.
        public var failure: LookupError?
        /// A7: the narrator the source found nothing read by, so that it searched again
        /// without the name; nil otherwise.
        public var narratorNotFound: String? = nil
    }

    /// A5: what applying would do: the book's details with every ticked value, from
    /// whichever result it is ticked on.
    public struct Applied: Equatable, Sendable {
        /// The current details with every ticked value put in.
        public var metadata: BookMetadata
        /// The fields that were ticked, in the offers' order, the cover included.
        public var fields: [MetadataField]
        /// The result whose cover is ticked; nil when no cover is.
        public var coverCandidate: LookupCandidate?
        /// The edition kind to give the book; nil when its offer is not ticked.
        public var editionKind: EditionKindNote?

        public var wantsCover: Bool { coverCandidate != nil }
    }

    public let target: Target
    /// The book's details when the lookup began: what found values are compared with.
    public let current: BookMetadata
    /// Text in the book's fields that `current` could not hold when the lookup began (a
    /// year that is not a year): it is what is there, and is not written over unasked.
    public let typed: [MetadataField: String]
    public let hasCover: Bool
    public let hasAudio: Bool
    /// The measured length of the book's audio files; nil when it has none, or when the
    /// length cannot be relied on. What a result's length is compared with.
    public let audioSeconds: Double?
    /// What kind of edition the book is taken to be now; nil for not known.
    public let editionKind: EditionKindNote?
    /// Whether the book's numbered parts have gaps: a short length is then no sign of
    /// an abridgement.
    public let partsAppearMissing: Bool

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
    /// A6: whether each result is the book's own edition, by candidate id. Empty when
    /// the search was for no book.
    public private(set) var verdicts: [String: EditionVerdict] = [:]
    /// A1: the fields ticked on each result, by candidate id.
    private var ticks: [String: Set<MetadataField>] = [:]
    /// The fields of each result whose first tick has been decided: one offered later
    /// (when more arrives about the result) is decided then.
    private var decided: [String: Set<MetadataField>] = [:]
    /// The results the user has ticked or unticked something on. Their ticks are kept
    /// when another result is selected, as are those of the book's own edition; the
    /// untouched ticks of any other result that was only looked at are not.
    private var touched: Set<String> = []
    /// The user's own tick of the edition offer, and the offer it was made on; nil
    /// while the offer has its first tick. A tick is for what was offered: when the
    /// results come to offer another kind, or the same on other grounds, it goes.
    private var editionTick: EditionTick?

    private struct EditionTick: Equatable, Sendable {
        var kind: EditionKind
        var basis: EditionKindNote.Basis
        var ticked: Bool

        func isFor(_ note: EditionKindNote) -> Bool {
            kind == note.kind && basis == note.basis
        }
    }
    /// What each source that was asked made of the last finished search, in the order
    /// they were asked; empty until a search has finished, and while another runs.
    public private(set) var outcomes: [SourceOutcome] = []
    /// The query the results shown are the answer to; nil when there are none, or when
    /// they are no longer what a search now would find.
    public private(set) var answeredQuery: LookupQuery?
    /// True once any search of this session has finished, whatever it found, and
    /// whether or not every source could be reached.
    public private(set) var hasSearched = false

    /// K1. The search carries the book's first narrator (a source that can search by
    /// reader then does), and asks for audio editions when the book has audio.
    public init(
        target: Target, current: BookMetadata, hasCover: Bool, hasAudio: Bool, typed: [MetadataField: String] = [:],
        audioSeconds: Double? = nil, editionKind: EditionKindNote? = nil, partsAppearMissing: Bool = false
    ) {
        self.target = target
        self.current = current
        self.typed = typed.compactMapValues(\.trimmedOrNil)
        self.hasCover = hasCover
        self.hasAudio = hasAudio
        self.audioSeconds = audioSeconds
        self.editionKind = editionKind
        self.partsAppearMissing = partsAppearMissing
        let adding = target == .newAudibleBook
        query = LookupQuery(
            title: current.title.trimmed, author: current.authors.lazy.compactMap(\.trimmedOrNil).first ?? "",
            isbn: current.isbn?.trimmedOrNil, asin: current.asin?.trimmedOrNil,
            // "Full Cast" is a credit, not someone to search for.
            narrator: hasAudio
                ? current.narrators.lazy.compactMap(\.trimmedOrNil).first { !EditionMatch.isFullCast($0) } : nil,
            wantsAudioEditions: hasAudio && !adding)
        preferAudio = hasAudio
    }

    /// The book the search is for, so that results are judged and ranked against it;
    /// nil when a book is being added, which has no edition yet.
    public var bookContext: LookupBookContext? {
        guard !isAddMode else { return nil }
        return LookupBookContext(
            metadata: current, audioSeconds: hasAudio ? audioSeconds : nil,
            // Only a kind that is well founded is held against a result.
            isAbridged: editionKind?.abridgedForMatching)
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

    /// Something is ticked, on the selected result or another, and it is not being
    /// applied already.
    public var canApply: Bool {
        phase == .results && (!tickedFields.isEmpty || editionOffer?.ticked == true)
    }

    /// The fields whose found values are to be taken, from whichever result, in the
    /// offers' order.
    public var tickedFields: [MetadataField] {
        let all = candidates.reduce(into: Set<MetadataField>()) { $0.formUnion(tickedFields(on: $1.id)) }
        return Self.offerOrder.filter(all.contains)
    }

    /// A1: the fields ticked on one result, in the offers' order.
    public func tickedFields(on id: String) -> [MetadataField] {
        offers(for: id).filter(\.ticked).map(\.id)
    }

    /// For the selected candidate.
    public var offers: [Offer] {
        selectedId.map(offers(for:)) ?? []
    }

    /// A1: one result's offers with its own ticks. Empty for a result that is not
    /// among the candidates, and when a book is being added.
    public func offers(for id: String) -> [Offer] {
        // N2: a book that is being added has no values of its own to replace.
        guard !isAddMode, let candidate = candidates.first(where: { $0.id == id }) else { return [] }
        let ticked = ticks[id] ?? []
        let reason = Self.reasonText(verdicts[id])
        return Self.offerOrder.compactMap { field in
            guard var offer = offer(field, from: candidate) else { return nil }
            offer.ticked = ticked.contains(field)
            if Self.editionFields.contains(field) { offer.reason = reason }
            return offer
        }
    }

    // MARK: Editions

    /// A2: the values that belong to an edition, not to the book whatever its edition.
    static let editionFields: Set<MetadataField> = [.narrators, .year, .publisher, .asin, .isbn]

    /// A6: whether the result is the book's own edition; `.unknown` when nothing says.
    public func verdict(for id: String) -> EditionVerdict {
        verdicts[id] ?? .unknown
    }

    /// A6: what a result's row is marked with: "Your edition", "Different edition", or
    /// nil when it cannot be told.
    public func badgeText(for id: String) -> String? {
        switch verdict(for: id) {
        case .sameEdition: "Your edition"
        case .differentEdition: "Different edition"
        case .unknown: nil
        }
    }

    /// A6: why a result is marked "Different edition", for the badge's tooltip:
    /// "Read by Rory Kinnear, not Frank Muller; 19h 59m; yours is 18h 0m". Nil otherwise.
    public func badgeHelp(for id: String) -> String? {
        let reasons = verdict(for: id).reasons
        guard !reasons.isEmpty else { return nil }
        let text = reasons.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A2: "Different edition: read by Rory Kinnear, not Frank Muller".
    private static func reasonText(_ verdict: EditionVerdict?) -> String? {
        guard case .differentEdition(let reasons)? = verdict else { return nil }
        return reasons.isEmpty ? "Different edition" : "Different edition: " + reasons.joined(separator: "; ")
    }

    /// What the results say of the book's edition kind, and the result that says it
    /// when one does. Only for a library book that has audio.
    ///
    /// With a result selected, that result first: a result that is this very edition
    /// and says what it is, or else what the running time shows against all of them.
    /// With none selected, only what the best result that is this very edition says:
    /// nothing is worked out from results nobody has looked at.
    private var editionFinding: (assessment: EditionKindAssessment, result: LookupCandidate?) {
        guard case .book = target, hasAudio, !candidates.isEmpty else { return (EditionKindAssessment(), nil) }
        guard let selected else {
            guard let best = EditionKindGuess.matchedResult(in: candidates, book: current, bookSeconds: audioSeconds)
            else { return (EditionKindAssessment(), nil) }
            let note = EditionKindGuess.assess([best], book: current, bookSeconds: audioSeconds).note
            return (EditionKindAssessment(note: note), best)
        }
        let ordered = [selected] + candidates.filter { $0.id != selected.id }
        let assessment = EditionKindGuess.assess(
            ordered, book: current, bookSeconds: audioSeconds, partsAppearMissing: partsAppearMissing)
        guard case .matched? = assessment.note?.basis else { return (assessment, nil) }
        return (assessment, EditionKindGuess.matchedResult(in: ordered, book: current, bookSeconds: audioSeconds))
    }

    private var editionAssessment: EditionKindAssessment {
        editionFinding.assessment
    }

    /// The edition kind the results give the book, offered with the other values; nil
    /// when they give none, or the one the book already has. Ticked to begin with only
    /// when the book's edition is not known; the user's own tick stands only while
    /// the same kind is offered on the same grounds.
    public var editionOffer: EditionOffer? {
        guard let note = editionAssessment.note, note.kind != editionKind?.kind else { return nil }
        let own = editionTick.flatMap { $0.isFor(note) ? $0.ticked : nil }
        return EditionOffer(
            label: "Edition", current: editionKind?.title ?? "", found: note.title, reason: note.helpText,
            ticked: own ?? (editionKind == nil), note: note)
    }

    /// The user's tick of the edition offer goes when that is no longer what is offered.
    private mutating func settleEditionTick() {
        guard let tick = editionTick else { return }
        if let note = editionOffer?.note, tick.isFor(note) { return }
        editionTick = nil
    }

    /// Said in place of an edition offer when the results show something about the
    /// book's length but no verdict: "13h 0m; shorter than the unabridged editions
    /// (20h 0m), so it may be abridged or incomplete."
    public var editionRemark: String? {
        let assessment = editionAssessment
        return assessment.note == nil ? assessment.remark : nil
    }

    public mutating func setEditionTicked(_ ticked: Bool) {
        guard phase != .applying, let note = editionOffer?.note else { return }
        editionTick = EditionTick(kind: note.kind, basis: note.basis, ticked: ticked)
    }

    // MARK: Searching

    /// A search for `query` has been started: what the last one found is cleared.
    public mutating func beginSearch() {
        guard phase != .applying else { return }
        phase = .searching
        candidates = []
        failureText = nil
        selectedId = nil
        verdicts = [:]
        ticks = [:]
        decided = [:]
        touched = []
        editionTick = nil
        outcomes = []
        answeredQuery = nil
    }

    /// True when the results shown are every source's answer to the query as it is now:
    /// searching again would only ask the same thing, and lose the ticks.
    public var isAnswered: Bool {
        phase == .results && answeredQuery == query && failureText == nil
    }

    /// The sources are not the ones the results came from (another Audible store, a
    /// source turned off): the same query may be searched for again.
    ///
    /// `sources`: the sources that are on now; nil to leave the results as they are.
    /// The results of a source that is off go, with their ticks: nothing more is
    /// fetched for them, and nothing of them is applied.
    public mutating func sourcesChanged(to sources: Set<LookupSource>? = nil) {
        answeredQuery = nil
        outcomes = []
        guard let sources, phase != .applying else { return }
        let gone = Set(candidates.filter { !sources.contains($0.source) }.map(\.id))
        guard !gone.isEmpty else { return }
        candidates.removeAll { gone.contains($0.id) }
        for id in gone {
            ticks[id] = nil
            decided[id] = nil
            verdicts[id] = nil
        }
        touched.subtract(gone)
        if let selectedId, gone.contains(selectedId) { self.selectedId = nil }
        if phase == .results, candidates.isEmpty { phase = .noResults }
        settleEditionTick()
    }

    /// K2: the answer to a search for `query`. Ignored when the query has changed since.
    public mutating func finishSearch(_ results: LookupResults, for query: LookupQuery) {
        guard query == self.query, phase != .applying else { return }
        candidates = results.candidates
        verdicts = isAddMode ? [:] : results.verdicts
        ticks = [:]
        decided = [:]
        touched = []
        editionTick = nil
        phase = candidates.isEmpty ? .noResults : .results
        // In the order the sources were asked, then any other.
        let sources = results.searched + LookupSource.allCases.filter { !results.searched.contains($0) }
        let sentences = sources.compactMap { source in
            results.failures[source].map { UserMessage.text(for: $0, source: source) }
        }
        failureText = sentences.isEmpty ? nil : sentences.joined(separator: " ")
        outcomes = results.searched.map {
            SourceOutcome(
                source: $0, found: results.found[$0] ?? 0, failure: results.failures[$0],
                narratorNotFound: results.narratorNotFound[$0])
        }
        answeredQuery = query
        hasSearched = true
        selectedId = candidates.first?.id
        decideFirstTicks()
    }

    // MARK: Choosing

    /// K4, A1: selects a candidate. One that is selected for the first time gets its
    /// first ticks (A2); one the user has ticked or unticked something on keeps its
    /// ticks while another is selected, and has them still when it is selected again.
    ///
    /// So does a result that is the book's own edition, touched or not: its values are
    /// the book's, and the cover or the description is then taken from another result.
    /// The first ticks of any other result that was only looked at go when another is
    /// selected: looking at a result is not choosing it, and nothing of it is applied.
    /// Nil selects none. An id that is not among the candidates, or is the selected
    /// one, changes nothing.
    public mutating func select(_ id: String?) {
        guard phase != .applying, id != selectedId else { return }
        if let id, !candidates.contains(where: { $0.id == id }) { return }
        if let old = selectedId, !touched.contains(old), verdict(for: old) != .sameEdition {
            ticks[old] = nil
            decided[old] = nil
        }
        selectedId = id
        decideFirstTicks()
        settleEditionTick()
    }

    /// K7: more has arrived about the selected candidate. Offers it adds have their
    /// first ticks; the ticks of offers already shown are left as the user has them.
    /// Ignored when `detailed` is not the selected candidate.
    public mutating func replaceSelected(with detailed: LookupCandidate) {
        guard phase != .applying, let selectedId, detailed.id == selectedId,
              let index = candidates.firstIndex(where: { $0.id == selectedId })
        else { return }
        candidates[index] = detailed
        decideFirstTicks()
        settleEditionTick()
    }

    /// A2: gives the selected result's offers their first ticks, each once: an offer
    /// decided already keeps the tick it has.
    ///
    /// A value is ticked to begin with when the book has none of its own, as before;
    /// but nothing of a result that is plainly another edition, and nothing that is
    /// ticked on another result already (A3: a field is taken from one result).
    private mutating func decideFirstTicks() {
        guard !isAddMode, let candidate = selected else { return }
        let id = candidate.id
        let offered = Self.offerOrder.compactMap { offer($0, from: candidate) }
        let fields = Set(offered.map(\.id))
        let before = decided[id] ?? []
        var ticked = ticks[id] ?? []
        let different = verdict(for: id).isDifferent
        for offer in offered where !before.contains(offer.id) {
            if offer.ticked, !different, !isTicked(offer.id, onOtherThan: id) { ticked.insert(offer.id) }
        }
        // K5: the series pair has one tick. Decided together, it is the series': a found
        // number is not put on a series the book already has unless the user says so.
        // A half that is offered later follows the half already shown.
        if fields.contains(.series), fields.contains(.seriesNumber) {
            let seriesIsNew = !before.contains(.series), numberIsNew = !before.contains(.seriesNumber)
            if seriesIsNew && !numberIsNew {
                if ticked.contains(.seriesNumber) { ticked.insert(.series) } else { ticked.remove(.series) }
            } else if seriesIsNew || numberIsNew {
                if ticked.contains(.series) { ticked.insert(.seriesNumber) } else { ticked.remove(.seriesNumber) }
            }
            // The pair is one choice: it is on one result or none.
            if ticked.contains(.series), isTicked(.series, onOtherThan: id) || isTicked(.seriesNumber, onOtherThan: id) {
                ticked.subtract([.series, .seriesNumber])
            }
        }
        ticks[id] = ticked
        decided[id] = before.union(fields)
    }

    private func isTicked(_ field: MetadataField, onOtherThan id: String) -> Bool {
        ticks.contains { $0.key != id && $0.value.contains(field) && candidateOffers($0.key, field) }
    }

    /// Whether the result still offers the field: a tick on a value that is no longer
    /// offered counts for nothing.
    private func candidateOffers(_ id: String, _ field: MetadataField) -> Bool {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return false }
        return offer(field, from: candidate) != nil
    }

    /// K5, A3: ticks or unticks a value of the selected result. Series and series
    /// number are ticked and unticked together when both are offered. Ticking a value
    /// unticks the same value on every other result: a field is taken from one.
    public mutating func setTicked(_ ticked: Bool, for field: MetadataField) {
        guard let selectedId else { return }
        setTicked(ticked, for: field, on: selectedId)
    }

    /// The same for any result, selected or not.
    public mutating func setTicked(_ ticked: Bool, for field: MetadataField, on id: String) {
        guard phase != .applying, candidateOffers(id, field) else { return }
        let pair: Set<MetadataField> = [.series, .seriesNumber]
        let fields = (pair.contains(field) ? pair : [field]).filter { candidateOffers(id, $0) }
        var own = ticks[id] ?? []
        if ticked {
            own.formUnion(fields)
            // A3: the pair moves together on the others too.
            let taken: Set<MetadataField> = pair.contains(field) ? pair : [field]
            for other in ticks.keys where other != id { ticks[other]?.subtract(taken) }
        } else {
            own.subtract(fields)
        }
        ticks[id] = own
        decided[id, default: []].formUnion(fields)
        touched.insert(id)
    }

    // MARK: Applying

    /// The ticked values are being applied; until the session closes nothing can be
    /// changed and `canApply` is false, so they cannot be applied twice.
    public mutating func beginApplying() {
        guard canApply else { return }
        phase = .applying
    }

    /// K6, A5: the current values with every ticked offer applied, from whichever
    /// result it is ticked on; the result whose cover is wanted; and the edition kind
    /// when its offer is ticked. Duration and page count are always the book's own.
    public func applied() -> Applied {
        var metadata = current
        var fields = Set<MetadataField>()
        var coverCandidate: LookupCandidate?
        for candidate in candidates {
            let found = candidate.metadata
            for field in tickedFields(on: candidate.id) where fields.insert(field).inserted {
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
                case .cover: coverCandidate = candidate
                }
            }
        }
        let edition = editionOffer.flatMap { $0.ticked ? $0.note : nil }
        return Applied(
            metadata: metadata, fields: Self.offerOrder.filter(fields.contains), coverCandidate: coverCandidate,
            editionKind: edition)
    }

    /// A4: what will be applied, across results: "Narrators, year and publisher from
    /// Library of Congress; description and cover from Audible". Nil when nothing is
    /// ticked.
    ///
    /// When more than one result of a source gives something, each is told apart by
    /// who reads it and its year, and failing those by its stores: "narrators from
    /// Audible (Rory Kinnear, 2025); year from Audible (Shaun Evans, 2024)". The
    /// edition is named with the result that says it, or with how it was worked out.
    public var applySummary: String? {
        // What each result gives, in the results' order.
        var taken = Set<MetadataField>()
        var gives: [(candidate: LookupCandidate, fields: Set<MetadataField>, edition: Bool)] = []
        let offer = editionOffer.flatMap { $0.ticked ? $0 : nil }
        let editionResult = offer == nil ? nil : editionFinding.result
        for candidate in candidates {
            let fields = Set(tickedFields(on: candidate.id).filter { taken.insert($0).inserted })
            let edition = candidate.id == editionResult?.id
            if !fields.isEmpty || edition { gives.append((candidate, fields, edition)) }
        }
        let givers = Dictionary(grouping: gives, by: \.candidate.source)

        var order: [String] = []
        var fields: [String: Set<MetadataField>] = [:]
        var edition: String?
        func place(_ name: String) -> String {
            if !order.contains(name) { order.append(name) }
            return name
        }
        for give in gives {
            let source = give.candidate.source
            var name = "from \(source.title)"
            if let others = givers[source], others.count > 1 {
                name += Self.distinguishing(give.candidate, among: others.map(\.candidate))
            }
            fields[place(name), default: []].formUnion(give.fields)
            if give.edition { edition = name }
        }
        if let offer, edition == nil {
            switch offer.note.basis {
            case .matched(let source): edition = place("from \(source)")
            case .estimated: edition = place("from the length of the printed book")
            default: edition = place("from its running time")
            }
        }
        guard !order.isEmpty else { return nil }
        let text: String = order.map { (place: String) -> String in
            // In the offers' order, whichever result each came from; the edition last.
            var names = Self.offerOrder.filter { fields[place]?.contains($0) ?? false }.map(Self.summaryName)
            if edition == place { names.append("edition") }
            return "\(Self.list(names)) \(place)"
        }.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// " (Rory Kinnear, 2025)": what tells one result from the others of its source
    /// that give something. Its first reader and its year; its stores too when those
    /// do not tell it apart; "" when it has none of them.
    private static func distinguishing(_ candidate: LookupCandidate, among others: [LookupCandidate]) -> String {
        func words(_ candidate: LookupCandidate, stores: Bool) -> [String] {
            var words: [String] = []
            if let reader = candidate.metadata.narrators.lazy.compactMap(\.trimmedOrNil).first { words.append(reader) }
            if let year = candidate.metadata.year { words.append(String(year)) }
            if stores || words.isEmpty {
                let named = candidate.edition.stores.compactMap(AudibleStore.init(rawValue:)).map(\.shortTitle)
                if !named.isEmpty { words.append(named.joined(separator: ", ")) }
            }
            return words
        }
        var own = words(candidate, stores: false)
        let alike = others.contains { $0.id != candidate.id && words($0, stores: false) == own }
        if alike { own = words(candidate, stores: true) }
        return own.isEmpty ? "" : " (\(own.joined(separator: ", ")))"
    }

    /// "narrators", "series number", "description", "ISBN".
    private static func summaryName(_ field: MetadataField) -> String {
        switch field {
        case .isbn, .asin: label(field)
        default: label(field).lowercased()
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
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

    /// Nil when the candidate has no value for the field, or the value is the book's own.
    /// `ticked` says whether the value would be ticked to begin with: the book has none.
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

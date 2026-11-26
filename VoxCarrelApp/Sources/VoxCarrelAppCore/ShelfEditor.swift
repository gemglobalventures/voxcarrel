import Foundation
import Observation
import VoxCarrelCore

/// What a condition of a smart shelf is about. One kind may stand for two of the
/// engine's conditions: Length is "shorter than" or "longer than".
public enum ShelfConditionKind: String, CaseIterable, Identifiable, Sendable {
    case format, status, genre, genreGroup, author, narrator, series, tag, rating, length, pages, year, added, onAudible
    case inASeries

    public var id: String { rawValue }

    /// What the menu of kinds calls it.
    public var title: String {
        switch self {
        case .format: "Format"
        case .status: "Status"
        case .genre: "Genre"
        case .genreGroup: "Genre group"
        case .author: "Author"
        case .narrator: "Narrator"
        case .series: "Series"
        case .tag: "Tag"
        case .rating: "Rating"
        case .length: "Length"
        case .pages: "Pages"
        case .year: "Year"
        case .added: "Added"
        case .onAudible: "On Audible"
        case .inASeries: "In a series"
        }
    }

    /// Whether the kind's value is a name that is typed, or picked from the library's own.
    var isName: Bool {
        switch self {
        case .genre, .author, .narrator, .series, .tag: true
        default: false
        }
    }
}

/// One of the fixed values a condition can have.
public struct ShelfChoice: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
}

/// Whether a book must meet every condition or any one, as the sheet offers it.
public struct ShelfMatchChoice: Identifiable, Equatable, Sendable {
    public var matchesAll: Bool
    public var title: String

    public var id: Bool { matchesAll }
}

/// One condition as the editor's sheet shows it. Which controls it has, and their
/// words, follow from its kind; the sheet shows them and decides nothing.
public struct ShelfConditionRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public internal(set) var kind: ShelfConditionKind
    /// The id of the chosen one of `choices`; empty for a kind that has none.
    public internal(set) var choice: String
    /// The name, for a kind whose value is one.
    public internal(set) var text: String
    /// The stars, hours, year or days, for a kind that has a number.
    public internal(set) var number: Double
    /// The library's own names for the kind, to pick from; empty for other kinds.
    public internal(set) var suggestions: [String]

    private enum Choice {
        static let atLeast = "atLeast"
        static let unrated = "unrated"
        static let shorter = "shorter"
        static let longer = "longer"
        static let fewer = "fewer"
        static let more = "more"
        static let from = "from"
        static let to = "to"
        static let yes = "yes"
        static let no = "no"
    }

    /// A new condition of this kind, with the value the kind begins with.
    init(id: Int, kind: ShelfConditionKind, suggestions: [String]) {
        self.id = id
        self.kind = kind
        self.suggestions = suggestions
        text = ""
        choice = ""
        number = 0
        switch kind {
        case .format: choice = ShelfFormat.audiobook.rawValue
        case .status: choice = ReadStatus.unread.rawValue
        case .genreGroup: choice = GenreGroup.allCases.first?.rawValue ?? ""
        case .genre, .author, .narrator, .series, .tag: break
        case .rating: (choice, number) = (Choice.atLeast, 4)
        case .length: (choice, number) = (Choice.shorter, 6)
        case .pages: (choice, number) = (Choice.fewer, 300)
        case .year: (choice, number) = (Choice.from, 2000)
        case .added: number = 30
        case .onAudible, .inASeries: choice = Choice.yes
        }
    }

    /// A stored condition as a row.
    init(id: Int, condition: ShelfCondition, suggestions: (ShelfConditionKind) -> [String]) {
        func row(_ kind: ShelfConditionKind, choice: String? = nil, text: String? = nil, number: Double? = nil) -> Self {
            var row = ShelfConditionRow(id: id, kind: kind, suggestions: suggestions(kind))
            if let choice { row.choice = choice }
            if let text { row.text = text }
            if let number { row.number = number }
            return row
        }
        switch condition {
        case .format(let format): self = row(.format, choice: format.rawValue)
        case .status(let status): self = row(.status, choice: status.rawValue)
        case .genre(let name): self = row(.genre, text: name)
        case .genreGroup(let group): self = row(.genreGroup, choice: group.rawValue)
        case .author(let name): self = row(.author, text: name)
        case .narrator(let name): self = row(.narrator, text: name)
        case .series(let name): self = row(.series, text: name)
        case .tag(let name): self = row(.tag, text: name)
        case .ratingAtLeast(let stars): self = row(.rating, choice: Choice.atLeast, number: Double(stars))
        case .unrated: self = row(.rating, choice: Choice.unrated)
        case .shorterThan(let hours): self = row(.length, choice: Choice.shorter, number: hours)
        case .longerThan(let hours): self = row(.length, choice: Choice.longer, number: hours)
        case .fewerPagesThan(let pages): self = row(.pages, choice: Choice.fewer, number: Double(pages))
        case .morePagesThan(let pages): self = row(.pages, choice: Choice.more, number: Double(pages))
        case .yearFrom(let year): self = row(.year, choice: Choice.from, number: Double(year))
        case .yearTo(let year): self = row(.year, choice: Choice.to, number: Double(year))
        case .addedWithin(let days): self = row(.added, number: Double(days))
        case .onAudible(let wanted): self = row(.onAudible, choice: wanted ? Choice.yes : Choice.no)
        case .inASeries(let wanted): self = row(.inASeries, choice: wanted ? Choice.yes : Choice.no)
        }
    }

    // MARK: What the sheet shows

    /// The fixed values to choose between; empty for a kind that has none.
    public var choices: [ShelfChoice] {
        switch kind {
        case .format:
            [
                ShelfChoice(id: ShelfFormat.audiobook.rawValue, title: "Audiobook"),
                ShelfChoice(id: ShelfFormat.ebook.rawValue, title: "Ebook"),
                ShelfChoice(id: ShelfFormat.both.rawValue, title: "Audiobook and ebook"),
            ]
        case .status: ReadStatus.allCases.map { ShelfChoice(id: $0.rawValue, title: $0.title) }
        case .genreGroup: GenreGroup.allCases.map { ShelfChoice(id: $0.rawValue, title: $0.title) }
        case .rating: [ShelfChoice(id: Choice.atLeast, title: "Rated"), ShelfChoice(id: Choice.unrated, title: "Not rated")]
        case .length:
            [ShelfChoice(id: Choice.shorter, title: "Shorter than"), ShelfChoice(id: Choice.longer, title: "Longer than")]
        case .pages:
            [ShelfChoice(id: Choice.fewer, title: "Fewer than"), ShelfChoice(id: Choice.more, title: "More than")]
        case .year: [ShelfChoice(id: Choice.from, title: "From"), ShelfChoice(id: Choice.to, title: "Up to")]
        case .onAudible:
            [ShelfChoice(id: Choice.yes, title: "On Audible"), ShelfChoice(id: Choice.no, title: "Not on Audible")]
        case .inASeries:
            [ShelfChoice(id: Choice.yes, title: "In a series"), ShelfChoice(id: Choice.no, title: "Not in a series")]
        case .genre, .author, .narrator, .series, .tag, .added: []
        }
    }

    /// Whether the value is a name to type.
    public var showsText: Bool { kind.isName }

    /// What the name box says while it is empty.
    public var textPrompt: String { kind.title }

    /// Whether the value has a number: not a rating of "Not rated".
    public var showsNumber: Bool {
        switch kind {
        case .rating: choice == Choice.atLeast
        case .length, .pages, .year, .added: true
        default: false
        }
    }

    /// The words before the number, when no choice stands there: "In the last".
    public var prefix: String {
        kind == .added ? "In the last" : ""
    }

    /// The words after the number: "stars or more", "hours", "days". Empty for a year.
    public var unit: String {
        switch kind {
        case .rating: number == 1 ? "star or more" : "stars or more"
        case .length: number == 1 ? "hour" : "hours"
        case .pages: number == 1 ? "page" : "pages"
        case .added: number == 1 ? "day" : "days"
        default: ""
        }
    }

    /// The numbers the kind allows.
    public var numberRange: ClosedRange<Double> {
        switch kind {
        case .rating: 1...5
        case .length: 0.25...1000
        case .pages: 1...100_000
        case .year: 1...9999
        default: 1...36_500
        }
    }

    /// How far a step of the number's stepper goes.
    public var numberStep: Double {
        switch kind {
        case .length: 0.5
        case .pages: 50
        default: 1
        }
    }

    /// Whether the number is a whole one: every number but a length in hours.
    public var numberIsWhole: Bool { kind != .length }

    /// The number as the kind allows it: in range, and whole unless it is of hours.
    func allowed(_ value: Double) -> Double {
        guard value.isFinite else { return numberRange.lowerBound }
        let whole = numberIsWhole ? value.rounded() : value
        return min(max(whole, numberRange.lowerBound), numberRange.upperBound)
    }

    // MARK: What it asks of a book

    /// The condition the row stands for; nil while it is not complete: a name kind
    /// with no name.
    public var condition: ShelfCondition? {
        let name = text.trimmedOrNil
        let whole = Int(allowed(number))
        switch kind {
        case .format: return ShelfFormat(rawValue: choice).map(ShelfCondition.format)
        case .status: return ReadStatus(rawValue: choice).map(ShelfCondition.status)
        case .genre: return name.map(ShelfCondition.genre)
        case .genreGroup: return GenreGroup(rawValue: choice).map(ShelfCondition.genreGroup)
        case .author: return name.map(ShelfCondition.author)
        case .narrator: return name.map(ShelfCondition.narrator)
        case .series: return name.map(ShelfCondition.series)
        case .tag: return name.map(ShelfCondition.tag)
        case .rating: return choice == Choice.unrated ? .unrated : .ratingAtLeast(whole)
        case .length:
            return choice == Choice.longer ? .longerThan(hours: allowed(number)) : .shorterThan(hours: allowed(number))
        case .pages: return choice == Choice.more ? .morePagesThan(whole) : .fewerPagesThan(whole)
        case .year: return choice == Choice.to ? .yearTo(whole) : .yearFrom(whole)
        case .added: return .addedWithin(days: whole)
        case .onAudible: return .onAudible(choice != Choice.no)
        case .inASeries: return .inASeries(choice != Choice.no)
        }
    }
}

/// The state of the sheet that makes or changes a smart shelf. It decides everything
/// the sheet shows; the shelf is stored by the model when it is saved, and not before.
@MainActor @Observable
public final class ShelfEditor {
    @ObservationIgnored private unowned let model: AppModel
    /// The stored shelf being changed; nil for a new one.
    @ObservationIgnored private let shelfId: Int64?
    @ObservationIgnored private var nextRowId = 1
    /// Changes with every count asked for: an older answer is not the one wanted.
    @ObservationIgnored private var countGeneration = 0

    init(model: AppModel, shelf: SmartShelf?) {
        self.model = model
        shelfId = shelf?.id
        title = shelf == nil ? "New Smart Shelf" : "Edit Smart Shelf"
        name = shelf?.name ?? ""
        matchesAll = shelf?.matchesAll ?? true
        for condition in shelf?.conditions ?? [] {
            conditions.append(
                ShelfConditionRow(id: nextRowId, condition: condition, suggestions: model.shelfSuggestions(for:)))
            nextRowId += 1
        }
        // A new shelf has no conditions and holds nothing: there is nothing to ask.
        if shelf == nil { matchCount = 0 } else { recount() }
    }

    public let title: String
    public var name: String
    /// True when a book must meet every condition; false when any one will do.
    public var matchesAll: Bool {
        didSet {
            if matchesAll != oldValue { recount() }
        }
    }

    public let matchChoices = [
        ShelfMatchChoice(matchesAll: true, title: "All of these"),
        ShelfMatchChoice(matchesAll: false, title: "Any of these"),
    ]

    /// The kinds a condition can be, in the menu's order.
    public let kinds = ShelfConditionKind.allCases

    public private(set) var conditions: [ShelfConditionRow] = []

    // MARK: Changing the conditions

    /// Adds a condition of this kind after the others, with the kind's first value.
    public func addCondition(_ kind: ShelfConditionKind) {
        conditions.append(ShelfConditionRow(id: nextRowId, kind: kind, suggestions: model.shelfSuggestions(for: kind)))
        nextRowId += 1
        recount()
    }

    public func removeCondition(_ id: Int) {
        conditions.removeAll { $0.id == id }
        recount()
    }

    /// Makes the condition one of another kind, in the same place, with that kind's
    /// first value.
    public func setKind(_ kind: ShelfConditionKind, for id: Int) {
        change(id) { row in
            guard row.kind != kind else { return }
            row = ShelfConditionRow(id: id, kind: kind, suggestions: model.shelfSuggestions(for: kind))
        }
    }

    /// Chooses one of the condition's fixed values, by its id. One it does not have
    /// changes nothing.
    public func setChoice(_ choice: String, for id: Int) {
        change(id) { row in
            if row.choices.contains(where: { $0.id == choice }) { row.choice = choice }
        }
    }

    public func setText(_ text: String, for id: Int) {
        change(id) { $0.text = text }
    }

    /// Sets the condition's number, brought within what its kind allows.
    public func setNumber(_ number: Double, for id: Int) {
        change(id) { $0.number = $0.allowed(number) }
    }

    private func change(_ id: Int, _ body: (inout ShelfConditionRow) -> Void) {
        guard let index = conditions.firstIndex(where: { $0.id == id }) else { return }
        let before = conditions[index]
        body(&conditions[index])
        if conditions[index].condition != before.condition { recount() }
    }

    // MARK: What it would hold

    /// The shelf as it would be stored now: the conditions that are complete.
    var shelf: SmartShelf {
        SmartShelf(id: shelfId, name: name, matchesAll: matchesAll, conditions: conditions.compactMap(\.condition))
    }

    /// How many books the shelf would hold now, as the library last answered; nil
    /// until it has answered once.
    private var matchCount: Int?

    /// "No books match", "1 book matches", "23 books match". While the library is
    /// working it out again, the last answer stays. Empty until it has answered once.
    public var matchText: String {
        switch matchCount {
        case nil: ""
        case 0: "No books match"
        case 1: "1 book matches"
        case let count?: "\(count) books match"
        }
    }

    /// Asks the library how many books the shelf would hold now.
    private func recount() {
        countGeneration += 1
        let generation = countGeneration
        let shelf = shelf
        model.spawn { [weak self, model] in
            let count = await model.shelfCount(shelf)
            guard let self, let count, generation == self.countGeneration else { return }
            self.matchCount = count
        }
    }

    // MARK: Saving

    /// True while the shelf is being stored.
    public var isBusy: Bool {
        model.busyLabel != nil
    }

    /// Whether the shelf can be stored: it has a name that is not blank, and at least
    /// one condition that is complete. A name another shelf has is allowed.
    public var canSave: Bool {
        !isBusy && name.trimmedOrNil != nil && conditions.contains { $0.condition != nil }
    }

    /// Stores the shelf, shows its books and closes the sheet.
    public func save() async {
        guard canSave else { return }
        await model.saveShelf(shelf, from: self)
    }

    /// Closes the sheet. Nothing is stored.
    public func cancel() {
        model.closeShelfEditor()
    }
}

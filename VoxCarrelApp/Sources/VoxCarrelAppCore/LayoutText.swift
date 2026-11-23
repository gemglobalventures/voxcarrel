import Foundation
import VoxCarrelCore

/// One way of arranging the library's folders that Settings offers: a preset, or Custom.
public struct LayoutChoice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The preset's pattern; empty for Custom, whose pattern is whatever is typed.
    public var patternText: String
}

/// One folder a change of layout would move, as the preview shows it.
public struct LayoutExample: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var from: String
    public var to: String
}

/// One book a change of layout would leave where it is, and why.
public struct LayoutStayRow: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var reason: String
}

/// What changing the folder layout would do, in words, for the preview sheet.
public struct LayoutPreview: Equatable, Sendable {
    public var heading: String
    public var lines: [String]
    public var examples: [LayoutExample]
    public var staying: [LayoutStayRow]
    public var canApply: Bool
    /// The pattern the preview is of.
    public var pattern: FolderPattern
}

/// A book to show a layout with: its details, and whether it has audio.
public struct LayoutSample: Equatable, Sendable {
    public var metadata: BookMetadata
    public var hasAudio: Bool
}

/// The wording of the folder layout setting and its preview.
enum LayoutText {
    static let customId = "custom"
    static let planningLabel = "Working out the new layout…"
    static let changingLabel = "Changing the folder layout…"

    // MARK: FL1 The choices

    /// The presets by name, then Custom. A preset's id is its name.
    static let choices: [LayoutChoice] =
        FolderPattern.presets.map { LayoutChoice(id: $0.name, name: $0.name, patternText: $0.pattern.text) }
        + [LayoutChoice(id: customId, name: "Custom", patternText: "")]

    // MARK: FL2 What is wrong with a pattern

    /// Why the text cannot be used as a folder layout, as one sentence; nil when it can.
    static func problem(in text: String) -> String? {
        do {
            _ = try FolderPattern(text)
            return nil
        } catch let problem as FolderPatternProblem {
            return self.problem(problem)
        } catch {
            return "That layout cannot be used."
        }
    }

    static func problem(_ problem: FolderPatternProblem) -> String {
        switch problem {
        case .empty:
            "Type a layout, such as {Author}/{Title}."
        case .unknownToken(let token):
            "\(token) is not something a folder can be named after."
        case .unclosedBrace:
            "A { has no } to close it."
        case .unclosedBracket:
            "A [ has no ] to close it."
        case .nestedBracket:
            "Square brackets cannot go inside square brackets."
        case .strayClosing:
            "A } or ] has nothing to close."
        case .emptyLevel:
            "A folder has no name. Look for a / at the start or the end, or two together."
        case .tooManyLevels(let count):
            "That is \(count) folders deep. A layout can be \(FolderPattern.maxLevels) deep at most."
        case .lastLevelNeedsTitle:
            "The last folder must include {Title}."
        case .dotLevel:
            "A folder cannot be named “.” or “..”."
        case .tooLong:
            "The layout is too long. It can be \(FolderPattern.maxTextLength) characters at most."
        case .tooManyAlternatives:
            "A layout can have \(FolderPattern.maxAlternatives) alternatives at most, separated by |."
        }
    }

    /// Every token, as it is typed: "{Author} {Series} …".
    static let tokens = FolderToken.allCases.map { "{\($0.rawValue)}" }.joined(separator: " ")

    static let bracketsHelp =
        "Put a part in [square brackets] to leave it out for a book that has no value for it. "
        + "After a |, give a second layout for the books the first cannot file."

    static let unreadable =
        "The library's saved folder layout could not be read, so books are being filed by the standard layout. "
        + "Choose a layout and press Change Layout… to save one that can be read."

    static let onlyFoldersMove = "Only folders move. You can undo this from the Edit menu."

    // MARK: FL3 The example

    /// The sample shown when the library has no book in a series: a value for every token.
    static let builtInSample: LayoutSample = {
        var metadata = BookMetadata(title: "Red Rabbit", authors: ["Tom Clancy"])
        metadata.series = "Jack Ryan"
        metadata.seriesNumber = "3"
        metadata.narrators = ["Stephen Lang"]
        metadata.year = 2002
        metadata.genre = "Thriller"
        metadata.publisher = "Putnam"
        metadata.language = "English"
        return LayoutSample(metadata: metadata, hasAudio: true)
    }()

    /// Where the layout typed as `text` files the sample, or a sentence saying what
    /// the sample lacks; nil when the text cannot be used. Worked out from the
    /// pattern and the values alone: nothing on the disk is looked at.
    static func example(of text: String, for sample: LayoutSample) -> String? {
        guard let pattern = try? FolderPattern(text) else { return nil }
        let values = FolderPatternValues(metadata: sample.metadata, hasAudio: sample.hasAudio)
        if let folder = pattern.folder(for: values) { return folder }
        let names = pattern.missingTokens(for: values).map(\.noun)
        switch names.count {
        case 0: return "This book could not be filed: the layout leaves no name for its folder."
        case 1: return "This book could not be filed: no \(names[0])."
        default:
            return "This book could not be filed: no \(names.dropLast().joined(separator: ", ")) or \(names[names.count - 1])."
        }
    }

    // MARK: FL5 The preview

    static let maxExamples = 8

    /// - Parameter changesPattern: Whether the plan's pattern is another than the
    ///   library's own. A change to another pattern can be made though no folder
    ///   moves: new books are then filed by it.
    static func preview(of plan: LayoutChangePlan, changesPattern: Bool) -> LayoutPreview {
        let moves = plan.moves.count
        let heading =
            switch moves {
            // Nothing to do at all: the pattern is the library's own, and no book is
            // anywhere else than it files it.
            case 0 where !changesPattern && plan.staying.isEmpty: "Every book is already in place"
            case 0: "No book will move"
            case 1: "1 book will move"
            default: "\(moves) books will move"
            }
        var lines: [String] = []
        let staying = plan.staying.count
        if staying > 0 {
            lines.append(staying == 1 ? "1 book stays where it is" : "\(staying) books stay where they are")
        }
        if plan.unchangedCount > 0 {
            lines.append(plan.unchangedCount == 1 ? "1 is already in place" : "\(plan.unchangedCount) are already in place")
        }
        if plan.noFolderCount > 0 {
            lines.append(
                plan.noFolderCount == 1
                    ? "1 has no files, so it has no folder" : "\(plan.noFolderCount) have no files, so they have no folder")
        }
        if moves == 0, changesPattern { lines.append("New books will be filed by this layout") }
        return LayoutPreview(
            heading: heading, lines: lines,
            examples: exampleMoves(plan.moves).enumerated().map { index, move in
                LayoutExample(id: index, title: shownTitle(move.title), from: move.from, to: move.to)
            },
            staying: plan.staying.enumerated().map { index, stay in
                LayoutStayRow(id: index, title: shownTitle(stay.title), reason: stay.reason)
            },
            canApply: moves > 0 || changesPattern, pattern: plan.pattern)
    }

    /// Up to `maxExamples` of the moves, in the order given: the first move of each
    /// shape of change, then the earliest of the rest.
    private static func exampleMoves(_ moves: [LayoutMove]) -> [LayoutMove] {
        guard moves.count > maxExamples else { return moves }
        var chosen: [Int] = []
        var seen = Set<String>()
        for (index, move) in moves.enumerated() where chosen.count < maxExamples {
            if seen.insert(shape(of: move)).inserted { chosen.append(index) }
        }
        var taken = Set(chosen)
        for index in moves.indices where taken.count < maxExamples {
            taken.insert(index)
        }
        return taken.sorted().map { moves[$0] }
    }

    /// What kind of change a move is, whatever the book: how deep the folder was and
    /// will be, how many of the folders above it stay the same, and whether the
    /// folder keeps its own name.
    private static func shape(of move: LayoutMove) -> String {
        let from = move.from.split(separator: "/"), to = move.to.split(separator: "/")
        let shared = zip(from.dropLast(), to.dropLast()).prefix { $0 == $1 }.count
        return "\(from.count)>\(to.count) \(shared) \(from.last == to.last)"
    }

    // MARK: FL6 What is said afterwards

    /// What to tell when a change of layout left books behind: each with its reason.
    /// Nil when none stayed.
    static func result(of done: LayoutChangePlan) -> ResultSummary? {
        guard !done.staying.isEmpty else { return nil }
        let moved =
            switch done.moves.count {
            case 0: "No book moved"
            case 1: "1 book moved"
            default: "\(done.moves.count) books moved"
            }
        let stayed = done.staying.count == 1 ? "1 stayed where it was" : "\(done.staying.count) stayed where they were"
        return ResultSummary(
            headline: "\(moved), \(stayed)",
            problems: done.staying.map { .init(title: shownTitle($0.title), detail: $0.reason) }, isClean: false)
    }

    private static func shownTitle(_ title: String) -> String {
        title.trimmedOrNil ?? "Untitled book"
    }
}

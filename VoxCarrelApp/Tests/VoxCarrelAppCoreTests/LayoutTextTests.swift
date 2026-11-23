import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// The wording of the folder layout setting and its preview (folder layout plan, Task 4).
@Suite struct LayoutTextTests {
    // MARK: FL1 The choices

    @Test func fl1_theChoicesAreThePresetsByNameThenCustom() {
        let choices = LayoutText.choices
        #expect(choices.map(\.name) == [
            "Author / Series / Title", "Author / Title", "Series / Title", "Kind / Author / Series / Title", "Custom",
        ])
        #expect(choices.map(\.patternText) == FolderPattern.presets.map(\.pattern.text) + [""])
        #expect(Set(choices.map(\.id)).count == choices.count)
        #expect(choices.last?.id == LayoutText.customId)
    }

    // MARK: FL2 What is wrong with a pattern

    @Test(arguments: [
        ("", "Type a layout, such as {Author}/{Title}."),
        ("   ", "Type a layout, such as {Author}/{Title}."),
        ("{Auther}/{Title}", "{Auther} is not something a folder can be named after."),
        ("{Author/{Title}", "A { has no } to close it."),
        ("{Author}/[{Series}/{Title}", "A [ has no ] to close it."),
        ("[[{Series}]]/{Title}", "Square brackets cannot go inside square brackets."),
        ("{Author}]/{Title}", "A } or ] has nothing to close."),
        ("{Author}//{Title}", "A folder has no name. Look for a / at the start or the end, or two together."),
        ("/{Title}", "A folder has no name. Look for a / at the start or the end, or two together."),
        ("a/b/c/d/e/f/{Title}", "That is 7 folders deep. A layout can be 6 deep at most."),
        ("{Author}/{Series}", "The last folder must include {Title}."),
        ("{Author}/[{Title}]", "The last folder must include {Title}."),
        ("{Author}/../{Title}", "A folder cannot be named “.” or “..”."),
        (String(repeating: "a", count: 501) + "{Title}", "The layout is too long. It can be 500 characters at most."),
        ("{Title}|{Title}|{Title}|{Title}", "A layout can have 3 alternatives at most, separated by |."),
    ])
    func fl2_eachProblemHasOnePlainSentence(text: String, sentence: String) {
        #expect(LayoutText.problem(in: text) == sentence)
    }

    @Test func fl2_aUsableLayoutHasNoProblem() {
        #expect(LayoutText.problem(in: "{Author}/{Title}") == nil)
        #expect(LayoutText.problem(in: "  {author}/[{series}/]{TITLE}  ") == nil)
        for preset in FolderPattern.presets {
            #expect(LayoutText.problem(in: preset.pattern.text) == nil)
        }
    }

    @Test func fl2_everyProblemIsWorded() {
        let problems: [FolderPatternProblem] = [
            .empty, .unknownToken("{X}"), .unclosedBrace, .unclosedBracket, .nestedBracket, .strayClosing,
            .emptyLevel, .tooManyLevels(9), .lastLevelNeedsTitle, .dotLevel, .tooLong, .tooManyAlternatives,
        ]
        let sentences = problems.map(LayoutText.problem)
        #expect(sentences.allSatisfy { $0.hasSuffix(".") && !$0.isEmpty })
        #expect(Set(sentences).count == problems.count)
    }

    // MARK: FL3 The example

    private var plain: LayoutSample {
        LayoutSample(metadata: BookMetadata(title: "Quiet Rivers", authors: ["Amara Okafor"]), hasAudio: false)
    }

    @Test func fl3_theBuiltInSampleIsFiledByThePattern() {
        let sample = LayoutText.builtInSample
        #expect(LayoutText.example(of: FolderPattern.standard.text, for: sample) == "Tom Clancy/Jack Ryan/3 - Red Rabbit")
        #expect(LayoutText.example(of: "{Author}/{Title}", for: sample) == "Tom Clancy/Red Rabbit")
        #expect(LayoutText.example(of: "{Kind}/{Author}/{Title}", for: sample) == "Audiobooks/Tom Clancy/Red Rabbit")
        // It has a value for everything a folder can be named after.
        for token in FolderToken.allCases {
            #expect(LayoutText.example(of: "{\(token.rawValue)}/{Title}", for: sample)?.hasSuffix("/Red Rabbit") == true)
        }
    }

    @Test func fl3_aSampleThatLacksWhatTheLayoutNeedsSaysSo() {
        #expect(LayoutText.example(of: "{Author}/[{Series}/]{Title}", for: plain) == "Amara Okafor/Quiet Rivers")
        #expect(LayoutText.example(of: "{Kind}/{Title}", for: plain) == "Ebooks/Quiet Rivers")
        #expect(LayoutText.example(of: "{Narrator}/{Title}", for: plain) == "This book could not be filed: no narrator.")
        #expect(LayoutText.example(of: "{Narrator}/{Year}/{Title}", for: plain)
            == "This book could not be filed: no narrator or year.")
        #expect(LayoutText.example(of: "{Series}/{Number} {Year}/{Narrator} {Title}", for: plain)
            == "This book could not be filed: no series, series number, year or narrator.")
    }

    @Test func fl3_aLayoutThatCannotBeUsedHasNoExample() {
        #expect(LayoutText.example(of: "{Auther}/{Title}", for: plain) == nil)
        #expect(LayoutText.example(of: "", for: plain) == nil)
    }

    // MARK: FL5 The preview

    private func plan(moves: Int, staying: Int = 0, unchanged: Int = 0, noFolder: Int = 0) throws -> LayoutChangePlan {
        LayoutChangePlan(
            pattern: try FolderPattern("{Author}/{Title}"),
            moves: (0..<moves).map {
                LayoutMove(bookId: Int64($0 + 1), title: "Book \($0)", from: "Ann/Series/Book \($0)", to: "Ann/Book \($0)")
            },
            staying: (0..<staying).map {
                LayoutStay(bookId: Int64(1000 + $0), title: "Stay \($0)", reason: "Reason \($0).")
            },
            unchangedCount: unchanged, noFolderCount: noFolder)
    }

    @Test func fl5_theCountsAreSaidInThePlural() throws {
        let preview = LayoutText.preview(of: try plan(moves: 312, staying: 4, unchanged: 18, noFolder: 2), changesPattern: true)
        #expect(preview.heading == "312 books will move")
        #expect(preview.lines == [
            "4 books stay where they are", "18 are already in place", "2 have no files, so they have no folder",
        ])
        #expect(preview.canApply)
        #expect(preview.pattern.text == "{Author}/{Title}")
    }

    @Test func fl5_theCountsAreSaidInTheSingular() throws {
        let preview = LayoutText.preview(of: try plan(moves: 1, staying: 1, unchanged: 1, noFolder: 1), changesPattern: true)
        #expect(preview.heading == "1 book will move")
        #expect(preview.lines == [
            "1 book stays where it is", "1 is already in place", "1 has no files, so it has no folder",
        ])
    }

    @Test func fl5_aLineAppearsOnlyWhenItsCountIsAboveZero() throws {
        #expect(LayoutText.preview(of: try plan(moves: 5), changesPattern: true).lines.isEmpty)
        #expect(LayoutText.preview(of: try plan(moves: 5, unchanged: 2), changesPattern: true).lines == ["2 are already in place"])
        #expect(LayoutText.preview(of: try plan(moves: 5, staying: 3), changesPattern: true).lines == ["3 books stay where they are"])
        #expect(LayoutText.preview(of: try plan(moves: 5, noFolder: 1), changesPattern: true).lines
            == ["1 has no files, so it has no folder"])
    }

    @Test func fl5_withNothingToMoveOnlyANewLayoutCanStillBeApplied() throws {
        // A new layout for a library whose books are all in place already (or that has
        // none): nothing moves, and the layout is what new books will be filed by.
        let changed = LayoutText.preview(of: try plan(moves: 0, unchanged: 7), changesPattern: true)
        #expect(changed.heading == "No book will move")
        #expect(changed.lines == ["7 are already in place", "New books will be filed by this layout"])
        #expect(changed.examples.isEmpty)
        #expect(changed.canApply)
        // The layout already in use, with nothing to move: there is nothing to do.
        let same = LayoutText.preview(of: try plan(moves: 0, unchanged: 7), changesPattern: false)
        #expect(same.lines == ["7 are already in place"])
        #expect(!same.canApply)
        // The layout already in use, with books out of place: they can be put in place.
        #expect(LayoutText.preview(of: try plan(moves: 2), changesPattern: false).canApply)
    }

    @Test func fl5_everyBookThatStaysIsListedWithItsReasonAsGiven() throws {
        let preview = LayoutText.preview(of: try plan(moves: 1, staying: 30), changesPattern: true)
        try #require(preview.staying.count == 30)
        #expect(preview.staying.map(\.id) == Array(0..<30))
        #expect(preview.staying[7] == LayoutStayRow(id: 7, title: "Stay 7", reason: "Reason 7."))
        var untitled = try plan(moves: 1)
        untitled.staying = [LayoutStay(bookId: 1, title: "  ", reason: "Its folder is missing.")]
        #expect(LayoutText.preview(of: untitled, changesPattern: true).staying.map(\.title) == ["Untitled book"])
    }

    @Test func fl5_thereAreAtMostEightExamplesInThePlansOrder() throws {
        let few = LayoutText.preview(of: try plan(moves: 3), changesPattern: true)
        #expect(few.examples == [
            LayoutExample(id: 0, title: "Book 0", from: "Ann/Series/Book 0", to: "Ann/Book 0"),
            LayoutExample(id: 1, title: "Book 1", from: "Ann/Series/Book 1", to: "Ann/Book 1"),
            LayoutExample(id: 2, title: "Book 2", from: "Ann/Series/Book 2", to: "Ann/Book 2"),
        ])
        let many = LayoutText.preview(of: try plan(moves: 40), changesPattern: true)
        #expect(many.examples.map(\.title) == (0..<8).map { "Book \($0)" })
        #expect(many.examples.map(\.id) == Array(0..<8))
    }

    @Test func fl5_theExamplesPreferOneMovePerShapeOfChange() throws {
        var plan = try plan(moves: 30)
        // Among thirty moves out of a series folder: one deeper, one renamed in place,
        // one to another top folder, and a second of that last shape.
        plan.moves[12] = LayoutMove(bookId: 13, title: "Deeper", from: "Ann/Deeper", to: "Ann/Saga/1 - Deeper")
        plan.moves[20] = LayoutMove(bookId: 21, title: "Renamed", from: "Ann/Old Name", to: "Ann/Renamed")
        plan.moves[27] = LayoutMove(bookId: 28, title: "Across", from: "Ann/Across", to: "Bea/Across")
        plan.moves[29] = LayoutMove(bookId: 30, title: "Across Too", from: "Ann/Across Too", to: "Cy/Across Too")
        let examples = LayoutText.preview(of: plan, changesPattern: true).examples
        try #require(examples.count == 8)
        // Each shape once, then the rest from the start; shown in the plan's order.
        #expect(examples.map(\.title) == ["Book 0", "Book 1", "Book 2", "Book 3", "Book 4", "Deeper", "Renamed", "Across"])
        #expect(examples.map(\.id) == Array(0..<8))
        #expect(examples[5].to == "Ann/Saga/1 - Deeper")
    }

    // MARK: FL6 What is said afterwards

    @Test func fl6_nothingIsSaidWhenEveryBookMoved() throws {
        #expect(LayoutText.result(of: try plan(moves: 12, unchanged: 3, noFolder: 1)) == nil)
        #expect(LayoutText.result(of: try plan(moves: 0)) == nil)
    }

    @Test func fl6_theBooksThatStayedAreNamedWithTheirReasons() throws {
        let result = try #require(LayoutText.result(of: try plan(moves: 3, staying: 2)))
        #expect(result.headline == "3 books moved, 2 stayed where they were")
        #expect(result.problems == [
            ResultSummary.Line(title: "Stay 0", detail: "Reason 0."), ResultSummary.Line(title: "Stay 1", detail: "Reason 1."),
        ])
        #expect(!result.isClean)
        #expect(LayoutText.result(of: try plan(moves: 1, staying: 1))?.headline == "1 book moved, 1 stayed where it was")
        #expect(LayoutText.result(of: try plan(moves: 0, staying: 1))?.headline == "No book moved, 1 stayed where it was")
    }
}

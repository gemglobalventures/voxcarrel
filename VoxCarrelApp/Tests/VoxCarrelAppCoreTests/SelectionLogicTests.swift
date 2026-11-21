import Testing
import VoxCarrelAppCore

/// A7
@Suite struct SelectionLogicTests {
    private let order: [Int64] = [10, 20, 30, 40, 50]

    private func click(
        _ id: Int64, _ modifiers: SelectionLogic.Modifiers = [], selection: Set<Int64> = [], anchor: Int64? = nil
    ) -> (selection: Set<Int64>, anchor: Int64?) {
        SelectionLogic.click(id, modifiers: modifiers, order: order, selection: selection, anchor: anchor)
    }

    /// A7
    @Test func plainClickSelectsOnlyThatBookAndSetsTheAnchor() {
        let result = click(30, selection: [10, 20], anchor: 10)
        #expect(result.selection == [30])
        #expect(result.anchor == 30)
    }

    /// A7
    @Test func commandClickTogglesAndSetsTheAnchor() {
        let added = click(40, .command, selection: [10], anchor: 10)
        #expect(added.selection == [10, 40])
        #expect(added.anchor == 40)

        let removed = click(10, .command, selection: [10, 40], anchor: 40)
        #expect(removed.selection == [40])
        #expect(removed.anchor == 10)
    }

    /// A7
    @Test func shiftClickSelectsTheRangeFromTheAnchorAndKeepsIt() {
        let down = click(40, .shift, selection: [20], anchor: 20)
        #expect(down.selection == [20, 30, 40])
        #expect(down.anchor == 20)

        // Backwards, and replacing what was selected.
        let up = click(10, .shift, selection: [20, 30, 40, 50], anchor: 20)
        #expect(up.selection == [10, 20])
        #expect(up.anchor == 20)

        let same = click(20, .shift, selection: [20], anchor: 20)
        #expect(same.selection == [20])
        #expect(same.anchor == 20)
    }

    /// A7
    @Test func shiftClickWithNoUsableAnchorIsAPlainClick() {
        let none = click(30, .shift, selection: [10, 20], anchor: nil)
        #expect(none.selection == [30])
        #expect(none.anchor == 30)

        let gone = click(30, .shift, selection: [10], anchor: 99)
        #expect(gone.selection == [30])
        #expect(gone.anchor == 30)
    }

    /// A7, beyond the rule: with both keys the range is added to the selection, as in the Finder.
    @Test func commandShiftClickAddsTheRange() {
        let result = click(40, [.command, .shift], selection: [10, 30], anchor: 30)
        #expect(result.selection == [10, 30, 40])
        #expect(result.anchor == 30)
    }

    // MARK: G2 Arrow keys

    /// Five books in three columns:  10 20 30 / 40 50
    private func move(
        _ direction: SelectionLogic.Direction, columns: Int = 3, selection: Set<Int64> = [], anchor: Int64? = nil
    ) -> Int64? {
        SelectionLogic.move(direction, columns: columns, order: order, selection: selection, anchor: anchor)
    }

    /// G2
    @Test func leftAndRightMoveAlongTheOrderAndStopAtItsEnds() {
        #expect(move(.right, selection: [20], anchor: 20) == 30)
        #expect(move(.left, selection: [20], anchor: 20) == 10)
        // Across the end of a row.
        #expect(move(.right, selection: [30], anchor: 30) == 40)
        #expect(move(.left, selection: [40], anchor: 40) == 30)
        #expect(move(.left, selection: [10], anchor: 10) == 10)
        #expect(move(.right, selection: [50], anchor: 50) == 50)
    }

    /// G2
    @Test func upAndDownMoveByARowOfColumns() {
        #expect(move(.down, selection: [10], anchor: 10) == 40)
        #expect(move(.up, selection: [50], anchor: 50) == 20)
        #expect(move(.up, selection: [20], anchor: 20) == 20)
        #expect(move(.down, selection: [40], anchor: 40) == 40)
        // With one column, as in a list.
        #expect(move(.down, columns: 1, selection: [10], anchor: 10) == 20)
        #expect(move(.up, columns: 1, selection: [30], anchor: 30) == 20)
    }

    /// G2: below a book in the last full row there may be nothing; down then goes to the last book.
    @Test func downFromAboveAShortLastRowGoesToTheLastBook() {
        #expect(move(.down, selection: [30], anchor: 30) == 50)
        #expect(move(.down, selection: [20], anchor: 20) == 50)
    }

    /// G2
    @Test func withNothingSelectedTheFirstOrLastBookIsChosen() {
        #expect(move(.right) == 10)
        #expect(move(.down) == 10)
        #expect(move(.left) == 50)
        #expect(move(.up) == 50)
        // A selection none of which is shown counts as nothing.
        #expect(move(.down, selection: [99], anchor: 99) == 10)
    }

    /// G2: with several selected the move starts from the anchor; without a usable
    /// anchor, from the end of the selection the arrow points towards.
    @Test func withSeveralSelectedTheMoveStartsFromTheAnchor() {
        #expect(move(.right, selection: [10, 20, 40], anchor: 20) == 30)
        #expect(move(.right, selection: [10, 20, 40], anchor: nil) == 50)
        #expect(move(.left, selection: [20, 40], anchor: 99) == 10)
        // An anchor that is not selected is not used.
        #expect(move(.down, selection: [20], anchor: 10) == 50)
    }

    /// G2
    @Test func nothingToMoveToInAnEmptyListAndAColumnCountBelowOneIsOne() {
        #expect(SelectionLogic.move(.down, columns: 3, order: [], selection: [], anchor: nil) == nil)
        #expect(move(.down, columns: 0, selection: [10], anchor: 10) == 20)
    }
}

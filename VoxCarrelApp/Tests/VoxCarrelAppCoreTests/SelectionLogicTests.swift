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
}

import Testing

@testable import VoxCarrelAppCore

/// V5: one sheet at a time, and never one kind of sheet turned into another in place.
@Suite struct SheetPresentationTests {
    private struct Sheet: Identifiable, Equatable {
        var id: String
        var text = ""
    }

    @Test func nothingIsShownAtFirst() {
        let sheets = SheetPresentation<Sheet>()
        #expect(sheets.presented == nil)
        #expect(sheets.isIdle)
    }

    @Test func aWantedSheetIsShownAtOnceWhenNoneIsUp() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "check"))
        #expect(sheets.presented == Sheet(id: "check"))
        #expect(!sheets.isIdle)
    }

    @Test func theSameKindOfSheetIsKeptUpWithWhatItShowsNow() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "review", text: "one"))
        sheets.want(Sheet(id: "review", text: "two"))
        #expect(sheets.presented == Sheet(id: "review", text: "two"))
    }

    @Test func aSheetNoLongerWantedIsClosed() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "result"))
        sheets.want(nil)
        #expect(sheets.presented == nil)
        // Still on its way out.
        #expect(!sheets.isIdle)
        sheets.didDismiss(wanted: nil)
        #expect(sheets.presented == nil)
        #expect(sheets.isIdle)
    }

    /// The defect: the review shown in the launch check's small sheet.
    @Test func anotherKindOfSheetWaitsForTheOneThatIsUpToClose() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "check"))
        sheets.want(Sheet(id: "review"))
        #expect(sheets.presented == nil)
        #expect(!sheets.isIdle)
        sheets.didDismiss(wanted: Sheet(id: "review"))
        #expect(sheets.presented == Sheet(id: "review"))
    }

    @Test func whatIsWantedWhileASheetClosesIsShownOnlyWhenItHasClosed() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "review"))
        sheets.want(nil)
        // The progress sheet falls due, and the result follows, before the review has gone.
        sheets.want(Sheet(id: "progress"))
        #expect(sheets.presented == nil)
        sheets.want(Sheet(id: "result"))
        #expect(sheets.presented == nil)
        sheets.didDismiss(wanted: Sheet(id: "result"))
        #expect(sheets.presented == Sheet(id: "result"))
    }

    /// A sheet that is wanted again while it closes is still closed and shown afresh.
    @Test func aSheetWantedAgainWhileItClosesComesBackWhenItHasClosed() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "check"))
        sheets.want(Sheet(id: "progress"))
        sheets.want(Sheet(id: "check"))
        #expect(sheets.presented == nil)
        sheets.didDismiss(wanted: Sheet(id: "check"))
        #expect(sheets.presented == Sheet(id: "check"))
        #expect(!sheets.isIdle)
    }

    @Test func aDismissalThatWasNotAskedForShowsWhatIsWanted() {
        var sheets = SheetPresentation<Sheet>()
        sheets.want(Sheet(id: "check"))
        sheets.didDismiss(wanted: Sheet(id: "check"))
        #expect(sheets.presented == Sheet(id: "check"))
    }
}

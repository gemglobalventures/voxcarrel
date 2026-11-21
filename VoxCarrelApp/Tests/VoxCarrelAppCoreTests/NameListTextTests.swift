import Testing
import VoxCarrelAppCore

@Suite struct NameListTextTests {
    /// N1
    @Test func splitsOnSemicolonsAndTrimsEachName() {
        #expect(NameListText.names(from: " Terry Pratchett ;Neil Gaiman  ") == ["Terry Pratchett", "Neil Gaiman"])
    }

    /// N1
    @Test func dropsEmptyNames() {
        #expect(NameListText.names(from: "A;; ;B;") == ["A", "B"])
        #expect(NameListText.names(from: "").isEmpty)
        #expect(NameListText.names(from: "  ;  ").isEmpty)
    }

    /// N1
    @Test func removesLaterDuplicatesIgnoringCase() {
        #expect(NameListText.names(from: "Ann Lee; ann lee; Bo; ANN LEE; bo") == ["Ann Lee", "Bo"])
    }

    /// N1
    @Test func doesNotSplitOnCommasOrAmpersands() {
        #expect(NameListText.names(from: "Le Guin, Ursula K.; Strugatsky & Strugatsky")
            == ["Le Guin, Ursula K.", "Strugatsky & Strugatsky"])
    }

    @Test func joinsWithSemicolonAndSpace() {
        #expect(NameListText.text(from: ["A", "B"]) == "A; B")
        #expect(NameListText.text(from: []) == "")
        #expect(NameListText.names(from: NameListText.text(from: ["Le Guin, Ursula K.", "B"]))
            == ["Le Guin, Ursula K.", "B"])
    }
}

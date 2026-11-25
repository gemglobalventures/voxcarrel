import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// HL11–HL13: Kindle as a place a book is owned. Nothing here reaches the network.
@MainActor
@Suite struct HighlightsKindleTests {
    typealias S = HighlightSamples

    /// A demo library that also has "Deep Work", which is on Kindle and has no files here.
    private func demoWithKindleBook(asin: String? = "B00KINDLE01") async throws -> (h: Harness, kindle: Int64) {
        let h = try await Harness.demo()
        try await h.bringIn([S.kindleBook("Deep Work", author: "Cal Newport", asin: asin, [S.incoming("1", "Focus.")])])
        return (h, try h.id("Deep Work"))
    }

    private func row(_ h: Harness, _ id: Int64) throws -> BookRow {
        try #require(h.model.rows.first { $0.id == id })
    }

    @Test func HL11_onKindleIsInTheSidebarOnlyWhileABookIsOwnedThere() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.showsOnKindle)
        #expect(h.model.onKindleCount == 0)
        #expect(!SidebarItem.fixed.contains(.onKindle))
        #expect(h.model.title(of: .onKindle) == "On Kindle")
        // Chosen while there is no such book, it has nothing to show: All Books is shown.
        h.model.sidebarSelection = .onKindle
        await h.model.settle()
        await h.model.reloadAll()
        #expect(h.model.sidebarSelection == .allBooks)

        try await h.bringIn([
            S.kindleBook("Deep Work", author: "Cal Newport", [S.incoming("1", "Focus.")]),
            S.kindleBook("Zen Mind", asin: "B00KINDLE02", [S.incoming("2", "Sit.")]),
        ])
        #expect(h.model.showsOnKindle)
        #expect(h.model.onKindleCount == 2)
        #expect(h.model.sidebar.counts[.onAudible] == 0)
        h.model.sidebarSelection = .onKindle
        await h.model.settle()
        #expect(h.titles == ["Deep Work", "Zen Mind"])
        #expect(h.model.windowTitle == "On Kindle")
        let row = try #require(h.model.rows.first)
        #expect(row.hasEbook && !row.hasAudio && !row.hasFiles)
        #expect(row.isOnKindle && !row.isOnAudible)
        #expect(!row.book.needsAttention)
        // A search narrows it as it does any list.
        h.model.searchText = "zen"
        await h.model.settle()
        #expect(h.titles == ["Zen Mind"])
        h.model.searchText = ""
        await h.model.settle()

        // The last of them gone, the item goes, and All Books is shown.
        h.model.requestRemove(Set(h.model.rows.map(\.id)))
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(!h.model.showsOnKindle)
        #expect(h.model.sidebarSelection == .allBooks)
    }

    @Test func HL12_aKindleBookSaysWhereItIsInTheWordsOfItsOwnPlace() async throws {
        let (h, kindle) = try await demoWithKindleBook()
        let row = try row(h, kindle)
        #expect(row.whereaboutsText == "On Kindle, not on this Mac")
        #expect(row.formatsHelpText == "On Kindle, not on this Mac")
        #expect(row.summaryText.contains("On Kindle, not on this Mac"))
        #expect(!row.summaryText.contains("Audible"))
        #expect(row.readTitle == "Open on Kindle")
        #expect(row.readHelpText == "Open this book in Kindle on the web")
        #expect(row.listenTitle == "Listen")
        #expect(h.model.readTitle(for: [kindle]) == "Open on Kindle")
        #expect(h.model.listenTitle(for: [kindle]) == "Listen")
        #expect(row.ownedKinds == [.kindle])
        try await h.select("Deep Work")
        #expect(h.model.inspectorOwnershipText == "On Kindle · not on this Mac")
        #expect(h.detail?.noFilesText == "This book has no files on this Mac.")
        // It is no Audible book: the switch is off.
        #expect(!h.model.inspectorIsOnAudible)

        // A book with files that is on Kindle too.
        let rivers = try h.id("Quiet Rivers")
        let service = try h.service()
        try service.setExternalCopies([ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00RIVERS1")], for: rivers)
        await h.model.reloadAll()
        let here = try self.row(h, rivers)
        #expect(here.whereaboutsText == "Also on Kindle")
        #expect(here.formatsHelpText.hasSuffix(". Also on Kindle"))
        #expect(h.model.readTitle(for: [rivers]) == (here.opensOnKindle ? "Open on Kindle" : "Read"))

        // On both, each is named; an Audible book says what it always said.
        try service.setExternalCopies(
            [
                ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE01"),
                ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B00AUDIBLE"),
            ], for: kindle)
        await h.model.reloadAll()
        let both = try self.row(h, kindle)
        #expect(both.whereaboutsText == "On Audible and Kindle, not on this Mac")
        #expect(both.ownedKinds == [.audible, .kindle])
        #expect(h.model.inspectorOwnershipText == "On Audible (United Kingdom) and Kindle · not on this Mac")
        #expect(both.listenTitle == "Open on Audible")
        try service.setExternalCopies([ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B00AUDIBLE")], for: kindle)
        await h.model.reloadAll()
        let audible = try self.row(h, kindle)
        #expect(audible.whereaboutsText == "On Audible, not on this Mac")
        #expect(audible.readTitle == "Read")
        #expect(h.model.inspectorOwnershipText == "On Audible (United Kingdom) · not on this Mac")
    }

    @Test func HL13_openingAKindleBookOpensItInKindleOnTheWeb() async throws {
        let (h, kindle) = try await demoWithKindleBook()
        let row = try row(h, kindle)
        let address = try #require(URL(string: "https://read.amazon.com/?asin=B00KINDLE01"))
        #expect(row.kindleAddress == address)
        #expect(row.opensOnKindle && row.canRead)
        let commands = h.model.commands(for: [kindle])
        #expect(commands.open && commands.read && !commands.listen && !commands.reveal)

        h.model.read(kindle)
        await h.model.settle()
        #expect(h.opener.openedWeb == [address])
        h.model.open(kindle)
        await h.model.settle()
        #expect(h.opener.openedWeb == [address, address])
        #expect(h.opener.opened.isEmpty && h.model.alert == nil)
        // Listening has nothing to open.
        h.model.listen(kindle)
        await h.model.settle()
        #expect(h.opener.openedWeb.count == 2)
        #expect(h.model.alert == "This book has no files on this Mac.")
    }

    @Test func HL13_aKindleBookWithNoIDHasNothingToOpen() async throws {
        let (h, kindle) = try await demoWithKindleBook(asin: nil)
        let row = try row(h, kindle)
        #expect(row.isOnKindle && row.kindleAddress == nil)
        #expect(!row.opensOnKindle && !row.canRead)
        #expect(row.readTitle == "Read")
        let commands = h.model.commands(for: [kindle])
        #expect(!commands.open && !commands.read && !commands.listen)
        // Asked all the same, nothing is opened and it is said why.
        h.model.read(kindle)
        await h.model.settle()
        #expect(h.opener.openedWeb.isEmpty && h.opener.opened.isEmpty)
        #expect(h.model.alert == "This book has no files on this Mac.")

        // An ID that is not one is put in no address.
        try h.service().setExternalCopies([ExternalCopy(kind: .kindle, form: .ebook, itemId: "x&y=1 2")], for: kindle)
        await h.model.reloadAll()
        #expect(try self.row(h, kindle).kindleAddress == nil)
    }

    @Test func HL13_anEbookFileHereIsOpenedBeforeTheKindleCopy() async throws {
        let h = try await Harness.demo()
        // A book of the demo library that has an ebook file.
        let ebook = try #require(h.model.rows.first { $0.hasFiles && $0.formats.contains { $0.defaultRole == .ebook } })
        try h.service().setExternalCopies([ExternalCopy(kind: .kindle, form: .ebook, itemId: "B00KINDLE09")], for: ebook.id)
        await h.model.reloadAll()
        let row = try row(h, ebook.id)
        #expect(row.isOnKindle && !row.opensOnKindle && row.canRead)
        #expect(row.readTitle == "Read")
        h.model.read(ebook.id)
        await h.model.settle()
        #expect(h.opener.openedWeb.isEmpty)
        #expect(h.opener.opened.count == 1)
    }
}

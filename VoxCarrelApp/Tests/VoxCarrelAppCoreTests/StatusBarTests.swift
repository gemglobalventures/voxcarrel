import Foundation
import Testing
import VoxCarrelCore
@testable import VoxCarrelAppCore

/// SB1–SB4: the status bar along the bottom of the library window.
@Suite struct StatusBarTests {
    @Test func SB1_theBooksInTheListAndTheirLength() {
        #expect(StatusBarText.shown(count: 0, seconds: 0, selected: 0, selectedSeconds: 0) == "No books")
        #expect(StatusBarText.shown(count: 1, seconds: 0, selected: 0, selectedSeconds: 0) == "1 book")
        #expect(StatusBarText.shown(count: 14, seconds: 166_200, selected: 0, selectedSeconds: 0) == "14 books · 46 h 10 min")
        #expect(StatusBarText.shown(count: 1204, seconds: 30, selected: 0, selectedSeconds: 0) == "1,204 books")
    }

    @Test func SB2_aSelectionIsCountedWithItsOwnLength() {
        #expect(StatusBarText.shown(count: 14, seconds: 166_200, selected: 3, selectedSeconds: 45_000) == "3 of 14 books selected · 12 h 30 min")
        #expect(StatusBarText.shown(count: 14, seconds: 166_200, selected: 1, selectedSeconds: 0) == "1 of 14 books selected")
        #expect(StatusBarText.shown(count: 1, seconds: 0, selected: 1, selectedSeconds: 2700) == "1 of 1 book selected · 45 min")
    }

    @Test func SB3_theWholeLibrary() {
        #expect(StatusBarText.library(books: 22, audiobooks: 14, ebooks: 9, unread: 8, audioSeconds: 763_200)
            == "Library: 22 books · 14 audiobooks · 9 ebooks · 212 h of audio · 8 unread")
        #expect(StatusBarText.library(books: 1, audiobooks: 1, ebooks: 0, unread: 0, audioSeconds: 600) == "Library: 1 book · 1 audiobook")
        #expect(StatusBarText.library(books: 0, audiobooks: 0, ebooks: 0, unread: 0, audioSeconds: 0) == "Library: 0 books")
        #expect(StatusBarText.library(books: 12_500, audiobooks: 3_000, ebooks: 1, unread: 0, audioSeconds: 36_000_000)
            == "Library: 12,500 books · 3,000 audiobooks · 1 ebook · 10,000 h of audio")
    }

    @Test func SB4_lengthsAndNumbers() {
        #expect(StatusBarText.length(59) == "1 min")
        #expect(StatusBarText.length(3600) == "1 h")
        #expect(StatusBarText.length(3_600_000 + 1800) == "1,000 h 30 min")
        #expect(StatusBarText.number(999) == "999" && StatusBarText.number(1000) == "1,000" && StatusBarText.number(1_234_567) == "1,234,567")
    }

    @Test func SB5_whatTheLibraryTakesOnDisk() {
        #expect(StatusBarText.size(0) == nil && StatusBarText.size(999_999) == nil)
        #expect(StatusBarText.size(1_000_000) == "1 MB")
        #expect(StatusBarText.size(640_400_000) == "640 MB")
        #expect(StatusBarText.size(38_240_000_000) == "38.2 GB")
        #expect(StatusBarText.size(2_000_000_000) == "2 GB")
        #expect(StatusBarText.size(1_440_000_000_000) == "1.4 TB")
        #expect(StatusBarText.library(books: 22, audiobooks: 14, ebooks: 9, unread: 8, audioSeconds: 763_200, diskBytes: 38_240_000_000)
            == "Library: 22 books · 14 audiobooks · 9 ebooks · 212 h of audio · 8 unread · 38.2 GB")
    }

    @Test @MainActor func SB5_theDemoLibrarysSizeIsCounted() async throws {
        let h = try await Harness.demo()
        #expect(h.model.sidebar.diskBytes > 0)
    }

    @Test @MainActor func SB1_theModelGivesTheBarForTheDemoLibraryAndNoneForTheInbox() async throws {
        let h = try await Harness.demo()
        let bar = try #require(h.model.statusBar)
        let listed = h.model.rows.filter { !$0.isMissing }.count
        #expect(bar.shown.hasPrefix(StatusBarText.books(listed)))
        #expect(bar.library.hasPrefix("Library: \(StatusBarText.books(h.model.sidebar.counts[.allBooks] ?? -1))"))
        let first = try #require(h.model.rows.first { !$0.isMissing })
        h.model.selection = [first.id]
        #expect(try #require(h.model.statusBar).shown.hasPrefix("1 of \(StatusBarText.books(listed)) selected"))
        h.model.sidebarSelection = .inbox
        #expect(h.model.statusBar == nil)
    }
}

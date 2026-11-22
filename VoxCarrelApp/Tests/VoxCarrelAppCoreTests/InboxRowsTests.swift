import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// WF14, WF15: the words of the Inbox and of the watch folder settings.
@Suite struct InboxRowsTests {
    private let folder = WatchFolder(id: 7, path: "/Volumes/Books/Arrivals", addedAt: Date(timeIntervalSinceReferenceDate: 0))
    private let arrived = Date(timeIntervalSinceReferenceDate: 500)

    private func arrival(
        title: String = "Salt Road", authors: [String] = ["Ines Calloway"], _ files: [(String, FileRole)]
    ) -> InboxArrival {
        let candidates = files.map {
            CandidateFile(url: URL(fileURLWithPath: "/Volumes/Books/Arrivals/\($0.0)"), role: $0.1)
        }
        return InboxArrival(
            id: candidates[0].url.path, folderId: 7,
            candidate: CandidateBook(files: candidates, metadata: BookMetadata(title: title, authors: authors)),
            files: candidates.map(\.url), arrivedAt: arrived)
    }

    /// WF14
    @Test func aRowSaysWhatTheBookIsAndWhereItArrived() {
        let row = InboxText.row(for: arrival([("Salt Road.m4b", .audio)]), folder: folder)
        #expect(row == InboxRow(
            id: "/Volumes/Books/Arrivals/Salt Road.m4b", title: "Salt Road", author: "Ines Calloway",
            kind: "Audiobook", files: "1 file", folder: "Arrivals", arrived: arrived))
    }

    /// WF14: a book whose files give no title is called by its first file's name, without the extension.
    @Test func theTitleFallsBackToTheFirstFilesName() {
        let files: [(String, FileRole)] = [("Untitled Recording 01.mp3", .audio), ("Untitled Recording 02.mp3", .audio)]
        #expect(InboxText.row(for: arrival(title: "", files), folder: folder).title == "Untitled Recording 01")
        #expect(InboxText.row(for: arrival(title: "   ", files), folder: folder).title == "Untitled Recording 01")
    }

    /// WF14
    @Test func theAuthorIsEmptyWhenUnknownAndListsEveryNameWhenKnown() {
        #expect(InboxText.row(for: arrival(authors: [], [("a.epub", .ebook)]), folder: folder).author == "")
        #expect(InboxText.row(for: arrival(authors: [" "], [("a.epub", .ebook)]), folder: folder).author == "")
        #expect(
            InboxText.row(for: arrival(authors: ["Terry Pratchett", "Neil Gaiman"], [("a.epub", .ebook)]), folder: folder)
                .author == "Terry Pratchett, Neil Gaiman")
    }

    /// WF14
    @Test func theKindIsWordedFromTheFiles() {
        #expect(InboxText.row(for: arrival([("a.m4b", .audio)]), folder: folder).kind == "Audiobook")
        #expect(InboxText.row(for: arrival([("a.epub", .ebook)]), folder: folder).kind == "Ebook")
        #expect(
            InboxText.row(for: arrival([("a.m4b", .audio), ("a.epub", .ebook)]), folder: folder).kind
                == "Audiobook and ebook")
        // An extra is neither: it comes along with the book.
        #expect(InboxText.row(for: arrival([("a.m4b", .audio), ("a.pdf", .extra)]), folder: folder).kind == "Audiobook")
    }

    /// WF14
    @Test func theFileCountIsWordedForOneAndForMany() {
        #expect(InboxText.row(for: arrival([("a.mp3", .audio)]), folder: folder).files == "1 file")
        let twelve = (1...12).map { ("part \($0).mp3", FileRole.audio) }
        #expect(InboxText.row(for: arrival(twelve), folder: folder).files == "12 files")
    }

    /// WF14: a folder that is no longer known leaves the name empty.
    @Test func theFolderIsItsLastPathComponent() {
        #expect(InboxText.row(for: arrival([("a.mp3", .audio)]), folder: folder).folder == "Arrivals")
        #expect(InboxText.row(for: arrival([("a.mp3", .audio)]), folder: nil).folder == "")
    }

    /// WF14: the home folder is shown as `~`; a folder that only begins with the same letters is not inside it.
    @Test func aPathAbbreviatesTheHomeFolder() {
        #expect(InboxText.abbreviated("/Users/sam/Downloads/Books", home: "/Users/sam") == "~/Downloads/Books")
        #expect(InboxText.abbreviated("/Users/sam", home: "/Users/sam") == "~")
        #expect(InboxText.abbreviated("/Users/samantha/Downloads", home: "/Users/sam") == "/Users/samantha/Downloads")
        #expect(InboxText.abbreviated("/Volumes/Books", home: "/Users/sam") == "/Volumes/Books")
        #expect(InboxText.abbreviated("/Users/sam/Downloads", home: "/Users/sam/") == "~/Downloads")
    }

    /// WF14
    @Test func aWatchFolderRowCarriesTheFoldersSettings() {
        var folder = WatchFolder(id: 3, path: "/Users/sam/Downloads", addedAt: Date(timeIntervalSinceReferenceDate: 0))
        folder.mode = .copy
        folder.includesPDFs = true
        let row = InboxText.row(for: WatchFolderStatus(folder: folder, availability: .available), home: "/Users/sam")
        #expect(row == WatchFolderRow(
            id: 3, path: "~/Downloads", mode: .copy, isEnabled: true, includesPDFs: true, note: nil))
    }

    /// WF15
    @Test func theNoteSaysWhyAFolderIsNotWatched() {
        func note(_ availability: FolderAvailability, enabled: Bool = true) -> String? {
            var folder = folder
            folder.isEnabled = enabled
            return InboxText.row(for: WatchFolderStatus(folder: folder, availability: availability)).note
        }
        #expect(note(.available) == nil)
        #expect(note(.missing) == "Folder not found. It will be watched again when it returns.")
        #expect(note(.notAllowed)
            == "VoxCarrel is not allowed to read this folder. Allow it in System Settings ▸ Privacy & Security ▸ Files and Folders.")
        #expect(note(.available, enabled: false) == "Off")
        // A folder that is off is not looked at: whatever was last known about it, it is Off.
        #expect(note(.missing, enabled: false) == "Off")
    }
}

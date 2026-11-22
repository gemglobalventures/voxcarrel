import Foundation
import VoxCarrelCore

// What the launch-check sheet asks of the model (plan Task 11). Q10–Q12.

/// What the launch check found, in words: only the sections that have something in them.
public struct LibraryCheckSummary: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        /// Its place in its section.
        public var id: Int
        /// A book's title, or a file's place inside the library folder.
        public var text: String
        /// The file; nil for a book.
        public var url: URL?
    }

    public struct Section: Equatable, Sendable {
        public var heading: String
        public var detail: String
        public var lines: [Line]
    }

    /// Books with files that are not where the library expects them.
    public var missing: Section?
    /// Book files in the library folder that no book uses.
    public var untracked: Section?
    /// Files an interrupted move left under a temporary name.
    public var stranded: Section?
    /// What the check did, under the sheet's title.
    public var intro = LibraryCheckSummary.nothingChanged
    static let nothingChanged = "VoxCarrel looked over the library folder as it opened. Nothing has been changed."
    static let noFileChanged = "VoxCarrel looked over the library folder as it opened. No file has been changed."

    /// A line saying how many books had their length corrected, because their files
    /// stated the wrong one; nil when none had.
    public var correctedLengths: String?
}

extension AppModel {
    /// Q10: what the launch-check sheet shows; nil when there is nothing to tell.
    public var libraryCheckSummary: LibraryCheckSummary? {
        guard let check = libraryCheck else { return nil }
        var summary = LibraryCheckSummary()

        let missing = check.booksWithMissingFiles.count
        if missing > 0 {
            summary.missing = LibraryCheckSummary.Section(
                heading: missing == 1 ? "1 book has missing files" : "\(missing) books have missing files",
                detail: "Their files are not where the library expects them. The books are listed under "
                    + "Needs Attention, where you can point VoxCarrel at a file that has moved.",
                lines: missingFileTitles.enumerated().map {
                    LibraryCheckSummary.Line(id: $0.offset, text: $0.element, url: nil)
                })
        }

        let untracked = check.untrackedFiles.count
        if untracked > 0 {
            summary.untracked = LibraryCheckSummary.Section(
                heading: untracked == 1
                    ? "1 file in the library folder does not belong to any book"
                    : "\(untracked) files in the library folder do not belong to any book",
                detail: "Import them to add them to the library, or leave them where they are.",
                lines: fileLines(check.untrackedFiles))
        }

        let stranded = check.strandedFiles.count
        if stranded > 0 {
            summary.stranded = LibraryCheckSummary.Section(
                heading: stranded == 1 ? "1 file was left half-moved" : "\(stranded) files were left half-moved",
                detail: "A move was interrupted before it finished. VoxCarrel has left "
                    + (stranded == 1 ? "this file" : "these files")
                    + " untouched; nothing was deleted. "
                    + (stranded == 1 ? "It is" : "They are")
                    + " hidden in the Finder: press ⌘⇧. (Command-Shift-full stop) there to show hidden files.",
                lines: strandedLines(check.strandedFiles))
        }

        if check.correctedLengths > 0 {
            summary.intro = LibraryCheckSummary.noFileChanged
            summary.correctedLengths = check.correctedLengths == 1
                ? "The length of 1 book was corrected: its files stated the wrong length."
                : "The length of \(check.correctedLengths) books was corrected: their files stated the wrong length."
        }

        let isEmpty = summary.missing == nil && summary.untracked == nil && summary.stranded == nil
            && summary.correctedLengths == nil
        return isEmpty ? nil : summary
    }

    /// Q12: shows a file the launch check found in the Finder.
    public func revealInFinder(_ url: URL) {
        opener.reveal([url])
    }

    private func fileLines(_ urls: [URL]) -> [LibraryCheckSummary.Line] {
        urls.enumerated().map {
            LibraryCheckSummary.Line(id: $0.offset, text: placeInLibrary($0.element), url: $0.element)
        }
    }

    /// A half-moved file has a hidden name that says nothing, so what is shown is the
    /// folder it is in and, when it is plain what the file was, that file's name.
    private func strandedLines(_ urls: [URL]) -> [LibraryCheckSummary.Line] {
        urls.enumerated().map { index, url in
            let place = placeInLibrary(url)
            var folder = (place as NSString).deletingLastPathComponent
            if folder.isEmpty { folder = "the library folder" }
            var text = "A hidden file in \(folder)"
            if let name = strandedNames[url] { text += ", probably \"\(name)\"" }
            return LibraryCheckSummary.Line(id: index, text: text, url: url)
        }
    }

    /// A file's path from the library folder down; its whole path when it is not inside it.
    private func placeInLibrary(_ url: URL) -> String {
        guard let root = libraryFolder else { return url.path }
        // The same folder may be spelled two ways (/var and /private/var).
        for (file, folder) in [
            (url.standardizedFileURL.path, root.standardizedFileURL.path),
            (url.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path),
        ] {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            if file.hasPrefix(prefix) { return String(file.dropFirst(prefix.count)) }
        }
        return url.path
    }
}

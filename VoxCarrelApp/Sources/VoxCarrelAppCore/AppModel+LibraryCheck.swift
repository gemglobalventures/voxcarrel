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
    static let allInPlace =
        "VoxCarrel looked over the library folder. Everything is where the library expects it, and nothing has been changed."
    static let noFileChanged = "VoxCarrel looked over the library folder as it opened. No file has been changed."

    /// FL13: book folders left set aside by a change of folder layout that was
    /// interrupted and then given up on.
    public var setAside: Section?
    /// FL11: said when a change of folder layout had been interrupted and the folders
    /// were put back; nil otherwise.
    public var recoveredLayout: String?
    /// FL12: a change of folder layout was interrupted and could not be put right.
    public var layoutProblem: LayoutProblem?

    public struct LayoutProblem: Equatable, Sendable {
        /// Its detail says why the folders could not be put back and what that means
        /// for now; its lines are the folders in the way: where each is, and where it
        /// belongs.
        public var section: Section
        public var retryTitle: String
        public var stopTitle: String
    }

    /// A line saying how many books had their length corrected, because their files
    /// stated the wrong one; nil when none had.
    public var correctedLengths: String?
    /// A line saying how many files the check found to state the wrong length; nil when
    /// it found none.
    public var wrongLengthFiles: String?
}

extension AppModel {
    static let checkingLabel = "Checking the library…"
    /// What the check says when it has put an interrupted merge right.
    static let recoveredMergeText = "A merge of books was interrupted. The files have been put back as they were."

    /// A2: runs the launch check and keeps what it found worth telling.
    ///
    /// FL11: the check first puts right a change of folder layout that was interrupted,
    /// and says so when folders were put back. FL12: when it cannot, it says why, and
    /// `layoutChangeIsUnresolved` switches off everything the library would refuse
    /// until a later check succeeds or the owner gives up (FL13).
    ///
    /// - Parameter reloads: False when the caller reads everything again itself.
    ///   - asked: True when the owner asked for the check: what it found is then
    ///     shown even when that is nothing.
    func runLibraryCheck(with worker: LibraryWorker, reloads: Bool = true, asked: Bool = false) async {
        libraryCheckWasAsked = asked
        do {
            let report = try await worker.reconcile()
            // Another library was opened meanwhile: what was found is not about it.
            guard self.worker === worker else { return }
            // FL12: set before the check is shown, so that nothing is offered that is off.
            // The same for a merge of books that was interrupted.
            mergeRecoveryIsUnresolved = report.mergeProblem != nil
            layoutChangeIsUnresolved = report.layoutChangeProblem != nil || mergeRecoveryIsUnresolved
            // The check flags books with missing files and clears the flag of books that are whole
            // again, corrects the length of books whose files stated the wrong one, and marks
            // files it finds to state the wrong length.
            if reloads,
               report.recoveredMerge || !report.booksWithMissingFiles.isEmpty || !report.booksRecovered.isEmpty
                || report.correctedLengths > 0 || report.filesWithWrongLength > 0 {
                await reloadAll()
            }
            // A2
            let worthTelling = !report.booksWithMissingFiles.isEmpty || !report.untrackedFiles.isEmpty
                || !report.strandedFiles.isEmpty || report.correctedLengths > 0
                || report.filesWithWrongLength > 0
                // FL11, FL12, and folders still set aside after FL13.
                || report.recoveredLayoutChange || report.layoutChangeProblem != nil
                || !report.strandedFolders.isEmpty
                // A merge of books that was interrupted: put right, or not.
                || report.recoveredMerge || report.mergeProblem != nil
            var titles: [String] = []
            if !report.booksWithMissingFiles.isEmpty {
                // Q10: named now, so that the check can list them whatever the window shows later.
                let missing = Set(report.booksWithMissingFiles)
                titles = try await worker.rows(for: .needsAttention, search: "")
                    .filter { missing.contains($0.id) }
                    .map(\.book.title)
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            missingFileTitles = titles
            strandedNames = try await worker.likelyNames(ofStranded: report.strandedFiles)
            // FL12: a folder that is nowhere the change could have left it is said to
            // be missing, not to be at the place it was last expected.
            missingStrandedFolders = Set(
                report.strandedFolders.map(\.url).filter { !FileManager.default.fileExists(atPath: $0.path) })
            libraryCheck = worthTelling || asked ? report : nil
        } catch {
            show(error)
            // FL12: the check said nothing, so the library is asked.
            mergeRecoveryIsUnresolved = await worker.hasInterruptedMerge()
            layoutChangeIsUnresolved = await worker.hasInterruptedLayoutChange() || mergeRecoveryIsUnresolved
        }
    }

    public static let checkNowTitle = "Check Library Now"

    /// Whether the library can be checked on demand: one is open, nothing is running or
    /// being reviewed, and no check is already shown.
    public var canCheckLibraryNow: Bool {
        isLibraryOpen && busyLabel == nil && review == nil && libraryCheck == nil && !hasUnsavedChanges
    }

    /// Library > Check Library Now: the check made as the library opens, made again,
    /// and shown whatever it found.
    public func checkLibraryNow() async {
        guard canCheckLibraryNow, let worker = await begin(Self.checkingLabel) else { return }
        await runLibraryCheck(with: worker, reloads: false, asked: true)
        await finish()
    }

    /// FL12: "Try Again": runs the check again, which tries once more to put the
    /// folders back. Does nothing unless a change of layout is unresolved.
    public func retryLibraryCheck() async {
        guard layoutChangeIsUnresolved, let worker = await begin(Self.checkingLabel) else { return }
        await runLibraryCheck(with: worker, reloads: false)
        await finish()
    }

    /// FL13: "Stop Trying…": asks whether to give up on putting the folders back.
    public func requestStopLayoutRecovery() {
        guard layoutChangeIsUnresolved, busyLabel == nil, worker != nil else { return }
        raise(mergeRecoveryIsUnresolved ? .stopMergeRecovery : .stopLayoutRecovery)
    }

    /// FL13: the answer "stop trying" to `.stopLayoutRecovery`. The record of the
    /// interrupted change is removed; no folder is touched and nothing is deleted. The
    /// ordinary check then runs, and tells of the books whose folders are not where
    /// the library has them.
    public func confirmStopLayoutRecovery() async {
        guard storedPrompt == .stopLayoutRecovery || storedPrompt == .stopMergeRecovery else { return }
        storedPrompt = nil
        guard layoutChangeIsUnresolved, let worker = await begin(Self.checkingLabel) else { return }
        do {
            try await worker.discardInterruptedLayoutChange()
            try await worker.discardInterruptedMerge()
            await runLibraryCheck(with: worker, reloads: false)
        } catch {
            show(error)
        }
        await finish()
    }

    /// Q10: what the launch-check sheet shows; nil when there is nothing to tell.
    public var libraryCheckSummary: LibraryCheckSummary? {
        guard let check = libraryCheck else { return nil }
        var summary = LibraryCheckSummary()

        // FL12
        if let reason = check.layoutChangeProblem {
            summary.layoutProblem = LibraryCheckSummary.LayoutProblem(
                section: LibraryCheckSummary.Section(
                    heading: "A change of folder layout was interrupted",
                    detail: Self.sentence(reason) + " Nothing was moved or deleted. "
                        + "Importing, saving and other changes are off until this is resolved.",
                    lines: folderLines(check.strandedFolders)),
                retryTitle: "Try Again", stopTitle: "Stop Trying…")
        } else if let reason = check.mergeProblem {
            // Shown as an interrupted change of folder layout is, with the same two ways on.
            summary.layoutProblem = LibraryCheckSummary.LayoutProblem(
                section: LibraryCheckSummary.Section(
                    heading: "A merge of books was interrupted",
                    detail: Self.sentence(reason) + " Nothing was deleted. "
                        + "Importing, saving and other changes are off until this is resolved.",
                    lines: fileLines(check.mergeFilesOutOfPlace)),
                retryTitle: "Try Again", stopTitle: "Stop Trying…")
        } else if !check.strandedFolders.isEmpty {
            // FL13: folders that were set aside when the change was given up on.
            let count = check.strandedFolders.count
            summary.setAside = LibraryCheckSummary.Section(
                heading: count == 1 ? "1 book folder was left set aside" : "\(count) book folders were left set aside",
                detail: "A change of folder layout was interrupted before it finished. VoxCarrel has left "
                    + (count == 1 ? "this folder" : "these folders")
                    + " untouched; nothing was deleted. Move "
                    + (count == 1 ? "it back to where it belongs" : "them back to where they belong")
                    + " in the Finder: press ⌘⇧. (Command-Shift-full stop) there to show hidden folders.",
                lines: folderLines(check.strandedFolders))
        }
        // FL11
        if check.recoveredLayoutChange {
            summary.intro = LibraryCheckSummary.noFileChanged
            summary.recoveredLayout =
                "A change of folder layout was interrupted. The folders have been put back as they were."
        }
        if check.recoveredMerge {
            summary.intro = LibraryCheckSummary.noFileChanged
            summary.recoveredLayout = [summary.recoveredLayout, Self.recoveredMergeText].compactMap { $0 }
                .joined(separator: " ")
        }

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

        if check.filesWithWrongLength > 0 {
            summary.intro = LibraryCheckSummary.noFileChanged
            summary.wrongLengthFiles =
                (check.filesWithWrongLength == 1
                    ? "1 file was found to state the wrong length. Its book is"
                    : "\(check.filesWithWrongLength) files were found to state the wrong length. Their books are")
                + " marked with a warning, and the inspector says what is wrong and whether it can be repaired."
        }

        let isEmpty = summary.missing == nil && summary.untracked == nil && summary.stranded == nil
            && summary.correctedLengths == nil && summary.wrongLengthFiles == nil
            && summary.recoveredLayout == nil && summary.layoutProblem == nil && summary.setAside == nil
        if libraryCheckWasAsked {
            // Not "as it opened": the owner asked just now.
            summary.intro = isEmpty
                ? LibraryCheckSummary.allInPlace
                : summary.intro.replacingOccurrences(of: " as it opened", with: "")
            return summary
        }
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

    /// FL12: where each folder is and where it belongs; for one that is not there, where
    /// it belongs and where it was being moved.
    private func folderLines(_ folders: [StrandedFolder]) -> [LibraryCheckSummary.Line] {
        folders.enumerated().map { index, folder in
            if missingStrandedFolders.contains(folder.url), let belongs = folder.belongsAt {
                var text = "“\(belongs)” cannot be found."
                if let destination = folder.wasMovingTo { text += " It was being moved to “\(destination)”." }
                return LibraryCheckSummary.Line(id: index, text: text, url: nil)
            }
            let place = placeInLibrary(folder.url)
            let text = folder.belongsAt.map { "“\(place)” belongs at “\($0)”" } ?? "A folder at “\(place)”"
            return LibraryCheckSummary.Line(id: index, text: text, url: folder.url)
        }
    }

    /// The library's reasons are not always whole sentences: gives one a full stop.
    private static func sentence(_ text: String) -> String {
        let text = text.trimmed
        return ".!?".contains(text.last ?? ".") ? text : text + "."
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

import Foundation

/// Reads descriptive metadata from one file. Format-specific readers arrive in Plan 2.
public protocol MetadataReader: Sendable {
    func readMetadata(at url: URL) throws -> BookMetadata
}

/// A book found by scanning, before the user has reviewed it.
public struct CandidateBook: Equatable, Sendable {
    /// Audio parts in order, then ebook files, then extras.
    public var files: [CandidateFile]
    public var metadata: BookMetadata
    /// Set when a folder of audio parts was grouped into this book.
    public var sourceFolder: URL?

    public init(files: [CandidateFile], metadata: BookMetadata, sourceFolder: URL? = nil) {
        self.files = files
        self.metadata = metadata
        self.sourceFolder = sourceFolder
    }

    public var hasAudio: Bool {
        files.contains { $0.role == .audio }
    }
}

public struct ScanResult: Equatable, Sendable {
    public var candidates: [CandidateBook] = []
    /// Everything that was not scanned: files with unsupported extensions,
    /// symlinks, paths that do not exist, folders that could not be read, and
    /// packages or folders named like a book file.
    public var skipped: [URL] = []

    public init() {}
}

public struct BookScanner {
    private let reader: (any MetadataReader)?

    public init(reader: (any MetadataReader)? = nil) {
        self.reader = reader
    }

    /// Scans dropped files and folders (folders recursively) into candidate books.
    ///
    /// Each file is considered once, however the inputs overlap. Symlinks, paths
    /// that do not exist, folders that cannot be read, and packages or folders
    /// named like a book file are listed as skipped and not looked inside.
    public func scan(_ urls: [URL]) -> ScanResult {
        var result = ScanResult()

        // Drop repeats, and inputs that lie inside another input folder.
        var seen = Set<String>()
        let inputs = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let folderPrefixes = inputs.filter { kind(of: $0) != .file && kind(of: $0) != .unusable }
            .map { $0.standardizedFileURL.path + "/" }
        let roots = inputs.filter { input in
            let path = input.standardizedFileURL.path
            return !folderPrefixes.contains { path.hasPrefix($0) }
        }

        // Loose files are grouped only with files dropped from the same folder.
        var looseFolders: [String] = []
        var looseFiles: [String: [URL]] = [:]
        for url in roots {
            switch kind(of: url) {
            case .folder:
                _ = scanFolder(url, into: &result)
            case .file:
                let parent = url.standardizedFileURL.deletingLastPathComponent().path
                if looseFiles[parent] == nil { looseFolders.append(parent) }
                looseFiles[parent, default: []].append(url)
            case .opaqueFolder, .unusable:
                result.skipped.append(url)
            }
        }
        for parent in looseFolders {
            addFiles(looseFiles[parent] ?? [], folder: nil, subfoldersHaveAudio: false,
                     subfoldersHaveBooks: false, into: &result)
        }

        result.candidates = mergeMatching(result.candidates).map { candidate in
            var sorted = candidate
            sorted.files = [FileRole.audio, .ebook, .extra].flatMap { role in
                candidate.files.filter { $0.role == role }
            }
            return sorted
        }
        return result
    }

    // MARK: Folders

    private enum Kind {
        /// A regular file.
        case file
        /// A folder to look inside.
        case folder
        /// A package, or a folder named like a book file: one unsupported item.
        case opaqueFolder
        /// A symlink, or nothing readable at the path.
        case unusable
    }

    private func kind(of url: URL) -> Kind {
        guard let values = try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey]),
            values.isSymbolicLink != true
        else { return .unusable }
        guard values.isDirectory == true else { return .file }
        return values.isPackage == true || FileFormat(url: url) != nil ? .opaqueFolder : .folder
    }

    private func isGeneric(_ folder: URL) -> Bool {
        FilenameParser.genericFolders.contains(folder.lastPathComponent.lowercased())
    }

    private struct Contents {
        var hasAudio = false
        var hasBooks = false
    }

    /// Scans one folder and its subfolders; reports what the subtree contains.
    private func scanFolder(_ folder: URL, into result: inout ScanResult) -> Contents {
        guard let unsorted = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            result.skipped.append(folder)
            return Contents()
        }
        let children = unsorted.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var files: [URL] = []
        var below = Contents()
        for child in children {
            switch kind(of: child) {
            case .folder:
                let sub = scanFolder(child, into: &result)
                below.hasAudio = below.hasAudio || sub.hasAudio
                below.hasBooks = below.hasBooks || sub.hasBooks
            case .file:
                files.append(child)
            case .opaqueFolder, .unusable:
                result.skipped.append(child)
            }
        }

        addFiles(files, folder: folder, subfoldersHaveAudio: below.hasAudio,
                 subfoldersHaveBooks: below.hasBooks, into: &result)

        let formats = files.compactMap { FileFormat(url: $0) }
        return Contents(
            hasAudio: below.hasAudio || formats.contains { $0.defaultRole == .audio },
            hasBooks: below.hasBooks || !formats.isEmpty)
    }

    // MARK: Grouping the files of one folder

    private struct Group {
        var files: [CandidateFile]
        /// Non-nil for a multi-file audiobook made from a whole folder.
        var folder: URL?
        /// True when files were joined because they share the folder, not a name:
        /// the folder is then this book's own, and the author is the folder above.
        var ownsFolder = false
    }

    private func baseName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// - Parameter folder: The folder being scanned, or nil for loose dropped files.
    private func addFiles(
        _ files: [URL], folder: URL?, subfoldersHaveAudio: Bool, subfoldersHaveBooks: Bool,
        into result: inout ScanResult
    ) {
        var audio: [URL] = []
        var others: [URL] = []
        for file in files {
            guard let format = FileFormat(url: file) else {
                result.skipped.append(file)
                continue
            }
            if format.defaultRole == .audio { audio.append(file) } else { others.append(file) }
        }

        // 1. Audio: one multi-file book, or one book per file. A generic place
        // such as Downloads is never one book.
        var audioGroups: [Group]
        let audioFormats = Set(audio.compactMap { FileFormat(url: $0) })
        if let folder, !isGeneric(folder), !subfoldersHaveAudio, audio.count > 1,
           audioFormats == [.mp3] || audioFormats == [.m4a] {
            audioGroups = [
                Group(files: audio.map { CandidateFile(url: $0, role: .audio) }, folder: folder)
            ]
        } else {
            audioGroups = audio.map {
                Group(files: [CandidateFile(url: $0, role: .audio)], folder: nil)
            }
        }

        // 2 & 3. Non-audio files: join a same-named single-file audiobook,
        // otherwise group ebooks by base name and set PDFs aside.
        var ebookGroups: [Group] = []
        var pdfs: [URL] = []
        for file in others {
            let isPDF = FileFormat(url: file) == .pdf
            let name = baseName(file)
            if let i = audioGroups.firstIndex(where: {
                $0.folder == nil && baseName($0.files[0].url) == name
            }) {
                audioGroups[i].files.append(CandidateFile(url: file, role: isPDF ? .extra : .ebook))
            } else if isPDF {
                pdfs.append(file)
            } else if let i = ebookGroups.firstIndex(where: { baseName($0.files[0].url) == name }) {
                ebookGroups[i].files.append(CandidateFile(url: file, role: .ebook))
            } else {
                ebookGroups.append(Group(files: [CandidateFile(url: file, role: .ebook)], folder: nil))
            }
        }

        // 4. In a dedicated folder, one audiobook plus one ebook are the same book.
        // An audiobook that already has an ebook of its own name keeps to itself.
        let isDedicated = folder.map { !subfoldersHaveBooks && !isGeneric($0) } ?? false

        var groups: [Group]
        if isDedicated, audioGroups.count == 1, ebookGroups.count == 1,
           !audioGroups[0].files.contains(where: { $0.role == .ebook }) {
            var merged = audioGroups[0]
            merged.files += ebookGroups[0].files
            merged.ownsFolder = true
            groups = [merged]
        } else {
            groups = audioGroups + ebookGroups
        }

        // 5. PDFs: another format of a same-named ebook, an extra of the folder's
        // only book, or a book of their own.
        let folderHoldsOneBook = isDedicated && groups.count == 1
        for pdf in pdfs {
            let name = baseName(pdf)
            if let i = groups.firstIndex(where: { group in
                group.files.contains { $0.role == .ebook && baseName($0.url) == name }
            }) {
                groups[i].files.append(CandidateFile(url: pdf, role: .ebook))
            } else if folderHoldsOneBook {
                groups[0].files.append(CandidateFile(url: pdf, role: .extra))
                groups[0].ownsFolder = true
            } else {
                groups.append(Group(files: [CandidateFile(url: pdf, role: .ebook)], folder: nil))
            }
        }

        result.candidates += groups.map(makeCandidate)
    }

    private func makeCandidate(_ group: Group) -> CandidateBook {
        // Read tags from the audio if there is any, otherwise from the first file.
        let primary = (group.files.first { $0.role == .audio } ?? group.files[0]).url
        var metadata = (try? reader?.readMetadata(at: primary)) ?? BookMetadata()
        let guess = FilenameParser.guess(
            from: group.folder ?? primary, isFolder: group.folder != nil,
            parentIsBookFolder: group.folder == nil && group.ownsFolder)
        if metadata.title.isEmpty { metadata.title = guess.title }
        if metadata.authors.isEmpty, let author = guess.author { metadata.authors = [author] }
        return CandidateBook(files: group.files, metadata: metadata, sourceFolder: group.folder)
    }

    // MARK: Merging across folders

    /// 6. Merges an audiobook that has no ebook yet with a candidate that has no
    /// audio when they share a title and first author. Only an unambiguous pair
    /// is merged: exactly one such audiobook and exactly one no-audio candidate
    /// for that title and author. Anything else is left for the review sheet, so
    /// the outcome does not depend on the order things were scanned in.
    /// The audio candidate's metadata wins.
    private func mergeMatching(_ candidates: [CandidateBook]) -> [CandidateBook] {
        var audioOnly: [String: [Int]] = [:]
        var withoutAudio: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let key = matchKey(candidate) else { continue }
            if !candidate.hasAudio {
                withoutAudio[key, default: []].append(index)
            } else if !candidate.files.contains(where: { $0.role == .ebook }) {
                audioOnly[key, default: []].append(index)
            }
        }

        var merged: [CandidateBook?] = candidates
        for (key, audio) in audioOnly {
            guard audio.count == 1, let others = withoutAudio[key], others.count == 1 else {
                continue
            }
            var combined = candidates[audio[0]]
            combined.files += candidates[others[0]].files
            merged[min(audio[0], others[0])] = combined
            merged[max(audio[0], others[0])] = nil
        }
        return merged.compactMap { $0 }
    }

    /// Nil when the candidate lacks a title or author and so cannot be matched.
    private func matchKey(_ candidate: CandidateBook) -> String? {
        let title = candidate.metadata.title.trimmingCharacters(in: .whitespaces).lowercased()
        let author = (candidate.metadata.authors.first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !title.isEmpty, !author.isEmpty else { return nil }
        return title + "\u{0}" + author
    }
}

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
    /// Files with unsupported extensions.
    public var skipped: [URL] = []

    public init() {}
}

public struct BookScanner {
    private let reader: (any MetadataReader)?

    public init(reader: (any MetadataReader)? = nil) {
        self.reader = reader
    }

    /// Scans dropped files and folders (folders recursively) into candidate books.
    public func scan(_ urls: [URL]) -> ScanResult {
        var result = ScanResult()
        var looseFiles: [URL] = []
        for url in urls {
            if isDirectory(url) {
                _ = scanFolder(url, into: &result)
            } else {
                looseFiles.append(url)
            }
        }
        addFiles(looseFiles, folder: nil, subfoldersHaveAudio: false, subfoldersHaveBooks: false,
                 into: &result)
        result.candidates = mergeMatching(result.candidates)
        return result
    }

    // MARK: Folders

    private struct Contents {
        var hasAudio = false
        var hasBooks = false
    }

    /// Scans one folder and its subfolders; reports what the subtree contains.
    private func scanFolder(_ folder: URL, into result: inout ScanResult) -> Contents {
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? [])
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

        var files: [URL] = []
        var below = Contents()
        for child in children {
            if isDirectory(child) {
                let sub = scanFolder(child, into: &result)
                below.hasAudio = below.hasAudio || sub.hasAudio
                below.hasBooks = below.hasBooks || sub.hasBooks
            } else {
                files.append(child)
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

        // 1. Audio: one multi-file book, or one book per file.
        var audioGroups: [Group]
        let audioFormats = Set(audio.compactMap { FileFormat(url: $0) })
        if let folder, !subfoldersHaveAudio, audio.count > 1,
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
        let isDedicated = folder.map {
            !subfoldersHaveBooks
                && !FilenameParser.genericFolders.contains($0.lastPathComponent.lowercased())
        } ?? false

        var groups: [Group]
        if isDedicated, audioGroups.count == 1, ebookGroups.count == 1 {
            var merged = audioGroups[0]
            merged.files += ebookGroups[0].files
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
        let guess = FilenameParser.guess(from: group.folder ?? primary, isFolder: group.folder != nil)
        if metadata.title.isEmpty { metadata.title = guess.title }
        if metadata.authors.isEmpty, let author = guess.author { metadata.authors = [author] }
        return CandidateBook(files: group.files, metadata: metadata, sourceFolder: group.folder)
    }

    // MARK: Merging across folders

    /// 6. Merges a candidate that has audio with one that has none when they
    /// share a title and first author. The audio candidate's metadata wins.
    private func mergeMatching(_ candidates: [CandidateBook]) -> [CandidateBook] {
        var merged: [CandidateBook] = []
        for candidate in candidates {
            guard let key = matchKey(candidate),
                  let i = merged.firstIndex(where: {
                      matchKey($0) == key && $0.hasAudio != candidate.hasAudio
                  })
            else {
                merged.append(candidate)
                continue
            }
            if merged[i].hasAudio {
                merged[i].files += candidate.files
            } else {
                var combined = candidate
                combined.files += merged[i].files
                merged[i] = combined
            }
        }
        return merged
    }

    /// Nil when the candidate lacks a title or author and so cannot be matched.
    private func matchKey(_ candidate: CandidateBook) -> String? {
        let title = candidate.metadata.title.trimmingCharacters(in: .whitespaces).lowercased()
        let author = (candidate.metadata.authors.first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !title.isEmpty, !author.isEmpty else { return nil }
        return title + "\u{0}" + author
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

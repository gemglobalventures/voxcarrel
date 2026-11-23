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

    /// What was guessed from names and not read from tags, for the review to say.
    public var guessNotes: GuessNotes

    public init(
        files: [CandidateFile], metadata: BookMetadata, sourceFolder: URL? = nil, guessNotes: GuessNotes = []
    ) {
        self.files = files
        self.metadata = metadata
        self.sourceFolder = sourceFolder
        self.guessNotes = guessNotes
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

    private let known: KnownNames

    /// - Parameter known: The authors and titles the library already has, as evidence
    ///   for reading a name "A - B" either way round.
    public init(reader: (any MetadataReader)? = nil, known: KnownNames = .none) {
        self.reader = reader
        self.known = known
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
                _ = scanFolder(url, from: disk, into: &result)
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

        finish(&result)
        return result
    }

    /// Scans `files`, all of them somewhere under `root`, as if they were everything
    /// `root` holds and its contents had been dropped together: files directly in
    /// `root` are loose files, and each folder below it is scanned as a folder that
    /// holds only those of `files` that lie in it. Files of `root` that are not in
    /// `files` play no part.
    ///
    /// Each file is still looked at where it is: one that is no longer a plain file is
    /// listed as skipped, as is one that does not lie under `root`.
    func scan(files: [URL], under root: URL) -> ScanResult {
        var result = ScanResult()
        let rootParts = root.pathComponents
        // What each folder holds, by the folder's path.
        var holds: [String: [URL]] = [root.path: []]
        for file in files {
            let parts = file.pathComponents
            guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
                result.skipped.append(file)
                continue
            }
            var folder = root
            for name in parts[rootParts.count..<(parts.count - 1)] {
                let below = folder.appendingPathComponent(name, isDirectory: true)
                if holds[below.path] == nil {
                    holds[below.path] = []
                    holds[folder.path, default: []].append(below)
                }
                folder = below
            }
            holds[folder.path, default: []].append(file)
        }
        let source = Source(
            kind: { holds[$0.path] != nil ? .folder : kind(of: $0) },
            children: { holds[$0.path] })

        var loose: [URL] = []
        for child in Self.inNameOrder(holds[root.path] ?? []) {
            switch source.kind(child) {
            case .folder: _ = scanFolder(child, from: source, into: &result)
            case .file: loose.append(child)
            case .opaqueFolder, .unusable: result.skipped.append(child)
            }
        }
        addFiles(loose, folder: nil, subfoldersHaveAudio: false, subfoldersHaveBooks: false, into: &result)

        finish(&result)
        return result
    }

    /// Merges candidates that are one book, and puts each one's files in order.
    private func finish(_ result: inout ScanResult) {
        result.candidates = mergeMatching(result.candidates).map { candidate in
            var sorted = candidate
            sorted.files = [FileRole.audio, .ebook, .extra].flatMap { role in
                candidate.files.filter { $0.role == role }
            }
            return sorted
        }
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

    /// Where the scanner learns what a folder holds and what each thing in it is.
    private struct Source {
        var kind: (URL) -> Kind
        /// Nil for a folder that cannot be read.
        var children: (URL) -> [URL]?
    }

    /// The folders and files as they are on disk.
    private var disk: Source {
        Source(kind: kind(of:), children: { folder in
            try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        })
    }

    private static func inNameOrder(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Scans one folder and its subfolders; reports what the subtree contains.
    private func scanFolder(_ folder: URL, from source: Source, into result: inout ScanResult) -> Contents {
        guard let unsorted = source.children(folder) else {
            result.skipped.append(folder)
            return Contents()
        }
        let children = Self.inNameOrder(unsorted)

        var files: [URL] = []
        var below = Contents()
        for child in children {
            switch source.kind(child) {
            case .folder:
                let sub = scanFolder(child, from: source, into: &result)
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
        // Tags always win: only what they leave empty is taken from names.
        let needsTitle = metadata.title.isEmpty
        let needsAuthor = metadata.authors.isEmpty
        let needsASIN = (metadata.asin ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // What the tags do say is evidence for reading the name, like what the library has.
        var evidence = known
        if needsTitle != needsAuthor {
            if !needsTitle { evidence.titles.insert(KnownNames.titleKey(metadata.title)) }
            for author in metadata.authors { evidence.authors.insert(KnownNames.authorKey(author)) }
        }
        let guess = FilenameParser.guess(
            from: group.folder ?? primary, isFolder: group.folder != nil,
            parentIsBookFolder: group.folder == nil && group.ownsFolder, known: evidence)

        var notes: GuessNotes = []
        var usedName = false
        if needsTitle {
            metadata.title = guess.title
            usedName = true
        }
        if needsAuthor, let author = guess.author {
            metadata.authors = [author]
            usedName = true
        }
        if usedName {
            notes.formUnion(guess.notes.intersection([.fromFileName, .orderUnsure, .orderSwapped]))
        }
        // An author from the tags is the author, whatever the title looks like.
        if needsTitle, needsAuthor, guess.notes.contains(.titleLooksLikePerson) {
            notes.insert(.titleLooksLikePerson)
        }
        if needsASIN, let asin = guess.asin {
            metadata.asin = asin
            notes.insert(.audibleIDFromName)
        }
        return CandidateBook(
            files: group.files, metadata: metadata, sourceFolder: group.folder, guessNotes: notes)
    }

    // MARK: Merging across folders

    /// 6. Merges an audiobook that has no ebook yet with a candidate that has no
    /// audio when they are one book: they have the same Audible ID, or the same first
    /// author and the same title, edition words aside (`TitleMatch.core`); never when
    /// one title is only the other up to a subtitle. Only an unambiguous pair is
    /// merged: exactly one such audiobook and exactly one no-audio candidate for that
    /// ID, or for that title and author. Anything else is left for the review sheet,
    /// so the outcome does not depend on the order things were scanned in.
    /// The audio candidate's metadata, and what was guessed for it, wins.
    private func mergeMatching(_ candidates: [CandidateBook]) -> [CandidateBook] {
        mergePairs(mergePairs(candidates, by: audibleIDKey), by: matchKey)
    }

    private func mergePairs(_ candidates: [CandidateBook], by key: (CandidateBook) -> String?) -> [CandidateBook] {
        var audioOnly: [String: [Int]] = [:]
        var withoutAudio: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let key = key(candidate) else { continue }
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

    /// Nil when the candidate has no Audible ID.
    private func audibleIDKey(_ candidate: CandidateBook) -> String? {
        let id = (candidate.metadata.asin ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return id.isEmpty ? nil : id
    }

    /// Nil when the candidate lacks a title or author and so cannot be matched.
    private func matchKey(_ candidate: CandidateBook) -> String? {
        let title = KnownNames.titleKey(candidate.metadata.title)
        let author = KnownNames.authorKey(candidate.metadata.authors.first ?? "")
        guard !title.isEmpty, !author.isEmpty else { return nil }
        return title + "\u{0}" + author
    }
}

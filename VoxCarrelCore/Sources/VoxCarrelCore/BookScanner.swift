import CryptoKit
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

    /// A picture of the cover found beside the book, for when its files hold none.
    public var coverBeside: URL?

    /// Files found in the same scan that are byte for byte the same as one of this
    /// book's files. They are not imported: one copy is enough.
    public var copies: [URL] = []

    /// How many of the book's files are kept in iCloud and are not on this Mac. Their
    /// tags were not read (that would have fetched them), so the details come from
    /// names; importing fetches them.
    public var filesNotOnThisMac = 0

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
    /// Files that are byte for byte the same as a file the library already has. They
    /// are not offered: the book is there. Filled in only by a library's own scan.
    public var alreadyInLibrary: [URL] = []

    public init() {}
}

public struct BookScanner {
    private let reader: (any MetadataReader)?

    private let known: KnownNames

    /// Whether a file's contents are here to be read without fetching them.
    private let isOnThisMac: @Sendable (URL) -> Bool

    /// - Parameter known: The authors and titles the library already has, as evidence
    ///   for reading a name "A - B" either way round.
    /// - Parameter isOnThisMac: For tests; the file system is asked otherwise.
    public init(
        reader: (any MetadataReader)? = nil, known: KnownNames = .none,
        isOnThisMac: @escaping @Sendable (URL) -> Bool = BookScanner.isOnThisMac
    ) {
        self.reader = reader
        self.known = known
        self.isOnThisMac = isOnThisMac
    }

    /// False for a file kept in iCloud whose contents have not been fetched: reading
    /// it would fetch it, however large it is. True for every other file.
    public static func isOnThisMac(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus
        else { return true }
        return status != .notDownloaded
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

        finish(&result, tidying: true)
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

        finish(&result, tidying: false)
        return result
    }

    /// Merges candidates that are one book, and puts each one's files in order.
    ///
    /// - Parameter tidying: True for what the owner asked to have scanned: files that
    ///   are copies of others are set aside and the same book found twice is one. A
    ///   watch folder's check leaves both alone, since it keeps account of every file.
    private func finish(_ result: inout ScanResult, tidying: Bool) {
        let found = tidying
            ? joinSameBook(Self.withoutCopies(result.candidates, isOnThisMac: isOnThisMac)) : result.candidates
        result.candidates = mergeMatching(found).map { candidate in
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
        // An audiobook kept disc by disc is one book: its parts are gathered in the
        // order of the discs, as if they lay in this folder.
        let discs = discFolders(among: children, from: source)
        for child in children {
            if let parts = discs[child.path] {
                files += parts.audio
                result.skipped += parts.others
                continue
            }
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

    private struct DiscParts {
        var audio: [URL]
        var others: [URL]
    }

    /// True for the name of a folder that is one disc or part of an audiobook: "CD1",
    /// "CD 2", "Disc 03", "Disk-4", "Part 2".
    static func isDiscName(_ name: String) -> Bool {
        let lower = name.lowercased()
        for word in ["cd", "disc", "disk", "part"] where lower.hasPrefix(word) {
            let rest = lower.dropFirst(word.count).drop { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }
            if !rest.isEmpty, rest.count <= 3, rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The folders among `children` that are the discs of one audiobook, each with
    /// its parts in order: two or more folders named as discs, every one holding
    /// audio of the one kind (MP3 or M4A) and no folder, and no other folder beside
    /// them. Empty when the folder is not laid out so.
    private func discFolders(among children: [URL], from source: Source) -> [String: DiscParts] {
        let folders = children.filter { source.kind($0) == .folder }
        guard folders.count >= 2, folders.allSatisfy({ Self.isDiscName($0.lastPathComponent) }) else { return [:] }
        var found: [String: DiscParts] = [:]
        var formats = Set<FileFormat>()
        for folder in folders {
            guard let inside = source.children(folder) else { return [:] }
            var parts = DiscParts(audio: [], others: [])
            for item in Self.inNameOrder(inside) {
                guard source.kind(item) == .file else { return [:] }
                if let format = FileFormat(url: item), format.defaultRole == .audio {
                    formats.insert(format)
                    parts.audio.append(item)
                } else {
                    parts.others.append(item)
                }
            }
            guard !parts.audio.isEmpty else { return [:] }
            found[folder.path] = parts
        }
        return formats == [.mp3] || formats == [.m4a] ? found : [:]
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

        var made = groups.map(makeCandidate)
        // A folder that is one book's own may hold its details, as calibre keeps
        // them, and a picture of its cover. The details are the keeper's and are
        // believed over the tags for what they give; an Audible ID is never replaced.
        if folder != nil, made.count == 1, isDedicated {
            if let file = Sidecar.detailsFile(among: files), let details = Sidecar.details(at: file) {
                var merged = made[0].metadata
                merged.title = details.title
                if !details.authors.isEmpty { merged.authors = details.authors }
                merged.series = details.series ?? merged.series
                merged.seriesNumber = details.series != nil ? details.seriesNumber : merged.seriesNumber
                merged.publisher = details.publisher ?? merged.publisher
                merged.language = details.language ?? merged.language
                merged.year = details.year ?? merged.year
                merged.summary = details.summary ?? merged.summary
                merged.isbn = details.isbn ?? merged.isbn
                if (merged.asin ?? "").isEmpty { merged.asin = details.asin }
                made[0].metadata = merged
                made[0].guessNotes.subtract([.fromFileName, .orderUnsure, .orderSwapped, .orderGuessedByShape, .titleLooksLikePerson])
            }
            made[0].coverBeside = Sidecar.cover(among: files)
        }
        result.candidates += made
    }

    private func makeCandidate(_ group: Group) -> CandidateBook {
        // Read tags from the audio if there is any, otherwise from the first file.
        let primary = (group.files.first { $0.role == .audio } ?? group.files[0]).url
        // A file that is not here is not read: its name has to do until it is fetched.
        var metadata = (isOnThisMac(primary) ? try? reader?.readMetadata(at: primary) : nil) ?? BookMetadata()
        Self.settingAsideWhatAProgramLeft(in: &metadata, primary: primary, folder: group.folder)
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
            notes.formUnion(
                guess.notes.intersection([.fromFileName, .orderUnsure, .orderSwapped, .orderGuessedByShape]))
        }
        // An author from the tags is the author, whatever the title looks like.
        if needsTitle, needsAuthor, guess.notes.contains(.titleLooksLikePerson) {
            notes.insert(.titleLooksLikePerson)
        }
        if needsASIN, let asin = guess.asin {
            metadata.asin = asin
            notes.insert(.audibleIDFromName)
        }
        var candidate = CandidateBook(
            files: group.files, metadata: metadata, sourceFolder: group.folder, guessNotes: notes)
        candidate.filesNotOnThisMac = group.files.filter { !isOnThisMac($0.url) }.count
        return candidate
    }

    /// Empties a title or an author that is not the book's but what a program left in
    /// the tags (`TagJudge`), so that the name is read instead. A PDF's title that has
    /// no word in common with a name that says plenty is not believed either, and then
    /// its author only if the name has them too. A part's number before the title of a
    /// book in several files ("01 Slow Horses" in a folder named for Slow Horses) is
    /// taken off.
    static func settingAsideWhatAProgramLeft(in metadata: inout BookMetadata, primary: URL, folder: URL?) {
        let name = (folder ?? primary.deletingPathExtension()).lastPathComponent
        let isPDF = FileFormat(url: primary) == .pdf
        metadata.authors = metadata.authors.compactMap(TagJudge.author)

        var believed = !TagJudge.isJunkTitle(metadata.title)
        if believed, isPDF, TagJudge.nameIsTelling(name), !TagJudge.agree(tagTitle: metadata.title, fileName: name) {
            believed = false
        }
        if !believed {
            metadata.title = ""
            if isPDF { metadata.authors = metadata.authors.filter { TagJudge.agree(tagTitle: $0, fileName: name) } }
        }

        if let folder, believed {
            let words = metadata.title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if words.count == 2, words[0].count <= 3, words[0].allSatisfy(\.isNumber) {
                let rest = String(words[1]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty, folder.lastPathComponent.range(of: rest, options: [.caseInsensitive]) != nil {
                    metadata.title = rest
                }
            }
        }
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
            combined.coverBeside = combined.coverBeside ?? candidates[others[0]].coverBeside
            combined.copies += candidates[others[0]].copies
            combined.filesNotOnThisMac += candidates[others[0]].filesNotOnThisMac
            merged[min(audio[0], others[0])] = combined
            merged[max(audio[0], others[0])] = nil
        }
        return merged.compactMap { $0 }
    }

    // MARK: The same file, and the same book, found twice

    /// What tells two files with the same bytes from two that differ: the size, and a
    /// digest of the contents (of the first and last 4 MB for a file larger than 64 MB,
    /// which is as much as two different audiobooks of one length could share by
    /// chance). Nil for a file that cannot be read.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var hash = Fingerprint()
        let whole: UInt64 = 64 * 1024 * 1024, edge: UInt64 = 4 * 1024 * 1024
        func feed(from start: UInt64, count: UInt64) -> Bool {
            guard (try? handle.seek(toOffset: start)) != nil else { return false }
            var left = count
            while left > 0 {
                guard let chunk = try? handle.read(upToCount: Int(min(left, 1024 * 1024))), !chunk.isEmpty else { return false }
                hash.add(chunk)
                left -= UInt64(chunk.count)
            }
            return true
        }
        if size <= whole {
            guard feed(from: 0, count: size) else { return nil }
        } else {
            guard feed(from: 0, count: edge), feed(from: size - edge, count: edge) else { return nil }
        }
        return "\(size):\(hash.value)"
    }

    /// The candidates with every file that is a copy of an earlier one taken out and
    /// noted as a copy on the book that keeps the first. A candidate left with no
    /// file is dropped. Only files of the same size are read to be compared.
    static func withoutCopies(
        _ candidates: [CandidateBook], isOnThisMac: (URL) -> Bool = BookScanner.isOnThisMac
    ) -> [CandidateBook] {
        var sizes: [Int: Int] = [:]
        // Anything smaller than this is no book, and says nothing by being the same.
        let smallest = 4096
        func size(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        for candidate in candidates {
            for file in candidate.files { if let s = size(file.url), s >= smallest { sizes[s, default: 0] += 1 } }
        }
        var out = candidates
        // The candidate that holds the first file with each fingerprint.
        var first: [String: Int] = [:]
        for index in out.indices {
            var kept: [CandidateFile] = []
            for file in out[index].files {
                guard let s = size(file.url), s >= smallest, sizes[s, default: 0] > 1, isOnThisMac(file.url),
                      let print = fingerprint(of: file.url)
                else {
                    kept.append(file)
                    continue
                }
                // The parts of one book are never copies of one another.
                if let owner = first[print], owner != index {
                    out[owner].copies.append(file.url)
                } else {
                    first[print] = first[print] ?? index
                    kept.append(file)
                }
            }
            out[index].files = kept
        }
        return out.filter { !$0.files.isEmpty }
    }

    /// Joins candidates with no audio that are the same book: the same first author
    /// and the same title, edition words aside. Their files go
    /// together as the forms of one book, under the details of the first found.
    /// Audiobooks are never joined to one another: two of one title are two editions.
    private func joinSameBook(_ candidates: [CandidateBook]) -> [CandidateBook] {
        var out: [CandidateBook?] = candidates
        var firstByKey: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() where !candidate.hasAudio {
            // Not by Audible ID alone: a book's map and its glossary share one.
            let keys = [matchKey(candidate).map { "name:" + $0 }].compactMap { $0 }
            if let owner = keys.compactMap({ firstByKey[$0] }).first, var kept = out[owner] {
                kept.files += candidate.files
                kept.copies += candidate.copies
                kept.filesNotOnThisMac += candidate.filesNotOnThisMac
                kept.coverBeside = kept.coverBeside ?? candidate.coverBeside
                out[owner] = kept
                out[index] = nil
            } else {
                for key in keys { firstByKey[key] = index }
            }
        }
        return out.compactMap { $0 }
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

/// A running digest of a file's contents.
private struct Fingerprint {
    private var hasher = SHA256()
    mutating func add(_ data: Data) { hasher.update(data: data) }
    var value: String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

import Foundation

public struct PlannedMove: Equatable, Sendable {
    public var from: URL
    public var to: URL

    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }
}

public enum TransferMode: Sendable {
    case move
    case copy
}

public enum OrganiserError: Error, Equatable {
    /// Something already exists at this path, or two files were given the same destination.
    case destinationExists(String)
    case sourceMissing(String)
    /// A transfer failed and some of its completed steps could not be reversed.
    /// `outstanding` lists the files still displaced: each record's `from` is where
    /// the file was before the call and `to` is where it is now, so undoing these
    /// records finishes the rollback.
    case rollbackIncomplete(cause: String, outstanding: [MoveRecord])
    /// Undoing a copy would delete something that is not a plain file.
    case notARegularFile(String)
}

/// Performs file transfers for one book at a time. Never overwrites.
public struct Organiser {
    private let fm: FileManager

    public init() { fm = .default }

    /// For tests: a file manager whose operations can be made to fail.
    init(fileManager: FileManager) { fm = fileManager }

    /// Destinations for a book's files inside the library, or nil when the book
    /// has no usable title or author and so cannot be filed.
    public static func plan(
        files: [CandidateFile], metadata: BookMetadata, libraryRoot: URL
    ) -> [PlannedMove]? {
        guard let folder = PathBuilder.bookFolder(metadata: metadata) else { return nil }
        let names = PathBuilder.fileNames(title: metadata.title, files: files)
        let base = libraryRoot.appendingPathComponent(folder, isDirectory: true)
        return zip(files, names).map {
            PlannedMove(from: $0.url, to: base.appendingPathComponent($1))
        }
    }

    /// Transfers every file of one book. If any transfer fails, the ones already
    /// done are reversed and the error is rethrown, so the book ends up where it started.
    /// If a reversal fails too, `OrganiserError.rollbackIncomplete` is thrown instead.
    ///
    /// In move mode a destination may be the current location of another file in
    /// the same batch (renumbering parts, swapping two files).
    ///
    /// - Parameter pruneRoot: After a successful move, source folders left empty are
    ///   removed, but only folders strictly inside this root. Pass the library root
    ///   when re-filing; pass nil to leave all source folders alone.
    @discardableResult
    public func transfer(
        _ moves: [PlannedMove], mode: TransferMode, pruneRoot: URL? = nil
    ) throws -> [MoveRecord] {
        let pending = moves.filter { $0.from.standardizedFileURL != $0.to.standardizedFileURL }

        // In move mode, a destination that another move of this batch vacates is free.
        let vacated = mode == .move ? Set(pending.map { $0.from.standardizedFileURL.path }) : []
        var destinations = Set<String>()
        for move in pending {
            guard fm.fileExists(atPath: move.from.path) else {
                throw OrganiserError.sourceMissing(move.from.path)
            }
            let destination = move.to.standardizedFileURL.path
            let isNewDestination = destinations.insert(destination).inserted
            if !isNewDestination || (itemExists(move.to) && !vacated.contains(destination)) {
                throw OrganiserError.destinationExists(move.to.path)
            }
        }

        try perform(pending, copy: mode == .copy)

        if mode == .move, let pruneRoot {
            for move in pending {
                prune(move.from.deletingLastPathComponent(), under: pruneRoot)
            }
        }
        return pending.map {
            MoveRecord(from: $0.from.path, to: $0.to.path, wasCopy: mode == .copy)
        }
    }

    /// Reverses completed transfers: moved files go back, copies are deleted.
    ///
    /// Safe to call again after a failure: a move whose file is already back at
    /// `from` (and gone from `to`) counts as undone, as does a copy that is gone.
    /// Nothing is overwritten, and a copy is only deleted while it is a plain file.
    public func undo(_ records: [MoveRecord], pruneRoot: URL? = nil) throws {
        var back: [PlannedMove] = []
        var copies: [URL] = []
        for record in records.reversed() {
            let to = URL(fileURLWithPath: record.to)
            if record.wasCopy {
                guard itemExists(to) else { continue }
                guard isRegularFile(to) else { throw OrganiserError.notARegularFile(to.path) }
                copies.append(to)
            } else {
                let from = URL(fileURLWithPath: record.from)
                if !itemExists(to) {
                    if itemExists(from) { continue }
                    throw OrganiserError.sourceMissing(to.path)
                }
                back.append(PlannedMove(from: to, to: from))
            }
        }

        let vacated = Set(back.map { $0.from.standardizedFileURL.path })
        var destinations = Set<String>()
        for move in back {
            let destination = move.to.standardizedFileURL.path
            let isNewDestination = destinations.insert(destination).inserted
            if !isNewDestination || (itemExists(move.to) && !vacated.contains(destination)) {
                throw OrganiserError.destinationExists(move.to.path)
            }
        }

        try perform(back, copy: false)
        for copy in copies {
            try fm.removeItem(at: copy)
        }

        if let pruneRoot {
            for record in records.reversed() {
                prune(URL(fileURLWithPath: record.to).deletingLastPathComponent(), under: pruneRoot)
            }
        }
    }

    // MARK: Performing a batch

    /// One file-system operation on one file of the batch.
    private struct Hop {
        /// Index of the file's move in the batch.
        var file: Int
        var from: URL
        var to: URL
        var copy: Bool
    }

    /// The operations for a batch, in a safe order. A file sitting where another
    /// file of the batch must go is first parked under a temporary name in its own
    /// destination folder, and given its real name once everything else has moved.
    private func hops(for moves: [PlannedMove], copy: Bool) -> [Hop] {
        let destinations = Set(moves.map { $0.to.standardizedFileURL.path })
        var parking: [Hop] = []
        var direct: [Hop] = []
        var unparking: [Hop] = []
        for (index, move) in moves.enumerated() {
            if !copy, destinations.contains(move.from.standardizedFileURL.path) {
                let parked = move.to.deletingLastPathComponent()
                    .appendingPathComponent(".voxcarrel-moving-\(UUID().uuidString)")
                parking.append(Hop(file: index, from: move.from, to: parked, copy: false))
                unparking.append(Hop(file: index, from: parked, to: move.to, copy: false))
            } else {
                direct.append(Hop(file: index, from: move.from, to: move.to, copy: copy))
            }
        }
        return parking + direct + unparking
    }

    /// Carries out a batch as a unit. On failure every completed operation is
    /// reversed, a half-written destination is removed, and folders created here
    /// are removed again; then the original error is rethrown, or
    /// `rollbackIncomplete` if some file could not be put back.
    private func perform(_ moves: [PlannedMove], copy: Bool) throws {
        var done: [Hop] = []
        var createdFolders: [URL] = []
        do {
            for hop in hops(for: moves, copy: copy) {
                try createFolder(hop.to.deletingLastPathComponent(), recording: &createdFolders)
                // Checked again here so nothing that appeared since is overwritten.
                guard !itemExists(hop.to) else {
                    throw OrganiserError.destinationExists(hop.to.path)
                }
                do {
                    if hop.copy {
                        try fm.copyItem(at: hop.from, to: hop.to)
                    } else {
                        try fm.moveItem(at: hop.from, to: hop.to)
                    }
                } catch {
                    // The destination did not exist before this operation, so anything
                    // there now is its half-written result. Only removed while the
                    // source is still intact.
                    if itemExists(hop.from), isRegularFile(hop.to) {
                        try? fm.removeItem(at: hop.to)
                    }
                    throw error
                }
                done.append(hop)
            }
        } catch {
            // Reverse newest first. A file whose reversal fails stays where it is,
            // and its earlier operations are left alone.
            var stranded: [Int: URL] = [:]
            for hop in done.reversed() where stranded[hop.file] == nil {
                do {
                    if hop.copy {
                        try fm.removeItem(at: hop.to)
                    } else {
                        guard !itemExists(hop.from) else {
                            throw OrganiserError.destinationExists(hop.from.path)
                        }
                        try fm.createDirectory(
                            at: hop.from.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try fm.moveItem(at: hop.to, to: hop.from)
                    }
                } catch {
                    stranded[hop.file] = hop.to
                }
            }
            removeIfEmpty(createdFolders)

            guard stranded.isEmpty else {
                let outstanding = stranded.keys.sorted().map {
                    MoveRecord(from: moves[$0].from.path, to: stranded[$0]!.path, wasCopy: copy)
                }
                let cause = (error as? OrganiserError).map { String(describing: $0) }
                    ?? error.localizedDescription
                throw OrganiserError.rollbackIncomplete(cause: cause, outstanding: outstanding)
            }
            throw error
        }
    }

    /// Creates `folder` and any missing parents, noting each folder it had to create.
    private func createFolder(_ folder: URL, recording created: inout [URL]) throws {
        var missing: [URL] = []
        var current = folder.standardizedFileURL
        while current.path != "/", !itemExists(current) {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        created += missing
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Removes the given folders, deepest first, skipping any that are not empty.
    private func removeIfEmpty(_ folders: [URL]) {
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// True when anything is at `url`, including a symlink that points nowhere.
    private func itemExists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Removes `folder` if it is empty (ignoring .DS_Store), then its parents,
    /// stopping at the first non-empty folder and never touching `root` itself.
    private func prune(_ folder: URL, under root: URL) {
        let rootPrefix = root.standardizedFileURL.path + "/"
        var current = folder.standardizedFileURL
        while current.path.hasPrefix(rootPrefix) {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }),
                  (try? fm.removeItem(at: current)) != nil
            else { return }
            current = current.deletingLastPathComponent()
        }
    }
}

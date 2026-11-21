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
}

/// Performs file transfers for one book at a time. Never overwrites.
public struct Organiser {
    public init() {}

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
    ///
    /// - Parameter pruneRoot: After a successful move, source folders left empty are
    ///   removed, but only folders strictly inside this root. Pass the library root
    ///   when re-filing; pass nil to leave all source folders alone.
    @discardableResult
    public func transfer(
        _ moves: [PlannedMove], mode: TransferMode, pruneRoot: URL? = nil
    ) throws -> [MoveRecord] {
        let fm = FileManager.default
        let pending = moves.filter { $0.from.standardizedFileURL != $0.to.standardizedFileURL }

        var destinations = Set<String>()
        for move in pending {
            guard fm.fileExists(atPath: move.from.path) else {
                throw OrganiserError.sourceMissing(move.from.path)
            }
            let isNewDestination = destinations.insert(move.to.standardizedFileURL.path).inserted
            if !isNewDestination || fm.fileExists(atPath: move.to.path) {
                throw OrganiserError.destinationExists(move.to.path)
            }
        }

        var done: [MoveRecord] = []
        do {
            for move in pending {
                try fm.createDirectory(
                    at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch mode {
                case .move: try fm.moveItem(at: move.from, to: move.to)
                case .copy: try fm.copyItem(at: move.from, to: move.to)
                }
                done.append(MoveRecord(from: move.from.path, to: move.to.path, wasCopy: mode == .copy))
            }
        } catch {
            try? undo(done, pruneRoot: pruneRoot)
            throw error
        }

        if mode == .move, let pruneRoot {
            for move in pending {
                prune(move.from.deletingLastPathComponent(), under: pruneRoot)
            }
        }
        return done
    }

    /// Reverses completed transfers, newest first: moved files go back, copies are deleted.
    public func undo(_ records: [MoveRecord], pruneRoot: URL? = nil) throws {
        let fm = FileManager.default
        for record in records.reversed() {
            let to = URL(fileURLWithPath: record.to)
            if record.wasCopy {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            } else {
                let from = URL(fileURLWithPath: record.from)
                if fm.fileExists(atPath: from.path) {
                    throw OrganiserError.destinationExists(from.path)
                }
                try fm.createDirectory(
                    at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: to, to: from)
            }
            if let pruneRoot {
                prune(to.deletingLastPathComponent(), under: pruneRoot)
            }
        }
    }

    /// Removes `folder` if it is empty (ignoring .DS_Store), then its parents,
    /// stopping at the first non-empty folder and never touching `root` itself.
    private func prune(_ folder: URL, under root: URL) {
        let fm = FileManager.default
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

import Foundation

/// How names are told apart on the volume a library is on.
///
/// Every volume macOS writes book folders to treats two spellings of a name that differ
/// only in Unicode form (composed or decomposed) as one name; most also ignore case.
struct VolumeNaming: Equatable, Sendable {
    /// Whether "Dune" and "dune" are two names on the volume.
    var caseSensitive: Bool

    /// What the volume holding `folder` says of itself; taken to ignore case (the more
    /// careful reading) when it does not say.
    static func of(_ folder: URL) -> VolumeNaming {
        let values = try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return VolumeNaming(caseSensitive: values?.volumeSupportsCaseSensitiveNames ?? false)
    }

    /// A name in the form names are compared in: two names with the same key are one
    /// name on the volume.
    func key(_ name: String) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        return caseSensitive ? composed : composed.lowercased()
    }

    func key(_ names: [String]) -> [String] {
        names.map(key)
    }
}

public enum FolderMoveError: Error, Equatable {
    /// The move at `index` could not be made. Every folder is where it was.
    case failed(index: Int, reason: String)
    /// The move at `index` could not be made, and some folders already moved could not
    /// be put back. Each of `outstanding` says where a folder was (`from`) and where it
    /// is now (`to`).
    case rollbackIncomplete(index: Int, reason: String, outstanding: [MoveRecord])
}

/// Moves whole folders inside a library, all or nothing, by renaming them.
///
/// Nothing is ever replaced: a folder is only renamed to a path at which nothing
/// exists, and the rename itself refuses a destination that has appeared in the
/// meantime. No file is copied, so a destination on another volume fails. Folders that
/// are in each other's way (a swap, a longer cycle, a name that differs only in
/// capitalisation, a folder moving into or out of its own path) are first set aside in
/// the library's own hidden folder.
struct FolderMover {
    /// The library folder. Only folders strictly inside it are moved or removed.
    let root: URL
    /// Where folders are set aside: `<root>/.voxcarrel/moving`.
    let parking: URL
    let naming: VolumeNaming
    /// Renames a folder to a path where nothing exists; throws when something does.
    var rename: (URL, URL) throws -> Void = FolderMover.renameWithoutReplacing

    /// For tests: a rename that throws this stops the move dead, with nothing put back,
    /// as a crash or a loss of power would.
    struct Halted: Error {}

    /// What a move is about to do beyond the moves it was given, worked out before the
    /// first folder is renamed.
    struct Preparation {
        /// Where each folder that is set aside on the way is set aside, by move index.
        var parkedAt: [Int: URL] = [:]
        /// Folders the move makes on the way to a destination: those that are not there
        /// now, and those that are now (or are inside) a folder being moved.
        var madeFolders: [URL] = []
    }

    static let manifestName = "moves.json"

    /// One line of the list kept beside folders that are set aside, so that a folder
    /// stranded there by a crash can be traced to where it belongs.
    struct ManifestEntry: Codable, Equatable {
        /// The folder's name inside the parking folder.
        var parkedAs: String
        /// Where the folder was, relative to the library.
        var folder: String
        /// Where it was going, relative to the library.
        var movingTo: String
    }

    /// Why a move cannot be made, found without changing anything.
    enum Blocker: Equatable {
        case sourceMissing
        /// Something is at the destination and the moves do not take it away.
        case destinationExists
        case outsideLibrary
    }

    // MARK: The moves, worked out

    private struct Item {
        var index: Int
        var from: [String]
        var to: [String]
        var fromKey: [String]
        var toKey: [String]
    }

    /// The moves by their places in the library, and what they vacate.
    private struct Layout {
        var items: [Item] = []
        /// Moves that name a folder outside the library, by index.
        var outside: [Int] = []
        var sources = Set<[String]>()
        /// Every folder above a source, up to but not including the library.
        var aboveSources = Set<[String]>()
        var destinations = Set<[String]>()
        var aboveDestinations = Set<[String]>()
    }

    private static func prefixes(_ key: [String]) -> [[String]] {
        (1..<max(key.count, 1)).map { Array(key.prefix($0)) }
    }

    private func layout(of moves: [PlannedMove]) -> Layout {
        let library = LibraryLayout(root: root)
        var result = Layout()
        // Nothing hidden is moved, with one exception: a folder that was set aside (by
        // a move that was cut short) may be moved out of the place it was set aside in.
        let parkingPlace = library.relativeComponents(of: parking) ?? []
        func isHidden(_ names: [String]) -> Bool { names.contains { $0.hasPrefix(".") } }
        func isSetAside(_ names: [String]) -> Bool {
            names.count == parkingPlace.count + 2 && !parkingPlace.isEmpty
                && Array(names.prefix(parkingPlace.count)) == parkingPlace
                && !isHidden(Array(names.dropFirst(parkingPlace.count)))
        }
        for (index, move) in moves.enumerated() {
            guard let from = library.relativeComponents(of: move.from),
                  let to = library.relativeComponents(of: move.to),
                  !isHidden(from) || isSetAside(from), !isHidden(to)
            else {
                result.outside.append(index)
                continue
            }
            let item = Item(index: index, from: from, to: to, fromKey: naming.key(from), toKey: naming.key(to))
            result.items.append(item)
            result.sources.insert(item.fromKey)
            result.aboveSources.formUnion(Self.prefixes(item.fromKey))
            result.destinations.insert(item.toKey)
            result.aboveDestinations.formUnion(Self.prefixes(item.toKey))
        }
        return result
    }

    private func url(_ components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    // MARK: Looking

    /// Calls `body` with the path in the form the file system is given it, as
    /// `FileManager` gives it, so that names made here are spelled as names made there.
    private static func withPath<Result>(_ url: URL, _ body: (UnsafePointer<CChar>) -> Result) -> Result {
        url.withUnsafeFileSystemRepresentation { pointer in
            if let pointer { return body(pointer) }
            return url.path.withCString(body)
        }
    }

    /// True when anything is at `url`, including a symbolic link that points nowhere.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return withPath(url) { lstat($0, &info) } == 0
    }

    /// True when a real folder is at `url`: not a file, and not a link to a folder.
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return withPath(url) { lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes the folder at `url` if it is empty; does nothing to one that is not.
    @discardableResult
    private static func removeEmptyFolder(_ url: URL) -> Bool {
        withPath(url) { rmdir($0) } == 0
    }

    private static func removeFile(_ url: URL) {
        _ = withPath(url) { unlink($0) }
    }

    /// Whether the folder at `components` holds nothing but what the moves take away:
    /// the folders being moved, folders that lead only to them, and `.DS_Store`. Such a
    /// folder is removed once the folders in it have been set aside (`prune`).
    private func isLeftEmpty(_ components: [String], by layout: Layout) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url(components).path) else {
            return false
        }
        for name in names where name != ".DS_Store" {
            let child = components + [name]
            let key = naming.key(child)
            if layout.sources.contains(key) { continue }
            guard layout.aboveSources.contains(key), Self.isFolder(url(child)), isLeftEmpty(child, by: layout)
            else { return false }
        }
        return true
    }

    /// The moves that cannot be made as things are on disk, by index. Nothing is changed.
    ///
    /// A destination at which something exists is free all the same when the moves
    /// themselves take that away: it is a folder being moved, it is inside one, or it is
    /// a folder that the moves leave empty.
    func blockers(for moves: [PlannedMove]) -> [Int: Blocker] {
        let layout = layout(of: moves)
        var found: [Int: Blocker] = [:]
        for index in layout.outside { found[index] = .outsideLibrary }
        for item in layout.items {
            if !Self.isFolder(url(item.from)) {
                found[item.index] = .sourceMissing
                continue
            }
            let above = Self.prefixes(item.toKey)
            // Inside a folder that is itself moved away: whatever is there now goes with it.
            if above.contains(where: layout.sources.contains) { continue }
            let destination = url(item.to)
            if Self.exists(destination) {
                if layout.sources.contains(item.toKey) { continue }
                if layout.aboveSources.contains(item.toKey), Self.isFolder(destination),
                   isLeftEmpty(item.to, by: layout) {
                    continue
                }
                found[item.index] = .destinationExists
            } else {
                // The nearest thing above it that exists must be a folder to make it in.
                var parent = Array(item.to.dropLast())
                while !parent.isEmpty, !Self.exists(url(parent)) { parent.removeLast() }
                if !parent.isEmpty, !Self.isFolder(url(parent)) { found[item.index] = .destinationExists }
            }
        }
        return found
    }

    // MARK: Moving

    private struct Hop {
        var index: Int
        var from: URL
        var to: URL
    }

    /// Makes every move, or none.
    ///
    /// Folders the moves leave empty are removed afterwards, upward to but never
    /// including the library folder; a folder still holding anything other than a
    /// `.DS_Store` is left alone.
    /// - Parameter willBegin: Called once everything has been checked and worked out,
    ///   just before the first folder is renamed. If it throws, nothing is moved.
    /// - Throws: `FolderMoveError`. After `.failed`, every folder is where it was.
    func move(_ moves: [PlannedMove], willBegin: ((Preparation) throws -> Void)? = nil) throws {
        guard !moves.isEmpty else { return }
        let layout = layout(of: moves)

        // Checked before anything moves.
        var seenSources = Set<[String]>(), seenDestinations = Set<[String]>()
        for item in layout.items {
            guard seenSources.insert(item.fromKey).inserted, seenDestinations.insert(item.toKey).inserted else {
                throw FolderMoveError.failed(
                    index: item.index, reason: "Two folders would be moved from or to the same place (\(url(item.to).path))")
            }
        }
        let blocked = blockers(for: moves)
        if let index = blocked.keys.min(), let blocker = blocked[index] {
            throw FolderMoveError.failed(index: index, reason: Self.describe(blocker, moves[index]))
        }

        // A folder is set aside first when it is in the way of a destination (it is
        // one, it holds one, or it is inside one), or when it is inside another folder
        // that is moved: it must be out before that one goes.
        func isSetAside(_ item: Item) -> Bool {
            if layout.destinations.contains(item.fromKey) || layout.aboveDestinations.contains(item.fromKey) {
                return true
            }
            return Self.prefixes(item.fromKey).contains {
                layout.destinations.contains($0) || layout.sources.contains($0)
            }
        }
        let aside = layout.items.filter(isSetAside).sorted {
            ($0.from.count, $1.index) > ($1.from.count, $0.index)
        }
        let slotFolder = parking.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var slots: [Int: URL] = [:]
        for (number, item) in aside.enumerated() {
            slots[item.index] = slotFolder.appendingPathComponent(String(number + 1), isDirectory: true)
        }
        // Shallowest destination first, so that a folder is in place before anything is
        // put inside it.
        let placing = layout.items.sorted {
            ($0.to.count, $0.to.joined(separator: "/"), $0.index) < ($1.to.count, $1.to.joined(separator: "/"), $1.index)
        }

        if let willBegin {
            var preparation = Preparation(parkedAt: slots)
            var seen = Set<[String]>()
            for item in layout.items {
                for depth in 1..<max(item.to.count, 1) {
                    let above = Array(item.to.prefix(depth))
                    let key = naming.key(above)
                    guard seen.insert(key).inserted else { continue }
                    let vacated = layout.sources.contains(key) || Self.prefixes(key).contains(where: layout.sources.contains)
                    if vacated || !Self.exists(url(above)) { preparation.madeFolders.append(url(above)) }
                }
            }
            do {
                try willBegin(preparation)
            } catch {
                throw FolderMoveError.failed(index: moves.startIndex, reason: LibraryService.describe(error))
            }
        }

        var done: [Hop] = []
        var created: [URL] = []
        var failedIndex = moves.startIndex
        do {
            if !aside.isEmpty {
                failedIndex = aside[0].index
                try makeFolder(slotFolder, recording: &created)
                let manifest = aside.map {
                    ManifestEntry(
                        parkedAs: slots[$0.index]?.lastPathComponent ?? "", folder: $0.from.joined(separator: "/"),
                        movingTo: $0.to.joined(separator: "/"))
                }
                try JSONEncoder().encode(manifest).write(to: slotFolder.appendingPathComponent(Self.manifestName))
            }
            for item in aside {
                failedIndex = item.index
                guard let slot = slots[item.index] else { continue }
                try hop(Hop(index: item.index, from: url(item.from), to: slot), done: &done)
                // At once, so that a folder this one was inside does not take an empty
                // folder along, and a folder the moves leave empty is out of the way
                // of the one that takes its place.
                prune(Array(item.from.dropLast()))
            }
            for item in placing {
                failedIndex = item.index
                let destination = url(item.to)
                try makeFolder(destination.deletingLastPathComponent(), recording: &created)
                try hop(Hop(index: item.index, from: slots[item.index] ?? url(item.from), to: destination), done: &done)
            }
        } catch {
            if error is Halted { throw error }
            let reason = (error as? Failure)?.reason ?? LibraryService.describe(error)
            let stranded = putBack(done, created: created)
            removeParking(slotFolder)
            removeIfEmpty(created)
            guard stranded.isEmpty else {
                let outstanding = stranded.sorted { $0.key < $1.key }.map {
                    MoveRecord(from: moves[$0.key].from.path, to: $0.value.path, wasCopy: false)
                }
                throw FolderMoveError.rollbackIncomplete(index: failedIndex, reason: reason, outstanding: outstanding)
            }
            throw FolderMoveError.failed(index: failedIndex, reason: reason)
        }

        // Every folder is in place; what follows cannot fail the move.
        removeParking(slotFolder)
        removeIfEmpty(created)
        for item in layout.items {
            prune(Array(item.from.dropLast()))
        }
    }

    private struct Failure: Error {
        var reason: String
    }

    private static func describe(_ blocker: Blocker, _ move: PlannedMove) -> String {
        switch blocker {
        case .sourceMissing: "The folder could not be found (\(move.from.path))"
        case .destinationExists: "Something is already there (\(move.to.path))"
        case .outsideLibrary: "The folder is not inside the library (\(move.from.path) to \(move.to.path))"
        }
    }

    /// One rename, to a path where nothing is.
    private func hop(_ hop: Hop, done: inout [Hop]) throws {
        guard Self.isFolder(hop.from) else {
            throw Failure(reason: "The folder could not be found (\(hop.from.path))")
        }
        // Checked again here, and once more by the rename itself, so that nothing that
        // has appeared since is replaced.
        guard !Self.exists(hop.to) else {
            throw Failure(reason: "Something is already there (\(hop.to.path))")
        }
        try rename(hop.from, hop.to)
        done.append(hop)
    }

    /// Reverses completed renames, newest first. A folder whose way back is barred stays
    /// where it is; the others still go back.
    /// - Returns: Where each folder that could not be put back now is, by move index.
    private func putBack(_ done: [Hop], created: [URL]) -> [Int: URL] {
        // Compared as the volume compares names: a folder made on the way may be
        // spelled otherwise than the folder that was there before.
        let library = LibraryLayout(root: root)
        func place(_ url: URL) -> [String]? { library.relativeComponents(of: url).map(naming.key) }
        let made = Set(created.compactMap(place))
        var stranded: [Int: URL] = [:]
        for hop in done.reversed() where stranded[hop.index] == nil {
            do {
                if Self.exists(hop.from) {
                    // A folder made on the way (to put another folder in) may stand
                    // where this one was; it is empty again by now.
                    guard let key = place(hop.from), made.contains(key), Self.removeEmptyFolder(hop.from) else {
                        throw Failure(reason: "")
                    }
                }
                try FileManager.default.createDirectory(
                    at: hop.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rename(hop.to, hop.from)
            } catch {
                stranded[hop.index] = hop.to
            }
        }
        return stranded
    }

    /// Removes the folders this call made that hold nothing (any more), deepest first.
    /// One that holds anything stays: only an empty folder can be removed this way.
    private func removeIfEmpty(_ created: [URL]) {
        for folder in created.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            Self.removeEmptyFolder(folder)
        }
    }

    /// Creates `folder` and any missing folders above it, noting each one it had to make.
    private func makeFolder(_ folder: URL, recording created: inout [URL]) throws {
        var missing: [URL] = []
        var current = folder.standardizedFileURL
        while current.pathComponents.count > 1, !Self.exists(current) {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        guard !missing.isEmpty else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created += missing
    }

    /// Removes the folder at `components` if it is empty or holds only a `.DS_Store`,
    /// then the folders above it, stopping at the first that holds anything else and
    /// never reaching the library folder itself.
    private func prune(_ components: [String]) {
        var current = components
        while !current.isEmpty {
            let folder = url(current)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  names.allSatisfy({ $0 == ".DS_Store" })
            else { return }
            if names.contains(".DS_Store") { Self.removeFile(folder.appendingPathComponent(".DS_Store")) }
            guard Self.removeEmptyFolder(folder) else { return }
            current.removeLast()
        }
    }

    /// Removes this call's parking folder, and the folder for parking itself, once no
    /// folder is left in them. A folder that could not be put back stays, with the list
    /// that says where it belongs.
    private func removeParking(_ slotFolder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: slotFolder.path) else { return }
        guard names.allSatisfy({ $0 == Self.manifestName }) else { return }
        Self.removeFile(slotFolder.appendingPathComponent(Self.manifestName))
        Self.removeEmptyFolder(slotFolder)
        Self.removeEmptyFolder(parking)
    }

    // MARK: Renaming

    /// Renames `from` to `to` only if nothing is at `to`, in one step where the volume
    /// can do that. Never copies: a destination on another volume fails.
    static func renameWithoutReplacing(_ from: URL, _ to: URL) throws {
        let code: Int32 = withPath(from) { source in
            withPath(to) { destination in
                if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return 0 }
                guard errno == ENOTSUP || errno == EINVAL else { return errno }
                // The volume cannot refuse and rename in one step: look, then rename.
                var info = stat()
                if lstat(destination, &info) == 0 { return EEXIST }
                return Darwin.rename(source, destination) == 0 ? 0 : errno
            }
        }
        guard code != 0 else { return }
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [
                NSFilePathErrorKey: to.path,
                NSLocalizedDescriptionKey: "\"\(from.lastPathComponent)\" could not be moved to \(to.path): "
                    + String(cString: strerror(code)),
            ])
    }
}

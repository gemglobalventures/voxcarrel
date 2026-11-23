import Foundation
import ZIPFoundation

/// Makes the one file that is sent for a book in several parts: a zip of them.
enum SendPackage {
    /// Writes `files` into a new zip named `name` in `folder`, uncompressed, at the zip's
    /// top level under their own names, in the order given. Returns where it is.
    ///
    /// The files are only read. The zip is written under another name and given its own
    /// once it is whole: a failure part-way leaves nothing in `folder`.
    static func write(_ files: [URL], named name: String, in folder: URL) throws -> URL {
        var seen = Set<String>()
        for file in files {
            let entry = file.lastPathComponent
            guard seen.insert(comparable(entry)).inserted else { throw SendError.nameClash(entry) }
            guard isRegularFile(file) else { throw SendError.notARegularFile(entry) }
        }
        let fm = FileManager.default
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        var info = stat()
        guard lstat(destination.path, &info) != 0 else { throw SendError.packageExists(name) }

        let partial = folder.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
        do {
            try fill(partial, with: files)
            // Fails rather than replace, should something have appeared meanwhile.
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return destination
    }

    /// The archive is closed, and so complete on disk, when this returns.
    private static func fill(_ zip: URL, with files: [URL]) throws {
        let archive = try Archive(url: zip, accessMode: .create)
        for file in files {
            // A file that turned into something else since it was looked at is not followed.
            guard isRegularFile(file) else { throw SendError.notARegularFile(file.lastPathComponent) }
            try archive.addEntry(with: file.lastPathComponent, fileURL: file, compressionMethod: .none)
        }
    }

    /// A name as the phone's disk, which may not tell capitals apart, would see it.
    private static func comparable(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether `url` is a plain file itself; a link to one is not.
    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

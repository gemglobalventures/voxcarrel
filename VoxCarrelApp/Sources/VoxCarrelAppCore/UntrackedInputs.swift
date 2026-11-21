import Foundation

/// What to hand the scan when files found loose in the library folder are imported.
public enum UntrackedInputs {
    /// The folders and files to scan for these loose files, so that they are grouped
    /// into books as in any other import (a folder of parts is one audiobook only when
    /// it is scanned as a folder).
    ///
    /// A loose file is replaced by the highest folder above it, below the library
    /// folder, that holds no file of a library book anywhere inside it; each such folder
    /// is passed once. A file with no such folder (it lies directly in the library
    /// folder, or beside or above a library book's files) is passed by itself. The
    /// library folder is never passed, and a file outside it is passed as it is.
    ///
    /// - Parameters:
    ///   - untracked: Files in the library folder that no book uses.
    ///   - tracked: Every file that belongs to a library book.
    ///   - root: The library folder.
    public static func grouped(untracked: [URL], tracked: [URL], root: URL) -> [URL] {
        let rootParts = parts(root)
        // Every folder below the library folder with a library book's file somewhere inside.
        var taken = Set<[String]>()
        for file in tracked {
            var folder = Array(parts(file).dropLast())
            while folder.count > rootParts.count, Array(folder.prefix(rootParts.count)) == rootParts {
                guard taken.insert(folder).inserted else { break }
                folder.removeLast()
            }
        }

        var inputs: [URL] = []
        var seen = Set<[String]>()
        for file in untracked {
            let fileParts = parts(file)
            var input = file
            var inputParts = fileParts
            if fileParts.count > rootParts.count + 1, Array(fileParts.prefix(rootParts.count)) == rootParts {
                // From the folder just below the library folder down to the file's own.
                for depth in (rootParts.count + 1)..<fileParts.count {
                    let folder = Array(fileParts.prefix(depth))
                    guard !taken.contains(folder) else { continue }
                    input = file
                    for _ in depth..<fileParts.count { input = input.deletingLastPathComponent() }
                    inputParts = folder
                    break
                }
            }
            if seen.insert(inputParts).inserted { inputs.append(input) }
        }
        return inputs
    }

    /// A path's parts in the form used to compare places: links followed, capitals ignored.
    private static func parts(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
    }
}

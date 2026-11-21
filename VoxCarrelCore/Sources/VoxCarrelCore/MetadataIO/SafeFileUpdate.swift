import Foundation

/// The one way VoxCarrel changes the inside of a user's file:
/// copy it, change the copy, check the copy, then swap the copy in.
enum SafeFileUpdate {
    /// - Parameters:
    ///   - url: The file to update. Left untouched if anything throws.
    ///   - change: Modifies the copy at the URL it is given.
    ///   - verify: Throws if the changed copy is not acceptable.
    /// - Throws: `MetadataIOError.notARegularFile` for a symbolic link, folder or package (a
    ///   link is never followed, because the copy would be another link and the change would
    ///   land in the real file); `.locked` when the file or its folder cannot be written;
    ///   `.cleanupFailed` when the write was abandoned but the working copy could not be
    ///   deleted; otherwise whatever `change`, `verify` or the file system threw.
    static func update(
        _ url: URL,
        change: (_ copy: URL) throws -> Void,
        verify: (_ copy: URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()

        // Resource values describe the item itself: a symbolic link is not resolved.
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isUserImmutableKey, .isSystemImmutableKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MetadataIOError.notARegularFile(name)
        }
        guard values.isUserImmutable != true, values.isSystemImmutable != true,
              fm.isWritableFile(atPath: url.path), fm.isWritableFile(atPath: folder.path)
        else { throw MetadataIOError.locked(name) }

        // Hidden, in the same folder (same volume, so the swap is atomic), and with
        // the same extension, because the format libraries choose a parser by it.
        let copy = folder.appendingPathComponent(".voxcarrel-\(UUID().uuidString).\(url.pathExtension)")
        do {
            // On APFS this is an instant copy-on-write clone; elsewhere a full copy.
            try fm.copyItem(at: url, to: copy)
            try change(copy)
            try verify(copy)
            _ = try fm.replaceItemAt(url, withItemAt: copy)
        } catch {
            try discard(copy)
            throw error
        }
    }

    /// Deletes the working copy. A copy that has become immutable or read-only is unlocked
    /// first. If it still cannot be deleted the caller is told where it is, rather than a
    /// hidden file being left behind silently.
    private static func discard(_ copy: URL) throws {
        let fm = FileManager.default
        var info = stat()
        guard lstat(copy.path, &info) == 0 else { return } // never created, or already swapped in
        if (try? fm.removeItem(at: copy)) != nil { return }
        _ = chflags(copy.path, 0)
        _ = chmod(copy.path, 0o600)
        do {
            try fm.removeItem(at: copy)
        } catch {
            throw MetadataIOError.cleanupFailed(copy.path)
        }
    }
}

import Foundation

/// The one way VoxCarrel changes the inside of a user's file:
/// copy it, change the copy, check the copy, then swap the copy in.
enum SafeFileUpdate {
    /// - Parameters:
    ///   - url: The file to update. Left untouched if anything throws.
    ///   - change: Modifies the copy at the URL it is given.
    ///   - verify: Throws if the changed copy is not acceptable.
    static func update(
        _ url: URL,
        change: (_ copy: URL) throws -> Void,
        verify: (_ copy: URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        // Hidden, in the same folder (same volume, so the swap is atomic), and with
        // the same extension, because the format libraries choose a parser by it.
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent(".voxcarrel-\(UUID().uuidString).\(url.pathExtension)")
        // On APFS this is an instant copy-on-write clone; elsewhere a full copy.
        try fm.copyItem(at: url, to: copy)
        do {
            try change(copy)
            try verify(copy)
            _ = try fm.replaceItemAt(url, withItemAt: copy)
        } catch {
            try? fm.removeItem(at: copy)
            throw error
        }
    }
}

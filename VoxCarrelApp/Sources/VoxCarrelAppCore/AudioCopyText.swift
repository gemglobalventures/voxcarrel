import Foundation
import VoxCarrelCore

/// A copy of an audiobook in a few words, for setting two copies side by side:
/// "MP3, 3 files, about 64 kbps".
public enum AudioCopyText {
    /// The kinds of file, how many, and about how many kilobits a second they hold,
    /// worked out from their size and the length given. Nil for no files. The rate
    /// is left out when a size or the length is not known.
    public static func text(formats: [FileFormat], urls: [URL], seconds: Double?) -> String? {
        guard !formats.isEmpty else { return nil }
        var kinds: [String] = []
        for format in formats where !kinds.contains(format.rawValue.uppercased()) { kinds.append(format.rawValue.uppercased()) }
        var parts = [kinds.joined(separator: " and "), formats.count == 1 ? "1 file" : "\(formats.count) files"]
        let sizes = urls.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        if let seconds, seconds > 0, !sizes.isEmpty, sizes.allSatisfy({ $0 != nil }) {
            let bytes = sizes.compactMap { $0 }.reduce(0, +)
            let rate = Int((Double(bytes) * 8 / seconds / 1000).rounded())
            if rate > 0 { parts.append("about \(rate) kbps") }
        }
        return parts.joined(separator: ", ")
    }
}

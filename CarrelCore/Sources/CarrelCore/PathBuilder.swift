import Foundation

/// Pure rules for where a book lives inside the library folder.
public enum PathBuilder {
    /// Subfolder of a book folder that holds its extras.
    public static let extrasFolderName = "Extras"

    /// Makes a string safe to use as one path component.
    public static func sanitise(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        s = String(s.prefix(200))
        while let first = s.first, first == "." || first == " " { s.removeFirst() }
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    /// Folder for a book, relative to the library root:
    /// `Author/Title` or `Author/Series/N - Title`.
    /// Returns nil when the book has no usable title or first author.
    public static func bookFolder(metadata: BookMetadata) -> String? {
        let title = sanitise(metadata.title)
        let author = sanitise(metadata.authors.first ?? "")
        guard !title.isEmpty, !author.isEmpty else { return nil }

        var parts = [author]
        let series = sanitise(metadata.series ?? "")
        if series.isEmpty {
            parts.append(title)
        } else {
            parts.append(series)
            let number = sanitise(metadata.seriesNumber ?? "")
            parts.append(number.isEmpty ? title : "\(number) - \(title)")
        }
        return parts.joined(separator: "/")
    }

    /// File names for a book's files, relative to the book folder, in the same
    /// order as `files`.
    /// - audio: `Title.ext`, or `01 - Title.ext` when the book has several audio parts
    /// - ebook: `Title.ext`
    /// - extra: `Extras/<original name>.ext`
    public static func fileNames(title: String, files: [CandidateFile]) -> [String] {
        let base = sanitise(title)
        let audioCount = files.filter { $0.role == .audio }.count
        let width = max(2, String(audioCount).count)
        var audioIndex = 0

        return files.map { file in
            let ext = file.url.pathExtension.lowercased()
            switch file.role {
            case .audio:
                guard audioCount > 1 else { return "\(base).\(ext)" }
                audioIndex += 1
                let number = String(audioIndex)
                let padded = String(repeating: "0", count: width - number.count) + number
                return "\(padded) - \(base).\(ext)"
            case .ebook:
                return "\(base).\(ext)"
            case .extra:
                let name = sanitise(file.url.deletingPathExtension().lastPathComponent)
                return "\(extrasFolderName)/\(name).\(ext)"
            }
        }
    }
}

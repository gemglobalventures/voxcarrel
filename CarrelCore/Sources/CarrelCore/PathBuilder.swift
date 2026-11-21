import Foundation

/// Pure rules for where a book lives inside the library folder.
public enum PathBuilder {
    /// Subfolder of a book folder that holds its extras.
    public static let extrasFolderName = "Extras"

    /// Longest allowed path component, in characters.
    public static let maxComponentLength = 200

    /// Makes a string safe to use as one path component.
    public static func sanitise(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        var s = String(scalars)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        s = String(s.prefix(maxComponentLength))
        while let first = s.first, first == "." || first == " " { s.removeFirst() }
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    /// Shortens an already sanitised string to `length` characters, without
    /// leaving a trailing space or dot.
    private static func capped(_ sanitised: String, to length: Int) -> String {
        var s = String(sanitised.prefix(max(length, 1)))
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
            parts.append(
                number.isEmpty ? title : capped("\(number) - \(title)", to: maxComponentLength))
        }
        return parts.joined(separator: "/")
    }

    /// File names for a book's files, relative to the book folder, in the same
    /// order as `files`.
    /// - audio: `Title.ext`, or `01 - Title.ext` when the book has several audio parts
    /// - ebook: `Title.ext`
    /// - extra: `Extras/<original name>.ext`
    ///
    /// No name is returned twice (compared ignoring case): a later file that would
    /// repeat one gets " 2", " 3"… before its extension. Each name, extension
    /// included, is at most `maxComponentLength` characters.
    public static func fileNames(title: String, files: [CandidateFile]) -> [String] {
        let base = sanitise(title)
        let audioCount = files.filter { $0.role == .audio }.count
        let width = max(2, String(audioCount).count)
        var audioIndex = 0
        var used = Set<String>()

        return files.map { file in
            let ext = sanitise(file.url.pathExtension.lowercased())
            var folder = ""
            let stem: String
            switch file.role {
            case .audio where audioCount > 1:
                audioIndex += 1
                let number = String(audioIndex)
                let padded = String(repeating: "0", count: width - number.count) + number
                stem = "\(padded) - \(base)"
            case .audio, .ebook:
                stem = base
            case .extra:
                folder = "\(extrasFolderName)/"
                let name = sanitise(file.url.deletingPathExtension().lastPathComponent)
                stem = name.isEmpty ? "Extra" : name
            }

            var copy = 1
            while true {
                let ending = (copy == 1 ? "" : " \(copy)") + (ext.isEmpty ? "" : ".\(ext)")
                let name = folder + capped(stem, to: maxComponentLength - ending.count) + ending
                if used.insert(name.lowercased()).inserted { return name }
                copy += 1
            }
        }
    }
}

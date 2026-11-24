import Foundation

/// What lies beside a book and describes it: the details file calibre keeps
/// (`metadata.opf`) and a picture of the cover.
enum Sidecar {
    /// Names (lowercased, without the ending) a cover picture beside a book goes by.
    static let coverNames: Set<String> = ["cover", "folder", "front", "poster"]
    static let pictureEndings: Set<String> = ["jpg", "jpeg", "png"]

    /// The one details file among `files`, if there is exactly one.
    static func detailsFile(among files: [URL]) -> URL? {
        let found = files.filter { $0.pathExtension.lowercased() == "opf" }
        return found.count == 1 ? found[0] : nil
    }

    /// The cover picture among `files`: one named as covers are, or failing that the
    /// only picture there is.
    static func cover(among files: [URL]) -> URL? {
        let pictures = files.filter { pictureEndings.contains($0.pathExtension.lowercased()) }
        if let named = pictures.first(where: { coverNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }) {
            return named
        }
        return pictures.count == 1 ? pictures[0] : nil
    }

    /// The details a details file gives; nil when it cannot be read or names no title.
    /// Its subjects are left out: they are the keeper's own tags, not genres.
    static func details(at url: URL) -> BookMetadata? {
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let document = try? XMLDocument(data: data),
              let metadata = document.rootElement()?.elements(forName: "metadata").first
                ?? document.rootElement()?.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "metadata" })
        else { return nil }
        let children = (metadata.children ?? []).compactMap { $0 as? XMLElement }
        func texts(_ name: String) -> [String] {
            children.filter { $0.localName == name }
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        func named(_ name: String) -> String? {
            children.first { $0.localName == "meta" && $0.attribute(forName: "name")?.stringValue == name }?
                .attribute(forName: "content")?.stringValue?.trimmingCharacters(in: .whitespaces)
        }
        guard let title = texts("title").first else { return nil }
        var details = BookMetadata()
        details.title = title
        details.authors = texts("creator")
        details.publisher = texts("publisher").first
        details.language = texts("language").first
        details.year = texts("date").first.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }.flatMap { (1...9999).contains($0) && $0 > 1000 ? $0 : nil }
        details.summary = texts("description").first.map(plain)
        details.series = named("calibre:series").flatMap { $0.isEmpty ? nil : $0 }
        if details.series != nil, let index = named("calibre:series_index"), !index.isEmpty {
            details.seriesNumber = index.hasSuffix(".0") ? String(index.dropLast(2)) : index
        }
        for identifier in children where identifier.localName == "identifier" {
            let scheme = identifier.attributes?.first { $0.localName == "scheme" }?.stringValue?.lowercased()
            let value = (identifier.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if scheme == "isbn" { details.isbn = value }
            if scheme == "asin" || scheme == "mobi-asin" || scheme == "amazon" { details.asin = value }
        }
        return details
    }

    /// Text with its markup taken out.
    static func plain(_ text: String) -> String {
        var out = ""
        var inTag = false
        for character in text {
            if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag { out.append(character) }
        }
        return out.replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

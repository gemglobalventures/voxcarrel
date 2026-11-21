import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

struct EpubMetadata: Equatable, Sendable {
    var title: String?
    var authors: [String] = []
    var series: String?
    var seriesNumber: String?
    var publisher: String?
    /// Raw dc:date, e.g. "2019" or "2019-03-01T00:00:00Z".
    var date: String?
    var language: String?
    var summary: String?
    var isbn: String?
    var subjects: [String] = []
    init() {}
    var year: Int? { date.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
}

/// Why an EPUB could not be handled. Never leaves this file: `read` and `write` report
/// `MetadataIOError` instead.
enum EpubError: Error { case missing(String), invalid(String) }

/// EPUB metadata and covers. Only the OPF package document and the cover image are ever changed.
enum EpubIO {
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let opf = "http://www.idpf.org/2007/opf"

    /// Fields an EPUB cannot hold.
    static let unstorable: Set<MetadataField> = [.subtitle, .narrators, .asin]

    // MARK: Read

    static func read(_ url: URL) throws -> FileContents {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            let package = try Package(archive: archive)
            return FileContents(metadata: bookMetadata(from: package.readMetadata()),
                                cover: try package.readCover(archive), chapters: [])
        } catch let error as MetadataIOError {
            throw error
        } catch {
            throw MetadataIOError.unreadable(url.lastPathComponent)
        }
    }

    // MARK: Write

    /// Edits a copy of the EPUB and swaps it in. Only the OPF entry (and the cover image entry, if
    /// asked) is replaced; every other entry keeps its original compressed bytes, and `mimetype`
    /// stays the first entry, stored uncompressed.
    @discardableResult
    static func write(_ metadata: BookMetadata, cover: CoverChange, to url: URL) throws -> WriteReport {
        let name = url.lastPathComponent
        try SafeFileUpdate.update(url) { copy in
            do { // scope so the archive's file handle is closed before the swap
                let archive = try Archive(url: copy, accessMode: .update)
                let package = try Package(archive: archive)
                package.apply(epubMetadata(from: metadata, existing: package.readMetadata()))
                if case .set(let image) = cover { try package.setCover(image, in: archive) }
                // .remove is deliberately not offered: the cover is usually referenced from XHTML.
                try replace(package.opfPath, with: package.serialized(), in: archive)
            } catch let error as MetadataIOError {
                throw error
            } catch {
                throw MetadataIOError.unreadable(name)
            }
        } verify: { copy in
            do {
                try validate(copy)
            } catch {
                throw MetadataIOError.verificationFailed("EPUB structure check failed")
            }
        }
        return WriteReport(notWritten: cover == .remove ? unstorable.union([.cover]) : unstorable)
    }

    // MARK: Mapping

    static func bookMetadata(from e: EpubMetadata) -> BookMetadata {
        var m = BookMetadata(title: e.title ?? "", authors: e.authors)
        m.series = e.series
        m.seriesNumber = e.seriesNumber
        m.publisher = e.publisher
        m.year = e.year
        m.language = e.language
        m.summary = e.summary
        m.isbn = e.isbn
        m.genre = e.subjects.isEmpty ? nil : e.subjects.joined(separator: "; ")
        return m
    }

    /// `existing` supplies the stored date, kept when its year already matches.
    static func epubMetadata(from m: BookMetadata, existing: EpubMetadata) -> EpubMetadata {
        var e = EpubMetadata()
        e.title = m.title.isEmpty ? nil : m.title
        e.authors = m.authors
        e.series = m.series
        e.seriesNumber = m.seriesNumber
        e.publisher = m.publisher
        e.date = m.year == existing.year ? existing.date : m.year.map(String.init)
        e.language = m.language
        e.summary = m.summary
        e.isbn = m.isbn
        e.subjects = (m.genre ?? "").components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return e
    }

    // MARK: Archive

    static func data(_ path: String, in archive: Archive) throws -> Data {
        guard let entry = archive[path] else { throw EpubError.missing(path) }
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }

    static func replace(_ path: String, with data: Data, in archive: Archive) throws {
        if let old = archive[path] { try archive.remove(old) }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    /// OCF rule: the first entry is `mimetype`, stored, with no extra field, so the bytes at
    /// offset 30 read "mimetypeapplication/epub+zip".
    static func validate(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 58) ?? Data())
        guard head.count == 58, head[0...3] == [0x50, 0x4B, 0x03, 0x04],
              head[8] == 0, head[9] == 0, // compression method 0 = stored
              head[26] == 8, head[27] == 0, // file name length
              head[28] == 0, head[29] == 0, // extra field length
              String(decoding: head[30...], as: UTF8.self) == "mimetypeapplication/epub+zip"
        else { throw EpubError.invalid("mimetype is not the first, stored entry") }
        _ = try read(url) // container.xml and the OPF still parse
    }

    // MARK: OPF package document

    final class Package {
        let opfPath: String
        let document: XMLDocument
        let root: XMLElement
        let metadata: XMLElement
        let manifest: XMLElement
        var version: String { root.attribute(forName: "version")?.stringValue ?? "2.0" }
        var isEPUB3: Bool { version.hasPrefix("3") }

        init(archive: Archive) throws {
            let container = try XMLDocument(data: EpubIO.data("META-INF/container.xml", in: archive))
            guard let path = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue
            else { throw EpubError.missing("rootfile in container.xml") }
            opfPath = path
            // nodePreserveAll keeps whitespace, quoting, CDATA and empty-element style of everything we do not touch.
            document = try XMLDocument(data: EpubIO.data(path, in: archive), options: [.nodePreserveAll])
            guard let root = document.rootElement(), let metadata = root.child("metadata"), let manifest = root.child("manifest")
            else { throw EpubError.invalid("OPF has no metadata or manifest") }
            self.root = root; self.metadata = metadata; self.manifest = manifest
        }

        /// XMLDocument.xmlData would add standalone="yes" to the declaration and drop the newline
        /// after it, so the declaration is written by hand and the top-level nodes (comments,
        /// processing instructions, the root element) are serialised one by one.
        func serialized() -> Data {
            let body = (document.children ?? []).map { $0.xmlString(options: [.nodePreserveAll]) }.joined(separator: "\n")
            return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body).utf8)
        }

        // Reading

        func dcElements(_ name: String) -> [XMLElement] { metadata.elements(forLocalName: name, uri: EpubIO.dc) }
        func dcText(_ name: String) -> String? { dcElements(name).first?.stringValue?.trimmed.nilIfEmpty }
        var metas: [XMLElement] { metadata.childElements.filter { $0.localName == "meta" } }
        func namedMeta(_ name: String) -> XMLElement? { metas.first { $0.attr("name") == name } }
        func refinements(of id: String, property: String) -> [XMLElement] {
            metas.filter { $0.attr("refines") == "#" + id && $0.attr("property") == property }
        }

        func role(of creator: XMLElement) -> String? {
            if let role = creator.attribute(forLocalName: "role", uri: EpubIO.opf)?.stringValue { return role }
            if let id = creator.attr("id") { return refinements(of: id, property: "role").first?.stringValue }
            return nil
        }
        var authorElements: [XMLElement] { dcElements("creator").filter { (role(of: $0) ?? "aut") == "aut" } }

        func isISBN(_ e: XMLElement) -> Bool {
            let scheme = e.attribute(forLocalName: "scheme", uri: EpubIO.opf)?.stringValue?.lowercased()
            return scheme == "isbn" || (e.stringValue ?? "").lowercased().hasPrefix("urn:isbn:")
        }
        var isbnElement: XMLElement? {
            let uniqueID = root.attr("unique-identifier")
            let all = dcElements("identifier").filter(isISBN)
            return all.first { $0.attr("id") != uniqueID } ?? all.first
        }
        var collection: XMLElement? { metas.first { $0.attr("property") == "belongs-to-collection" && $0.attr("refines") == nil } }

        func readMetadata() -> EpubMetadata {
            var m = EpubMetadata()
            m.title = dcText("title")
            m.authors = authorElements.compactMap { $0.stringValue?.trimmed.nilIfEmpty }
            m.publisher = dcText("publisher")
            m.date = dcText("date")
            m.language = dcText("language")
            m.summary = dcText("description")
            m.subjects = dcElements("subject").compactMap { $0.stringValue?.trimmed.nilIfEmpty }
            m.isbn = isbnElement?.stringValue.map { $0.trimmed.replacingOccurrences(of: "urn:isbn:", with: "", options: .caseInsensitive) }
            if let series = namedMeta("calibre:series")?.attr("content")?.nilIfEmpty {
                m.series = series
                m.seriesNumber = namedMeta("calibre:series_index")?.attr("content").map(Self.tidyIndex)
            } else if let c = collection {
                m.series = c.stringValue?.trimmed.nilIfEmpty
                m.seriesNumber = c.attr("id").flatMap { refinements(of: $0, property: "group-position").first?.stringValue?.trimmed }
            }
            return m
        }

        /// calibre writes "1.0" for book 1; show that as "1" but keep "2.5".
        static func tidyIndex(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }

        var coverItem: XMLElement? {
            let items = manifest.childElements.filter { $0.localName == "item" }
            if let item = items.first(where: { ($0.attr("properties") ?? "").split(separator: " ").contains("cover-image") }) { return item }
            if let id = namedMeta("cover")?.attr("content"), let item = items.first(where: { $0.attr("id") == id }) { return item }
            return nil
        }

        func archivePath(forHref href: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            let base = (opfPath as NSString).deletingLastPathComponent
            return base.isEmpty ? decoded : NSString(string: base + "/" + decoded).standardizingPath
        }

        func readCover(_ archive: Archive) throws -> CoverImage? {
            guard let item = coverItem, let href = item.attr("href") else { return nil }
            let path = archivePath(forHref: href)
            guard archive[path] != nil else { return nil }
            return CoverImage(data: try EpubIO.data(path, in: archive), mime: item.attr("media-type") ?? "image/jpeg")
        }

        // Writing

        func apply(_ m: EpubMetadata) {
            let old = readMetadata()
            setDC("title", m.title)
            setDC("publisher", m.publisher)
            setDC("date", m.date)
            setDC("language", m.language)
            setDC("description", m.summary)

            if m.authors != old.authors {
                authorElements.forEach(removeWithRefinements)
                for (i, name) in m.authors.enumerated() {
                    let e = makeDC("creator", name)
                    if isEPUB3 {
                        let id = "voxcarrel-creator-\(i + 1)"
                        e.setAttr("id", id)
                        append(e)
                        append(makeMeta(["refines": "#" + id, "property": "role", "scheme": "marc:relators"], text: "aut"))
                    } else {
                        ensureNamespace("opf", EpubIO.opf)
                        e.setAttr("opf:role", "aut", uri: EpubIO.opf)
                        append(e)
                    }
                }
            }
            if m.subjects != old.subjects {
                dcElements("subject").forEach(removeWithRefinements)
                m.subjects.forEach { append(makeDC("subject", $0)) }
            }
            if m.isbn != old.isbn {
                // Never rewrite the package's unique identifier: readers key annotations (and font
                // obfuscation) on it. Only a separate ISBN identifier is edited.
                let uniqueID = root.attr("unique-identifier")
                if let e = isbnElement, e.attr("id") != uniqueID {
                    if let isbn = m.isbn { e.stringValue = (e.stringValue ?? "").lowercased().hasPrefix("urn:isbn:") ? "urn:isbn:" + isbn : isbn }
                    else { removeWithRefinements(e) }
                } else if let isbn = m.isbn {
                    if isEPUB3 { append(makeDC("identifier", "urn:isbn:" + isbn)) } else {
                        let e = makeDC("identifier", isbn)
                        ensureNamespace("opf", EpubIO.opf)
                        e.setAttr("opf:scheme", "ISBN", uri: EpubIO.opf)
                        append(e)
                    }
                }
            }
            if m.series != old.series || m.seriesNumber != old.seriesNumber {
                // calibre's pair is what calibre, Audiobookshelf, Kavita and KOReader read, in EPUB 2 and 3 alike.
                setNamedMeta("calibre:series", m.series)
                setNamedMeta("calibre:series_index", m.series == nil ? nil : (m.seriesNumber ?? "1"))
                if isEPUB3 {
                    if let c = collection {
                        if let id = c.attr("id") { metas.filter { $0.attr("refines") == "#" + id }.forEach(remove) }
                        remove(c)
                    }
                    if let series = m.series {
                        let id = "voxcarrel-series"
                        append(makeMeta(["property": "belongs-to-collection", "id": id], text: series))
                        append(makeMeta(["refines": "#" + id, "property": "collection-type"], text: "series"))
                        if let n = m.seriesNumber { append(makeMeta(["refines": "#" + id, "property": "group-position"], text: n)) }
                    }
                }
            }
            if isEPUB3, let modified = metas.first(where: { $0.attr("property") == "dcterms:modified" }) {
                let f = ISO8601DateFormatter() // EPUB 3 wants CCYY-MM-DDThh:mm:ssZ exactly
                modified.stringValue = f.string(from: Date())
            }
        }

        /// Replaces the cover image bytes. Keeps the existing manifest item, path and media type
        /// (converting the image if needed) so XHTML cover pages that point at it keep working.
        func setCover(_ image: CoverImage, in archive: Archive) throws {
            if let item = coverItem, let href = item.attr("href") {
                let wanted = item.attr("media-type") ?? image.mime
                let data = wanted == image.mime ? image.data : try EpubIO.convert(image.data, toMIME: wanted)
                try EpubIO.replace(archivePath(forHref: href), with: data, in: archive)
            } else {
                let ext = image.mime == "image/png" ? "png" : "jpg"
                let href = "voxcarrel-cover." + ext
                let item = XMLElement(name: "item")
                item.setAttr("id", "voxcarrel-cover"); item.setAttr("href", href); item.setAttr("media-type", image.mime)
                if isEPUB3 { item.setAttr("properties", "cover-image") }
                append(item, to: manifest)
                setNamedMeta("cover", "voxcarrel-cover") // the EPUB 2 convention, also honoured by EPUB 3 readers
                try EpubIO.replace(archivePath(forHref: href), with: image.data, in: archive)
            }
        }

        // DOM helpers

        var dcPrefix: String { metadata.resolvePrefix(forNamespaceURI: EpubIO.dc) ?? { ensureNamespace("dc", EpubIO.dc); return "dc" }() }
        func ensureNamespace(_ prefix: String, _ uri: String) {
            if metadata.resolvePrefix(forNamespaceURI: uri) == nil {
                metadata.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
            }
        }
        func makeDC(_ name: String, _ text: String) -> XMLElement {
            let e = XMLElement(name: dcPrefix + ":" + name, uri: EpubIO.dc)
            e.stringValue = text
            return e
        }
        func makeMeta(_ attributes: [String: String], text: String? = nil) -> XMLElement {
            // Reuse whatever name existing <meta> elements have (covers the rare "opf:meta" spelling).
            let e = XMLElement(name: metas.first?.name ?? "meta")
            for (k, v) in attributes.sorted(by: { $0.key < $1.key }) { e.setAttr(k, v) }
            if let text { e.stringValue = text }
            return e
        }
        func setDC(_ name: String, _ value: String?) {
            let existing = dcElements(name)
            if let value, !value.isEmpty {
                if let first = existing.first { if first.stringValue != value { first.stringValue = value } }
                else { append(makeDC(name, value)) }
            } else { existing.forEach(removeWithRefinements) }
        }
        func setNamedMeta(_ name: String, _ content: String?) {
            if let content {
                if let e = namedMeta(name) { e.setAttr("content", content) }
                else { append(makeMeta(["name": name, "content": content])) }
            } else { metas.filter { $0.attr("name") == name }.forEach(remove) }
        }
        func append(_ e: XMLElement, to parent: XMLElement? = nil) {
            let parent = parent ?? metadata
            // Insert before the trailing whitespace so the closing tag keeps its indentation.
            let trailingText = parent.children?.last.flatMap { $0.kind == .text ? $0 : nil }
            let index = trailingText.map { $0.index } ?? parent.childCount
            parent.insertChild(e, at: index)
            parent.insertChild(XMLNode.text(withStringValue: "\n    ") as! XMLNode, at: index)
        }
        func remove(_ e: XMLElement) {
            guard let parent = e.parent as? XMLElement else { return }
            // Drop the whitespace that preceded the element too, to avoid leaving blank lines.
            if e.index > 0, let before = parent.child(at: e.index - 1), before.kind == .text,
               (before.stringValue ?? "").trimmed.isEmpty { parent.removeChild(at: e.index - 1) }
            parent.removeChild(at: e.index)
        }
        func removeWithRefinements(_ e: XMLElement) {
            if let id = e.attr("id") { metas.filter { $0.attr("refines") == "#" + id }.forEach(remove) }
            remove(e)
        }
    }

    static func convert(_ data: Data, toMIME mime: String) throws -> Data {
        guard let type = UTType(mimeType: mime), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EpubError.invalid("cover image") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw EpubError.invalid("cover type \(mime)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EpubError.invalid("cover encode") }
        return out as Data
    }
}

private extension XMLElement {
    var childElements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func child(_ localName: String) -> XMLElement? { childElements.first { $0.localName == localName } }
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    func setAttr(_ name: String, _ value: String, uri: String? = nil) {
        if let a = attribute(forName: name) { a.stringValue = value; return }
        // Under nodePreserveAll a freshly made attribute is serialised with single quotes, and
        // XMLNode(kind:options: .nodeUseDoubleQuotes) does not change that. An attribute detached
        // from a parsed template remembers its double quotes, so new ones are made that way.
        let template = try! XMLDocument(xmlString: "<t a=\"\"/>", options: [.nodePreserveAll])
        let a = template.rootElement()!.attribute(forName: "a")!
        a.detach()
        a.name = name
        if let uri { a.uri = uri }
        a.stringValue = value
        addAttribute(a)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

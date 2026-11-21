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
enum EpubError: Error {
    case missing(String), invalid(String)
    var reason: String {
        switch self {
        case .missing(let what): return "missing \(what)"
        case .invalid(let what): return what
        }
    }
}

/// EPUB metadata and covers. Only the OPF package document and the cover image are ever changed.
enum EpubIO {
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let opf = "http://www.idpf.org/2007/opf"

    /// Fields an EPUB cannot hold.
    static let unstorable: Set<MetadataField> = [.subtitle, .narrators, .asin]

    /// Keeps the whitespace, quoting, CDATA and empty-element style of everything left untouched.
    ///
    /// `.nodePreserveCharacterReferences` is deliberately left out. With it, XMLDocument
    /// mis-handles any text that mixes a numeric reference with `&amp;` or `&lt;`:
    /// `Tom &amp; Jerry&#8217;s` is written back with a bare `&` (malformed), and
    /// `&#8220;Q&amp;A&#8221;` is read and written back with part of the text duplicated. Without
    /// it, a numeric reference is written back as the character itself, which is the same text.
    static let xmlOptions: XMLNode.Options = XMLNode.Options.nodePreserveAll.subtracting(.nodePreserveCharacterReferences)

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
    ///
    /// Some things are deliberately not done, and are reported in `notWritten` instead:
    /// - `.cover` when removal is asked for (the image is usually referenced from the pages),
    ///   when the existing cover item's file is not in the archive, or when the new image cannot
    ///   be converted to the existing cover's type (SVG, say);
    /// - `.isbn` when the only ISBN is the package's unique identifier, which is never rewritten.
    ///
    /// `dc:title` and `dc:language` are required by the format, so an empty title or a nil
    /// language leaves the existing element as it is rather than removing it.
    @discardableResult
    static func write(_ metadata: BookMetadata, cover: CoverChange, to url: URL) throws -> WriteReport {
        let name = url.lastPathComponent
        // Plenty of real EPUBs break the mimetype rule. Only a file that follows it now has
        // to follow it afterwards.
        let followsMimetypeRule = (try? checkMimetypeRule(url)) != nil
        var notWritten = unstorable
        if cover == .remove { notWritten.insert(.cover) }
        var expectation: Expectation?
        try SafeFileUpdate.update(url) { copy in
            do { // scope so the archive's file handle is closed before the swap
                let archive = try Archive(url: copy, accessMode: .update)
                let package = try Package(archive: archive)
                guard !package.hasInternalDTDSubset else { throw EpubError.invalid("DOCTYPE with an internal subset") }
                notWritten.formUnion(package.apply(epubMetadata(from: metadata, existing: package.readMetadata())))
                if case .set(let image) = cover, try !package.setCover(image, in: archive) { notWritten.insert(.cover) }
                // .remove is deliberately not offered: the cover is usually referenced from XHTML.
                expectation = package.expectation(mimetypeRule: followsMimetypeRule)
                try replace(package.opfPath, with: package.serialized(), in: archive)
            } catch let error as MetadataIOError {
                throw error
            } catch {
                throw MetadataIOError.unreadable(name)
            }
        } verify: { copy in
            guard let expectation else { throw MetadataIOError.verificationFailed("nothing was written") }
            do {
                try verify(copy, against: expectation)
            } catch let error as EpubError {
                throw MetadataIOError.verificationFailed("EPUB check failed: \(error.reason)")
            } catch {
                throw MetadataIOError.verificationFailed("EPUB structure check failed")
            }
        }
        return WriteReport(notWritten: notWritten)
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

    // MARK: Checks

    /// OCF rule: the first entry is `mimetype`, stored, with no extra field, so the bytes at
    /// offset 30 read "mimetypeapplication/epub+zip".
    static func checkMimetypeRule(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 58) ?? Data())
        guard head.count == 58, head[0...3] == [0x50, 0x4B, 0x03, 0x04],
              head[8] == 0, head[9] == 0, // compression method 0 = stored
              head[26] == 8, head[27] == 0, // file name length
              head[28] == 0, head[29] == 0, // extra field length
              String(decoding: head[30...], as: UTF8.self) == "mimetypeapplication/epub+zip"
        else { throw EpubError.invalid("mimetype is not the first, stored entry") }
    }

    /// What `unzip -t` checks: every entry can be extracted and matches its stored CRC.
    static func checkIntegrity(_ archive: Archive) throws {
        for entry in archive where entry.type == .file {
            let crc = try archive.extract(entry, skipCRC32: false) { _ in }
            guard crc == entry.checksum else { throw EpubError.invalid("entry \(entry.path) is damaged") }
        }
    }

    /// A strictly valid container: the mimetype rule holds, every entry is intact, and
    /// container.xml and the OPF parse.
    static func validate(_ url: URL) throws {
        try checkMimetypeRule(url)
        try checkIntegrity(try Archive(url: url, accessMode: .read))
        _ = try read(url)
    }

    /// One element directly inside `<metadata>`, as an ordinary XML parse sees it.
    struct Fact: Equatable {
        var name: String
        var attributes: [String: String]
        var text: String

        init(_ element: XMLElement) {
            name = element.name ?? ""
            attributes = Dictionary((element.attributes ?? []).map { ($0.name ?? "", $0.stringValue ?? "") }) { first, _ in first }
            text = element.stringValue ?? ""
        }
    }

    /// What a changed copy must still look like. Built from the original while it is edited.
    struct Expectation {
        /// The original followed the mimetype rule, so the copy must.
        var mimetypeRule: Bool
        /// Number of elements directly inside `<metadata>` after the edit.
        var childCount: Int
        /// Elements the edit did not mean to change: where each now sits, and what it held in
        /// the original file.
        var unchanged: [(index: Int, fact: Fact)]
        var hadTitle: Bool
        var hadLanguage: Bool
    }

    /// Checks a changed copy from scratch, with a plain parse that shares nothing with the
    /// document object the edit was made on: the archive is intact, the package parses, the
    /// required elements are still there, and every metadata element the edit did not mean to
    /// change has the same name, attributes and text as in the original.
    static func verify(_ copy: URL, against expected: Expectation) throws {
        if expected.mimetypeRule { try checkMimetypeRule(copy) }
        let archive = try Archive(url: copy, accessMode: .read)
        try checkIntegrity(archive)
        let package = try Package(archive: archive)
        let facts = package.plainFacts
        guard facts.count == expected.childCount else { throw EpubError.invalid("metadata has \(facts.count) elements, expected \(expected.childCount)") }
        for (index, fact) in expected.unchanged {
            guard facts[index] == fact else { throw EpubError.invalid("\(fact.name) changed although it was not edited") }
        }
        if expected.hadTitle, package.dcText("title") == nil { throw EpubError.invalid("dc:title was lost") }
        if expected.hadLanguage, package.dcText("language") == nil { throw EpubError.invalid("dc:language was lost") }
    }

    // MARK: OPF package document

    final class Package {
        let opfPath: String
        let document: XMLDocument
        let root: XMLElement
        let metadata: XMLElement
        let manifest: XMLElement
        /// The elements directly inside `<metadata>` as first parsed, and what each held.
        private let originalChildren: [XMLElement]
        private let originalState: [Fact]
        /// The same elements as an ordinary parse of the same bytes sees them: the reference
        /// that verification compares against.
        let plainFacts: [Fact]
        private let hadTitle: Bool
        private let hadLanguage: Bool
        var version: String { root.attribute(forName: "version")?.stringValue ?? "2.0" }
        var isEPUB3: Bool { version.hasPrefix("3") }

        init(archive: Archive) throws {
            let container = try XMLDocument(data: EpubIO.data("META-INF/container.xml", in: archive))
            guard let path = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue
            else { throw EpubError.missing("rootfile in container.xml") }
            opfPath = path
            let opfData = try EpubIO.data(path, in: archive)
            document = try XMLDocument(data: opfData, options: EpubIO.xmlOptions)
            guard let root = document.rootElement(), let metadata = root.child("metadata"), let manifest = root.child("manifest")
            else { throw EpubError.invalid("OPF has no metadata or manifest") }
            self.root = root; self.metadata = metadata; self.manifest = manifest

            guard let plainMetadata = try XMLDocument(data: opfData).rootElement()?.child("metadata")
            else { throw EpubError.invalid("OPF has no metadata") }
            plainFacts = plainMetadata.childElements.map(Fact.init)
            originalChildren = metadata.childElements
            originalState = originalChildren.map(Fact.init)
            guard plainFacts.count == originalChildren.count else { throw EpubError.invalid("OPF parses inconsistently") }
            let dcChildren = metadata.elements(forLocalName: "title", uri: EpubIO.dc) + metadata.elements(forLocalName: "language", uri: EpubIO.dc)
            func has(_ name: String) -> Bool {
                dcChildren.contains { $0.localName == name && !($0.stringValue ?? "").trimmed.isEmpty }
            }
            hadTitle = has("title")
            hadLanguage = has("language")
        }

        /// See `EpubIO.Expectation`. Call after `apply` and `setCover`, before serialising.
        func expectation(mimetypeRule: Bool) -> Expectation {
            let now = metadata.childElements
            var unchanged: [(index: Int, fact: Fact)] = []
            for (i, element) in originalChildren.enumerated() where Fact(element) == originalState[i] {
                if let index = now.firstIndex(where: { $0 === element }) { unchanged.append((index, plainFacts[i])) }
            }
            return Expectation(mimetypeRule: mimetypeRule, childCount: now.count, unchanged: unchanged,
                               hadTitle: hadTitle, hadLanguage: hadLanguage)
        }

        /// `<!DOCTYPE …>` as it stood in the file, rebuilt from its parts: XMLDocument keeps the
        /// DTD node apart from the document's children and does not write it back.
        var doctype: String? {
            guard let dtd = document.dtd, let name = dtd.name else { return nil }
            func quoted(_ s: String) -> String { s.contains("\"") ? "'\(s)'" : "\"\(s)\"" }
            if let publicID = dtd.publicID { return "<!DOCTYPE \(name) PUBLIC \(quoted(publicID)) \(quoted(dtd.systemID ?? ""))>" }
            if let systemID = dtd.systemID { return "<!DOCTYPE \(name) SYSTEM \(quoted(systemID))>" }
            return "<!DOCTYPE \(name)>"
        }
        /// Declarations inside the DOCTYPE cannot be rebuilt reliably, so such a file is not written.
        var hasInternalDTDSubset: Bool { (document.dtd?.childCount ?? 0) > 0 }

        /// XMLDocument.xmlData would add standalone="yes" to the declaration and drop the newline
        /// after it, so the declaration is written by hand and the top-level nodes (comments,
        /// processing instructions, the root element) are serialised one by one. A DOCTYPE goes
        /// straight after the declaration.
        func serialized() -> Data {
            let nodes = (document.children ?? []).map { $0.xmlString(options: EpubIO.xmlOptions) }
            let lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"] + (doctype.map { [$0] } ?? []) + nodes
            return Data(lines.joined(separator: "\n").utf8)
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
        /// The first top-level collection that is a series: its `collection-type` is "series" or
        /// not given. A "set" or any other kind of collection is not a series and is never edited.
        var collection: XMLElement? {
            metas.first { c in
                guard c.attr("property") == "belongs-to-collection", c.attr("refines") == nil else { return false }
                guard let id = c.attr("id") else { return true }
                let type = refinements(of: id, property: "collection-type").first?.stringValue?.trimmed.lowercased()
                return type == nil || type == "series"
            }
        }

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

        /// The archive entry an href in the OPF points at: percent-decoded, relative to the OPF's
        /// folder, with "." and ".." resolved. Nil when it would climb out of the archive, so
        /// the result never contains "..".
        func archivePath(forHref href: String) -> String? {
            let decoded = href.removingPercentEncoding ?? href
            var parts = (opfPath as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            for piece in decoded.split(separator: "/") {
                switch piece {
                case ".": continue
                case "..":
                    if parts.isEmpty { return nil }
                    parts.removeLast()
                default: parts.append(String(piece))
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "/")
        }

        func readCover(_ archive: Archive) throws -> CoverImage? {
            guard let item = coverItem, let href = item.attr("href"), let path = archivePath(forHref: href) else { return nil }
            guard archive[path] != nil else { return nil }
            return CoverImage(data: try EpubIO.data(path, in: archive), mime: item.attr("media-type") ?? "image/jpeg")
        }

        // Writing

        /// - Returns: Fields that were asked to change but were deliberately left as they are.
        func apply(_ m: EpubMetadata) -> Set<MetadataField> {
            var notWritten: Set<MetadataField> = []
            let old = readMetadata()
            // Required by the format: changed when a value is given, never removed.
            setDC("title", m.title, required: true)
            setDC("language", m.language, required: true)
            setDC("publisher", m.publisher)
            setDC("date", m.date)
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
                        e.setAttr(opfAttributePrefix + ":role", "aut", uri: EpubIO.opf)
                        append(e)
                    }
                }
            }
            if m.subjects != old.subjects {
                dcElements("subject").forEach(removeWithRefinements)
                m.subjects.forEach { append(makeDC("subject", $0)) }
            }
            let newISBN = m.isbn?.trimmed.nilIfEmpty
            if newISBN != old.isbn {
                // Never rewrite the package's unique identifier: readers key annotations (and font
                // obfuscation) on it. When it is the only ISBN, the ISBN is left as it is and
                // reported, rather than a second, conflicting identifier being added beside it.
                let uniqueID = root.attr("unique-identifier")
                if let e = isbnElement {
                    if let id = e.attr("id"), id == uniqueID {
                        notWritten.insert(.isbn)
                    } else if let isbn = newISBN {
                        e.stringValue = (e.stringValue ?? "").lowercased().hasPrefix("urn:isbn:") ? "urn:isbn:" + isbn : isbn
                    } else {
                        removeWithRefinements(e)
                    }
                } else if let isbn = newISBN {
                    if isEPUB3 { append(makeDC("identifier", "urn:isbn:" + isbn)) } else {
                        let e = makeDC("identifier", isbn)
                        e.setAttr(opfAttributePrefix + ":scheme", "ISBN", uri: EpubIO.opf)
                        append(e)
                    }
                }
            }
            if m.series != old.series || m.seriesNumber != old.seriesNumber {
                // calibre's pair is what calibre, Audiobookshelf, Kavita and KOReader read, in EPUB 2 and 3 alike.
                // No number means no index: an invented "1" would come back as the book's number.
                setNamedMeta("calibre:series", m.series)
                setNamedMeta("calibre:series_index", m.series == nil ? nil : m.seriesNumber)
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
            return notWritten
        }

        /// Replaces the cover image bytes. Keeps the existing manifest item, path and media type
        /// (converting the image if needed) so XHTML cover pages that point at it keep working.
        ///
        /// - Returns: False when the cover was left alone: the existing cover item points at a
        ///   file that is not in the archive, or the image cannot be converted to that item's
        ///   type. Nothing is created in either case.
        func setCover(_ image: CoverImage, in archive: Archive) throws -> Bool {
            if let item = coverItem {
                guard let href = item.attr("href"), let path = archivePath(forHref: href), archive[path] != nil else { return false }
                let wanted = item.attr("media-type") ?? image.mime
                guard let data = wanted == image.mime ? image.data : try? EpubIO.convert(image.data, toMIME: wanted) else { return false }
                try EpubIO.replace(path, with: data, in: archive)
            } else {
                let ext = image.mime == "image/png" ? "png" : "jpg"
                let href = "voxcarrel-cover." + ext
                guard let path = archivePath(forHref: href) else { return false }
                let siblingName = manifest.childElements.first { $0.localName == "item" }?.name
                let item = XMLElement(name: siblingName ?? qualified("item", in: manifest), uri: EpubIO.opf)
                item.setAttr("id", "voxcarrel-cover"); item.setAttr("href", href); item.setAttr("media-type", image.mime)
                if isEPUB3 { item.setAttr("properties", "cover-image") }
                append(item, to: manifest)
                setNamedMeta("cover", "voxcarrel-cover") // the EPUB 2 convention, also honoured by EPUB 3 readers
                try EpubIO.replace(path, with: image.data, in: archive)
            }
            return true
        }

        // DOM helpers

        /// A non-empty prefix bound to `uri` on `<metadata>` or an ancestor. The default
        /// namespace does not count: an attribute needs a real prefix.
        func boundPrefix(for uri: String) -> String? {
            var node: XMLNode? = metadata
            while let element = node as? XMLElement {
                if let name = element.namespaces?.first(where: { $0.stringValue == uri && !($0.name ?? "").isEmpty })?.name { return name }
                node = element.parent
            }
            return nil
        }
        /// The prefix for `uri`, declared on `<metadata>` as `fallback` if nothing binds one yet.
        func prefix(for uri: String, fallback: String) -> String {
            if let bound = boundPrefix(for: uri) { return bound }
            // As with attributes (see `setAttr`), a declaration detached from a parsed template
            // is written with double quotes like the rest of the file; a fresh one gets single quotes.
            let template = try! XMLDocument(xmlString: "<t xmlns:p=\"u\"/>", options: EpubIO.xmlOptions)
            if let declaration = template.rootElement()?.namespaces?.first {
                declaration.detach()
                declaration.name = fallback
                declaration.stringValue = uri
                metadata.addNamespace(declaration)
            } else {
                metadata.addNamespace(XMLNode.namespace(withName: fallback, stringValue: uri) as! XMLNode)
            }
            return fallback
        }
        var dcPrefix: String { prefix(for: EpubIO.dc, fallback: "dc") }
        /// For `opf:role` and `opf:scheme`. Most EPUB 2 packages have the OPF namespace only as
        /// their default namespace, which attributes do not inherit.
        var opfAttributePrefix: String { prefix(for: EpubIO.opf, fallback: "opf") }
        /// `local` spelt the way `parent` is: prefixed when the package document prefixes its
        /// own elements (`<opf:metadata>`), bare otherwise.
        func qualified(_ local: String, in parent: XMLElement) -> String {
            guard let prefix = parent.prefix, !prefix.isEmpty else { return local }
            return prefix + ":" + local
        }
        func makeDC(_ name: String, _ text: String) -> XMLElement {
            let e = XMLElement(name: dcPrefix + ":" + name, uri: EpubIO.dc)
            e.stringValue = text
            return e
        }
        func makeMeta(_ attributes: [String: String], text: String? = nil) -> XMLElement {
            // Same namespace and spelling as its siblings: an existing <meta>'s name, else <metadata>'s prefix.
            let e = XMLElement(name: metas.first?.name ?? qualified("meta", in: metadata), uri: EpubIO.opf)
            for (k, v) in attributes.sorted(by: { $0.key < $1.key }) { e.setAttr(k, v) }
            if let text { e.stringValue = text }
            return e
        }
        /// - Parameter required: The format requires the element, so an empty value leaves
        ///   whatever is there untouched instead of removing it.
        func setDC(_ name: String, _ value: String?, required: Bool = false) {
            let existing = dcElements(name)
            if let value, !value.isEmpty {
                if let first = existing.first { if first.stringValue != value { first.stringValue = value } }
                else { append(makeDC(name, value)) }
            } else if !required { existing.forEach(removeWithRefinements) }
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
        let template = try! XMLDocument(xmlString: "<t a=\"\"/>", options: EpubIO.xmlOptions)
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

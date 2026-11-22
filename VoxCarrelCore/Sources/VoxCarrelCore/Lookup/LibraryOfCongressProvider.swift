import Foundation

/// Looks sound recordings of books up in the Library of Congress catalogue: cassette and
/// disc editions, with who read them. No account, no cookies.
///
/// The catalogue is asked by the libraries' search protocol (SRU) and answers with
/// records in XML (MODS).
public struct LibraryOfCongressProvider: LookupProvider {
    public let source = LookupSource.libraryOfCongress
    private let http: any HTTPFetching
    private let limit: Int

    /// The catalogue's search service answers only here, without encryption: the one
    /// address in the app that is not `https`. What is searched for can be read on the way.
    static let origin = InsecureOrigin.libraryOfCongress
    static let path = "/lcdb"
    /// The most an answer may be.
    static let byteLimit = 5 * 1024 * 1024
    static let headers = ["User-Agent": LookupRequest.userAgent, "Accept": "application/xml"]

    /// `limit`: the most records asked for, from 1 to 100. Records of printed books are
    /// among them and are not used, so fewer results come back.
    public init(http: any HTTPFetching, limit: Int = 20) {
        self.http = http
        self.limit = min(max(limit, 1), 100)
    }

    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        guard let text = Self.searchText(for: query),
              let url = LookupRequest.url(insecure: Self.origin, path: Self.path, query: [
                  ("version", "1.1"), ("operation", "searchRetrieve"), ("maximumRecords", String(limit)),
                  ("recordSchema", "mods"), ("query", text),
              ])
        else { return [] }
        // No redirect is followed: one anywhere fails the search as refused.
        let answer = try await http.get(
            url, headers: Self.headers, maxBytes: Self.byteLimit, redirectHosts: [], insecure: [Self.origin])
        guard answer.status == 200 else { throw LookupError.refused(status: answer.status) }
        guard answer.data.count <= Self.byteLimit else { throw LookupError.unreadable }
        let records = try MODSReader.records(in: answer.data)
        return Array(records.lazy.compactMap(candidate).prefix(limit))
    }

    // MARK: The question

    /// What the catalogue is asked: the title and the first author's surname, or an ISBN
    /// when there is no title. Nil when there is neither.
    static func searchText(for query: LookupQuery) -> String? {
        // The title as it is, leading article and all: the catalogue finds it either way.
        if let title = value(query.title) {
            var text = "bath.title=\"\(title)\""
            if let surname = surname(of: query.author) { text += " and bath.author=\"\(surname)\"" }
            return text
        }
        if let isbn = query.isbn.flatMap(LookupText.isbn) { return "bath.isbn=\(isbn)" }
        return nil
    }

    /// Made safe inside the quotes of a search: no quotes and no backslashes, on one line.
    private static func value(_ raw: String) -> String? {
        LookupText.cleaned(
            raw.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: ""),
            limit: LookupText.nameLimit)
    }

    /// The last word of the name, in lower case and without accents: "John le Carré" ->
    /// "carre". Only part of a surname of several words, which the catalogue still finds
    /// by that word.
    private static func surname(of author: String) -> String? {
        guard let name = value(LookupText.personName(fromCatalogue: value(author) ?? "")) else { return nil }
        let words = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased().split(separator: " ").map(String.init)
        let word = words.last { !LookupText.isNameSuffix($0) } ?? words.last
        return word?.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")).nonBlank
    }

    // MARK: A record

    /// Nil for a record that is not a sound recording of words, or has no title or no
    /// identifier of its own.
    private func candidate(from record: MODSReader.Record) -> LookupCandidate? {
        let kind = record.typeOfResource.lookupTrimmed.lowercased()
        guard kind.hasPrefix("sound recording"), !kind.contains("-musical"),
              let id = LookupText.cleaned(record.identifier, limit: LookupText.lineLimit),
              let titleInfo = record.titles.first(where: { $0.type == nil }),
              let title = Self.title(titleInfo)
        else { return nil }

        var metadata = BookMetadata(title: title)
        metadata.subtitle = Self.withoutFinalMarks(LookupText.cleaned(titleInfo.subtitle, limit: LookupText.nameLimit))

        var authors: [String] = []
        var readers: [String] = []
        var unsaid: [String] = []
        for name in record.names.filter(\.isPerson) {
            guard let said = Self.person(name) else { continue }
            if name.isAuthor {
                authors.append(said)
            } else if name.isNarrator {
                readers.append(said)
            } else if name.hasNoRole {
                unsaid.append(said)
            }
        }
        metadata.authors = Self.people(authors)
        // Who reads it: the people the record calls its readers; failing that, the ones
        // its performers note names; and with neither, the one other person it names
        // without saying what they did. Two such people are as likely a second author
        // and an editor as readers, and are not taken.
        let performerNotes = record.notes.filter { $0.type?.lowercased() == "performers" }
        let others = Self.people(unsaid)
        if !readers.isEmpty {
            metadata.narrators = Self.people(readers)
        } else if !performerNotes.isEmpty {
            metadata.narrators = performerNotes.lazy
                .compactMap { Self.narrators(fromNote: $0.text, authors: metadata.authors) }.first ?? []
        } else if others.count == 1 {
            metadata.narrators = others
        }

        let dates = record.dates.filter { $0.type?.lowercased() == "marc" } + record.dates.filter { $0.type?.lowercased() != "marc" }
        metadata.year = dates.lazy.compactMap { Self.year($0.text) }.first
        metadata.publisher = (record.agents + record.publishers).lazy
            .compactMap { Self.withoutFinalMarks(LookupText.cleaned($0, limit: LookupText.lineLimit)) }.first
        metadata.language = record.languages.lazy.compactMap(LookupText.languageCode).first
        metadata.durationSeconds = record.extents.lazy.compactMap(LookupText.seconds(fromExtent:)).first
        let isbns = record.identifiers.filter { $0.type?.lowercased() == "isbn" }.compactMap { Self.isbn($0.text) }
        metadata.isbn = isbns.first { $0.count == 13 } ?? isbns.first

        let format = Self.format(forms: record.forms, extents: record.extents)
        let abridged = Self.abridged(record.editions) ?? Self.abridged(record.notes.map(\.text))

        var note = [source.title, format.label]
        if let abridged { note.append(abridged ? "Abridged" : "Unabridged") }
        if let seconds = metadata.durationSeconds { note.append(LookupText.lengthLabel(minutes: Int((seconds / 60).rounded()))) }
        if let year = metadata.year { note.append(String(year)) }

        // The cataloguers' notes are for telling editions apart, never a description.
        return LookupCandidate(
            id: "\(source.rawValue):\(id)",
            source: source,
            metadata: metadata,
            note: note.joined(separator: " · "),
            hasMoreDetails: false,
            // A catalogue's length is a round figure: "18 hr.".
            edition: EditionFacts(
                format: format, abridged: abridged, publisher: metadata.publisher, year: metadata.year,
                lengthIsNominal: metadata.durationSeconds != nil)
        )
    }

    /// The title with the article the catalogue files it without: "A" + "perfect spy".
    private static func title(_ info: MODSReader.Title) -> String? {
        guard let title = withoutFinalMarks(LookupText.cleaned(info.title, limit: LookupText.nameLimit)) else { return nil }
        guard let article = LookupText.cleaned(info.nonSort, limit: LookupText.lineLimit) else { return title }
        let joined = article.hasSuffix("'") || article.hasSuffix("’") || article.hasSuffix("-")
        return LookupText.cleaned(joined ? article + title : "\(article) \(title)", limit: LookupText.nameLimit)
    }

    /// Without the marks a catalogue puts between the parts of a description: " /", " :", ",".
    private static func withoutFinalMarks(_ text: String?) -> String? {
        text?.trimmingCharacters(in: CharacterSet(charactersIn: " /:;,=")).nonBlank
    }

    private static func person(_ name: MODSReader.Name) -> String? {
        let plain = name.parts.filter { $0.type == nil }.map(\.text)
        let given = name.parts.filter { $0.type?.lowercased() == "given" }.map(\.text)
        let family = name.parts.filter { $0.type?.lowercased() == "family" }.map(\.text)
        let raw = plain.isEmpty ? (given + family).joined(separator: " ") : plain.joined(separator: " ")
        return LookupText.personName(fromCatalogue: raw).nonBlank
    }

    /// Cleaned, each person once, at most fifty.
    private static func people(_ names: [String]) -> [String] {
        var kept: [String] = []
        for name in LookupText.cleanedNames(names) where !kept.contains(where: { LookupText.samePerson($0, name) }) {
            kept.append(name)
        }
        return kept
    }

    private static let performerOpenings = [
        "narrated by ", "read by ", "performed by ", "narrator: ", "narrators: ", "reader: ", "readers: ",
        "performer: ", "performers: ",
    ]

    /// Who a performers note names: "Narrated by X.", "Read by X and Y.", "Readers: X, Y.".
    /// Nil when it is not in one of those forms or names nobody.
    static func narrators(fromNote note: String, authors: [String]) -> [String]? {
        guard let text = LookupText.cleaned(note, limit: LookupText.nameLimit) else { return nil }
        let lowered = text.lowercased()
        guard let opening = performerOpenings.first(where: { lowered.hasPrefix($0) }) else { return nil }
        var parts = [String(text.dropFirst(opening.count))]
        for separator in [" and ", "; ", ", ", " & "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var names: [String] = []
        for part in parts {
            let name = LookupText.personName(fromCatalogue: part)
            if ["the author", "the authors"].contains(name.lowercased()) {
                names += authors
                continue
            }
            // A name, not the rest of a sentence.
            guard !name.isEmpty, name.split(separator: " ").count <= 5, !name.contains(where: \.isNumber) else { continue }
            names.append(name)
        }
        let kept = people(names)
        return kept.isEmpty ? nil : kept
    }

    /// The first four digits standing alone: "p1987" -> 1987, "[1994?]" -> 1994.
    private static func year(_ text: String) -> Int? {
        guard let digits = LookupText.firstMatch("(?<![0-9])[0-9]{4}(?![0-9])", in: String(text.prefix(100)))?.first else { return nil }
        return LookupText.year(Int(digits))
    }

    /// "034038784X :", "0399139540 (alk. paper) :" -> the ISBN at the start.
    private static func isbn(_ text: String) -> String? {
        let start = text.lookupTrimmed.prefix { $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "x" || $0 == "X") }
        return LookupText.isbn(String(start))
    }

    private static func format(forms: [String], extents: [String]) -> EditionFormat {
        let said = (forms + extents).map { $0.lowercased() }
        if said.contains(where: { $0.contains("cassette") }) { return .cassette }
        guard said.contains(where: { $0.contains("sound disc") || $0.contains("compact disc") || $0.contains("audio disc") }) else {
            return .other
        }
        if said.contains(where: { $0.contains("mp3") }) { return .mp3CD }
        // A disc that turns at a speed is a record, not a compact disc.
        if said.contains(where: { $0.contains("rpm") }) { return .other }
        return .cd
    }

    /// False for a text that says "unabridged", true for one that says "abridged"; nil when none does.
    private static func abridged(_ texts: [String]) -> Bool? {
        let said = texts.map { $0.lowercased() }
        if said.contains(where: { $0.contains("unabridged") }) { return false }
        if said.contains(where: { $0.contains("abridged") }) { return true }
        return nil
    }
}

/// Reads the records out of a catalogue's answer, as events, keeping only the few values
/// a lookup uses and only so much of each. Nothing outside the answer is ever read: an
/// answer that declares a document type or entities is refused whole.
final class MODSReader: NSObject, XMLParserDelegate {
    struct Title {
        var type: String?
        var nonSort: String?
        var title: String?
        var subtitle: String?
    }

    struct Name {
        var type: String?
        var usage: String?
        var parts: [(type: String?, text: String)] = []
        var roles: [String] = []

        var isPerson: Bool { type == nil || type?.lowercased() == "personal" }

        private var saidRoles: [String] {
            roles.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,;")) }.filter { !$0.isEmpty }
        }

        var isAuthor: Bool {
            usage?.lowercased() == "primary" || saidRoles.contains { ["author", "aut", "creator", "cre"].contains($0) }
        }

        /// Said to be a reader.
        var isNarrator: Bool {
            saidRoles.contains { ["narrator", "nrt", "reader", "performer", "prf", "speaker", "spk"].contains($0) }
        }

        /// No part in the work is stated.
        var hasNoRole: Bool {
            saidRoles.isEmpty
        }
    }

    struct Typed {
        var type: String?
        var text: String
    }

    struct Record {
        var titles: [Title] = []
        var names: [Name] = []
        var typeOfResource = ""
        var dates: [Typed] = []
        var agents: [String] = []
        var publishers: [String] = []
        var editions: [String] = []
        var languages: [String] = []
        var forms: [String] = []
        var extents: [String] = []
        var notes: [Typed] = []
        var identifiers: [Typed] = []
        var identifier: String?
    }

    /// The most kept of one value, of one kind of value in a record, and of records; and
    /// the deepest an answer may nest.
    static let textLimit = 4_000
    static let valueLimit = 50
    static let recordLimit = 200
    static let depthLimit = 64

    private var path: [String] = []
    /// How deep the record being read began; nil outside a record.
    private var recordDepth: Int?
    private var record = Record()
    private var records: [Record] = []
    private var text = ""
    private var textCount = 0
    private var attributes: [String: String] = [:]
    private var isAnswer = false
    private var refused = false
    private var ended = false

    /// The records of an answer. Throws `.unreadable` for anything that is not a whole,
    /// well-formed answer to a search in UTF-8 with no document type.
    static func records(in data: Data) throws -> [Record] {
        guard isPlain(data) else { throw LookupError.unreadable }
        return try parsed(data)
    }

    /// The same without the first look at the text: the reading itself also stops at
    /// the first entity declared.
    static func parsed(_ data: Data) throws -> [Record] {
        let reader = MODSReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        // Read to its end with everything closed: the parser can stop early without saying so.
        guard parser.parse(), !reader.refused, reader.isAnswer, reader.ended, reader.path.isEmpty else {
            throw LookupError.unreadable
        }
        return reader.records
    }

    /// True for UTF-8 text that begins as XML and declares no document type and no
    /// entities: there is then nothing to expand and nothing to fetch.
    static func isPlain(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let start = text.unicodeScalars.drop { $0 == "\u{FEFF}" || $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        guard start.first == "<", !text.unicodeScalars.contains("\0") else { return false }
        // Read as the encoding it says it is: only UTF-8 will do. The whole of the
        // declaration is looked at, however long; one with no end is not XML.
        let opening = String(String.UnicodeScalarView(start.prefix(5)))
        if opening == "<?xml" {
            let rest = String(String.UnicodeScalarView(start))
            guard let end = rest.range(of: "?>") else { return false }
            let declaration = String(rest[..<end.lowerBound])
            if let named = LookupText.firstMatch("encoding\\s*=\\s*[\"']([^\"']*)[\"']", in: declaration),
               named[1].lowercased() != "utf-8" {
                return false
            }
            // Said, but not in a way that can be read: not taken on trust.
            if declaration.lowercased().contains("encoding"),
               LookupText.firstMatch("encoding\\s*=\\s*[\"']([^\"']*)[\"']", in: declaration) == nil {
                return false
            }
        }
        return text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil
            && text.range(of: "<!ENTITY", options: .caseInsensitive) == nil
    }

    private func refuse(_ parser: XMLParser) {
        refused = true
        parser.abortParsing()
    }

    // MARK: Events

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        path.append(name)
        guard path.count <= Self.depthLimit else { return refuse(parser) }
        if path.count == 1 { isAnswer = name == "searchRetrieveResponse" }
        text = ""
        textCount = 0
        attributes = attributeDict

        guard let recordDepth else {
            if name == "mods", path.dropLast().last == "recordData" {
                self.recordDepth = path.count
                record = Record()
            } else if name == "diagnostics" {
                // The catalogue's own report of an error.
                refuse(parser)
            }
            return
        }
        // The values that open a group of their own: the record's own children.
        guard path.count == recordDepth + 1 else { return }
        if name == "titleInfo", record.titles.count < Self.valueLimit {
            record.titles.append(Title(type: attributeDict["type"]))
        } else if name == "name", record.names.count < Self.valueLimit {
            record.names.append(Name(type: attributeDict["type"], usage: attributeDict["usage"]))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard recordDepth != nil, textCount < Self.textLimit else { return }
        let piece = string.prefix(Self.textLimit - textCount)
        text += piece
        textCount += piece.count
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
            textCount = 0
        }
        guard let recordDepth else { return }
        guard path.count > recordDepth else {
            // The record's own end.
            if records.count < Self.recordLimit { records.append(record) }
            self.recordDepth = nil
            return
        }
        let type = attributes["type"]
        func add(_ value: String, to list: inout [String]) {
            if list.count < Self.valueLimit { list.append(value) }
        }
        func add(_ value: Typed, to list: inout [Typed]) {
            if list.count < Self.valueLimit { list.append(value) }
        }
        // Where this is within the record: at most three deep is ever of use. Looked at
        // in place: an answer may hold a million elements.
        let depth = path.count - recordDepth
        guard depth <= 3 else { return }
        let place = (
            path[recordDepth], depth >= 2 ? path[recordDepth + 1] : "", depth == 3 ? path[recordDepth + 2] : "")
        switch place {
        case ("titleInfo", "nonSort", ""): setTitle(\.nonSort)
        case ("titleInfo", "title", ""): setTitle(\.title)
        case ("titleInfo", "subTitle", ""): setTitle(\.subtitle)
        case ("name", "namePart", ""):
            if let last = record.names.indices.last, record.names[last].parts.count < Self.valueLimit {
                record.names[last].parts.append((type, text))
            }
        case ("name", "role", "roleTerm"):
            if let last = record.names.indices.last, record.names[last].roles.count < Self.valueLimit {
                record.names[last].roles.append(text)
            }
        case ("typeOfResource", "", ""): if record.typeOfResource.isEmpty { record.typeOfResource = text }
        case ("originInfo", "dateIssued", ""): add(Typed(type: attributes["encoding"], text: text), to: &record.dates)
        case ("originInfo", "agent", "namePart"): add(text, to: &record.agents)
        case ("originInfo", "publisher", ""): add(text, to: &record.publishers)
        case ("originInfo", "edition", ""): add(text, to: &record.editions)
        case ("language", "languageTerm", ""): add(text, to: &record.languages)
        case ("physicalDescription", "form", ""): add(text, to: &record.forms)
        case ("physicalDescription", "extent", ""): add(text, to: &record.extents)
        case ("note", "", ""): add(Typed(type: type, text: text), to: &record.notes)
        case ("identifier", "", ""):
            if attributes["invalid"]?.lowercased() != "yes" { add(Typed(type: type, text: text), to: &record.identifiers) }
        case ("recordInfo", "recordIdentifier", ""): if record.identifier == nil { record.identifier = text }
        default: break
        }
    }

    /// Sets a part of the title being read, the first time it is given.
    private func setTitle(_ part: WritableKeyPath<Title, String?>) {
        guard let last = record.titles.indices.last, record.titles[last][keyPath: part] == nil else { return }
        record.titles[last][keyPath: part] = text
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        ended = true
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        refused = true
    }

    // An answer never declares entities; one that does is not read further.

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        refuse(parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        refuse(parser)
    }

    func parser(
        _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
        notationName: String?
    ) {
        refuse(parser)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        refuse(parser)
        return Data()
    }
}

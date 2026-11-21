import CTagBridge
import Foundation

/// Reads and writes audiobook tags. Formats handled: m4b, m4a, mp3.
enum AudioTagIO {
    enum Container { case mp4, mp3 }

    static func container(for url: URL) throws -> Container {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m4b", "m4a": return .mp4
        case "mp3": return .mp3
        default: throw MetadataIOError.unsupportedFormat(ext)
        }
    }

    // MARK: Read

    static func read(_ url: URL) throws -> FileContents {
        let kind = try container(for: url)
        let snap: CTBSnapshot
        do {
            snap = kind == .mp4 ? try CTBTagFile.readMP4(atPath: url.path) : try CTBTagFile.readMP3(atPath: url.path)
        } catch {
            throw MetadataIOError.unreadable(url.lastPathComponent)
        }
        let raw = snap.items
        func first(_ keys: String...) -> String? {
            for key in keys {
                if let v = raw[key]?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            }
            return nil
        }
        var t = BookMetadata()
        let free = "----:com.apple.iTunes:"
        switch kind {
        case .mp4:
            // Album before track title, so one part of a multi-part book reports the book's title.
            t.title = first("©alb", "©nam") ?? ""
            t.subtitle = first("©st3", free + "SUBTITLE")
            t.authors = NameList.split(first("aART", "©ART"))
            t.narrators = NameList.split(first("©nrt", "©wrt"))
            t.series = first(free + "SERIES", "©mvn")
            t.seriesNumber = first(free + "SERIES-PART", "©mvi")
            t.genre = first("©gen")
            t.year = first("©day").flatMap(leadingYear)
            t.publisher = first("©pub", free + "PUBLISHER")
            t.summary = first("ldes", "desc", "©cmt")
            t.language = first(free + "LANGUAGE")
            t.isbn = first(free + "ISBN")
            t.asin = first(free + "ASIN")
            if t.series == nil, let g = first("©grp") { (t.series, t.seriesNumber) = parseGrouping(g) }
        case .mp3:
            t.title = first("TALB", "TIT2") ?? ""
            t.subtitle = first("TIT3")
            t.authors = NameList.split(first("TPE2", "TPE1"))
            t.narrators = NameList.split(first("TCOM", "TXXX:NARRATOR"))
            t.series = first("TXXX:SERIES", "MVNM")
            t.seriesNumber = first("TXXX:SERIES-PART", "MVIN")
            t.genre = first("TCON")
            t.year = first("TDRC", "TYER").flatMap(leadingYear)
            t.publisher = first("TPUB")
            t.summary = first("TXXX:DESCRIPTION", "COMM")
            t.language = first("TLAN")
            t.isbn = first("TXXX:ISBN")
            t.asin = first("TXXX:ASIN")
            if t.series == nil, let g = first("GRP1", "TIT1") { (t.series, t.seriesNumber) = parseGrouping(g) }
        }
        if snap.durationSeconds > 0 { t.durationSeconds = snap.durationSeconds }
        let cover = snap.coverData.map { CoverImage(data: $0, mime: snap.coverMIME ?? "image/jpeg") }
        return FileContents(
            metadata: t, cover: cover,
            chapters: snap.chapters.map { Chapter(start: $0.startSeconds, title: $0.title) })
    }

    // MARK: Write

    /// Safe write (copy, change, verify, swap). Returns an empty report: audio formats hold every field.
    @discardableResult
    static func write(_ metadata: BookMetadata, cover: CoverChange, part: PartPosition?, to url: URL) throws -> WriteReport {
        let name = url.lastPathComponent
        let before = try read(url)
        try SafeFileUpdate.update(url) { copy in
            do {
                try writeInPlace(metadata, cover: cover, part: part, to: copy)
            } catch let error as NSError where error.domain == CTBErrorDomain {
                throw error.code == 2 ? MetadataIOError.locked(name) : MetadataIOError.unreadable(name)
            }
        } verify: { copy in
            let after = try read(copy)
            guard abs((after.metadata.durationSeconds ?? 0) - (before.metadata.durationSeconds ?? 0)) < 0.05,
                  after.chapters == before.chapters else {
                throw MetadataIOError.verificationFailed("duration or chapters changed")
            }
        }
        return WriteReport()
    }

    /// The raw TagLib write. Modifies `url` in place.
    static func writeInPlace(_ metadata: BookMetadata, cover: CoverChange, part: PartPosition?, to url: URL) throws {
        let changes = CTBChanges()
        var set: [String: [String]] = [:]
        // Nil and empty both remove the tag.
        func put(_ key: String, _ value: String?) { set[key] = value.map { $0.isEmpty ? [] : [$0] } ?? [] }
        let authors = NameList.join(metadata.authors)
        let narrators = NameList.join(metadata.narrators)
        let wholeNumber = metadata.seriesNumber.flatMap { Int($0) }.map(String.init)
        let grouping = metadata.series.map { s in metadata.seriesNumber.map { "\(s) #\($0)" } ?? s }
        let track = part.map { "\($0.index)/\($0.count)" }
        let kind = try container(for: url)
        switch kind {
        case .mp4:
            let free = "----:com.apple.iTunes:"
            // In a multi-part book the track title is the part's own name: leave it alone.
            if let track { put("trkn", track) } else { put("©nam", metadata.title) }
            put("©alb", metadata.title)
            put("©st3", metadata.subtitle)
            put("©ART", authors); put("aART", authors)
            put("©nrt", narrators); put("©wrt", narrators)
            put(free + "SERIES", metadata.series); put(free + "SERIES-PART", metadata.seriesNumber)
            put("©mvn", metadata.series); put("©mvi", wholeNumber) // ©mvi is an integer atom
            put("©grp", grouping)
            put("©gen", metadata.genre)
            put("©day", metadata.year.map(String.init))
            put("©pub", metadata.publisher); put(free + "PUBLISHER", metadata.publisher)
            put("desc", metadata.summary); put("ldes", metadata.summary); put("©cmt", metadata.summary)
            put(free + "LANGUAGE", metadata.language)
            put(free + "ISBN", metadata.isbn)
            put(free + "ASIN", metadata.asin)
            set["stik"] = ["2"] // media kind: Audiobook
        case .mp3:
            if let track { put("TRCK", track) } else { put("TIT2", metadata.title) }
            put("TALB", metadata.title)
            put("TIT3", metadata.subtitle)
            put("TPE1", authors); put("TPE2", authors)
            put("TCOM", narrators)
            put("TXXX:SERIES", metadata.series); put("TXXX:SERIES-PART", metadata.seriesNumber)
            put("MVNM", metadata.series); put("MVIN", wholeNumber)
            put("GRP1", grouping)
            put("TCON", metadata.genre)
            put("TDRC", metadata.year.map(String.init))
            put("TPUB", metadata.publisher)
            put("COMM", metadata.summary); put("TXXX:DESCRIPTION", metadata.summary)
            put("TLAN", metadata.language)
            put("TXXX:ISBN", metadata.isbn)
            put("TXXX:ASIN", metadata.asin)
        }
        changes.setItems = set
        switch cover {
        case .keep: changes.replaceCover = false
        case .remove: changes.replaceCover = true
        case .set(let image):
            changes.replaceCover = true
            changes.coverData = image.data
            changes.coverMIME = image.mime
        }
        switch kind {
        case .mp4: try CTBTagFile.writeMP4(atPath: url.path, changes: changes)
        case .mp3: try CTBTagFile.writeMP3(atPath: url.path, changes: changes)
        }
    }

    // MARK: Helpers

    static func leadingYear(_ s: String) -> Int? {
        let digits = s.prefix(4)
        return digits.count == 4 ? Int(digits) : nil
    }

    /// "Series Name #2" -> ("Series Name", "2"); used only when no dedicated series tag exists.
    static func parseGrouping(_ g: String) -> (String?, String?) {
        let firstSeries = g.split(separator: ";").first.map(String.init) ?? g
        guard let hash = firstSeries.range(of: "#", options: .backwards) else {
            return (firstSeries.trimmingCharacters(in: .whitespaces), nil)
        }
        let name = firstSeries[..<hash.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        let number = firstSeries[hash.upperBound...].trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? nil : name, number.isEmpty ? nil : number)
    }
}

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

    // MARK: Raw tags

    /// The raw atoms or frames of one file, with the lookups the mapping below needs.
    struct RawTags {
        let kind: Container
        let snapshot: CTBSnapshot
        private let items: [String: [String]]

        init(_ url: URL) throws {
            kind = try AudioTagIO.container(for: url)
            do {
                snapshot = kind == .mp4 ? try CTBTagFile.readMP4(atPath: url.path) : try CTBTagFile.readMP3(atPath: url.path)
            } catch {
                throw MetadataIOError.unreadable(url.lastPathComponent)
            }
            // TagLib's MPEG reader accepts any file it can open. A file with no audio stream it
            // can measure is not an audiobook, whatever its name says, and must never be tagged.
            guard snapshot.durationSeconds > 0 else { throw MetadataIOError.unreadable(url.lastPathComponent) }
            var items = snapshot.items
            // ID3 user text frames are found whatever the case of their description: other
            // apps write "series", "Series" and "SERIES" alike. An exact upper-case one wins.
            for key in snapshot.items.keys.sorted() where key.hasPrefix("TXXX:") {
                let folded = key.uppercased()
                if items[folded] == nil { items[folded] = snapshot.items[key] }
            }
            self.items = items
        }

        /// Every non-blank value of the first of `keys` that has any.
        func values(_ keys: String...) -> [String] {
            for key in keys {
                let found = (items[key] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !found.isEmpty { return found }
            }
            return []
        }

        func first(_ keys: String...) -> String? {
            for key in keys {
                if let value = values(key).first { return value }
            }
            return nil
        }

        /// Several people may be spread over several values, and each value may itself be a list.
        func names(_ keys: String...) -> [String] {
            for key in keys {
                let found = values(key).flatMap { NameList.split($0) }
                if !found.isEmpty { return found }
            }
            return []
        }

        var dateKey: String { kind == .mp4 ? "©day" : "TDRC" } // TagLib presents a v2.3 TYER as TDRC
        var commentKey: String { kind == .mp4 ? "©cmt" : "COMM" }
        /// The description proper, not counting the comment `read` falls back to.
        var description: String? { kind == .mp4 ? first("ldes", "desc") : first("TXXX:DESCRIPTION") }
    }

    // MARK: Read

    /// - Throws: `MetadataIOError.unreadable` when the file cannot be parsed or has no audio
    ///   with a duration, so a mis-named or non-audio file is never reported as an empty book.
    static func read(_ url: URL) throws -> FileContents {
        let raw = try RawTags(url)
        let snap = raw.snapshot
        var t = BookMetadata()
        let free = "----:com.apple.iTunes:"
        let grouping: String?
        switch raw.kind {
        case .mp4:
            // Album before track title, so one part of a multi-part book reports the book's title.
            t.title = raw.first("©alb", "©nam") ?? ""
            t.subtitle = raw.first("©st3", free + "SUBTITLE")
            t.authors = raw.names("aART", "©ART")
            t.narrators = raw.names("©nrt", "©wrt")
            t.series = raw.first(free + "SERIES", "©mvn")
            t.seriesNumber = raw.first(free + "SERIES-PART", "©mvi")
            t.genre = NameList.join(raw.values("©gen"))
            t.year = raw.first("©day").flatMap(leadingYear)
            t.publisher = raw.first("©pub", free + "PUBLISHER")
            t.summary = raw.first("ldes", "desc", "©cmt")
            t.language = raw.first(free + "LANGUAGE")
            t.isbn = raw.first(free + "ISBN")
            t.asin = raw.first(free + "ASIN")
            grouping = raw.first("©grp")
        case .mp3:
            t.title = raw.first("TALB", "TIT2") ?? ""
            t.subtitle = raw.first("TIT3")
            t.authors = raw.names("TPE2", "TPE1")
            t.narrators = raw.names("TCOM", "TXXX:NARRATOR")
            t.series = raw.first("TXXX:SERIES", "MVNM")
            t.seriesNumber = raw.first("TXXX:SERIES-PART", "MVIN")
            t.genre = NameList.join(raw.values("TCON"))
            t.year = raw.first("TDRC", "TYER").flatMap(leadingYear)
            t.publisher = raw.first("TPUB")
            t.summary = raw.first("TXXX:DESCRIPTION", "COMM")
            t.language = raw.first("TLAN")
            t.isbn = raw.first("TXXX:ISBN")
            t.asin = raw.first("TXXX:ASIN")
            grouping = raw.first("GRP1", "TIT1")
        }
        // Grouping is a series only in the "Name #N" form; a bare grouping ("Fiction") is not.
        if t.series == nil, let grouping, grouping.contains("#") {
            (t.series, t.seriesNumber) = parseGrouping(grouping)
        }
        t.durationSeconds = snap.durationSeconds
        return FileContents(
            metadata: t, cover: snap.coverData.map(CoverImage.stored),
            chapters: snap.chapters.map { Chapter(start: $0.startSeconds, title: $0.title) })
    }

    // MARK: Write

    /// Safe write (copy, change, verify, swap). Returns an empty report: audio formats hold every field.
    ///
    /// Not everything is rewritten on every write:
    /// - the date tag is left alone while its year equals `metadata.year`, so a full date survives;
    /// - the comment is kept in step with the description only while it is absent or a copy of
    ///   it; a comment that says something else is the user's and is left alone;
    /// - only the cover picture is replaced or removed, never an MP3's other pictures.
    ///
    /// - Throws: `MetadataIOError.unreadable` for a file with no measurable audio, before
    ///   anything is copied.
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
            let after: FileContents
            do {
                after = try read(copy)
            } catch {
                throw MetadataIOError.verificationFailed("the changed copy no longer reads as audio")
            }
            guard let was = before.metadata.durationSeconds, let now = after.metadata.durationSeconds,
                  was > 0, now > 0, abs(now - was) < 0.05, after.chapters == before.chapters
            else { throw MetadataIOError.verificationFailed("duration or chapters changed") }
        }
        return WriteReport()
    }

    /// The raw TagLib write. Modifies `url` in place.
    static func writeInPlace(_ metadata: BookMetadata, cover: CoverChange, part: PartPosition?, to url: URL) throws {
        let existing = try RawTags(url)
        let changes = CTBChanges()
        var set: [String: [String]] = [:]
        // Nil and empty both remove the tag.
        func put(_ key: String, _ value: String?) { set[key] = value.map { $0.isEmpty ? [] : [$0] } ?? [] }
        let authors = NameList.join(metadata.authors)
        let narrators = NameList.join(metadata.narrators)
        let wholeNumber = metadata.seriesNumber.flatMap { Int($0) }.map(String.init)
        let grouping = metadata.series.map { s in metadata.seriesNumber.map { "\(s) #\($0)" } ?? s }
        let track = part.map { "\($0.index)/\($0.count)" }
        switch existing.kind {
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
            put("©pub", metadata.publisher); put(free + "PUBLISHER", metadata.publisher)
            put("desc", metadata.summary); put("ldes", metadata.summary)
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
            put("TPUB", metadata.publisher)
            put("TXXX:DESCRIPTION", metadata.summary)
            put("TLAN", metadata.language)
            put("TXXX:ISBN", metadata.isbn)
            put("TXXX:ASIN", metadata.asin)
        }
        // A date with the right year may be a full date ("2019-03-01"): keep it.
        if let year = metadata.year {
            if existing.first(existing.dateKey).flatMap(leadingYear) != year { put(existing.dateKey, String(year)) }
        } else {
            put(existing.dateKey, nil)
        }
        // The comment mirrors the description for apps that read only the comment. A comment
        // that already says something else is the user's own note.
        let comment = existing.first(existing.commentKey)
        if comment == nil || comment == existing.description { put(existing.commentKey, metadata.summary) }

        changes.setItems = set
        switch cover {
        case .keep: changes.replaceCover = false
        case .remove: changes.replaceCover = true
        case .set(let image):
            changes.replaceCover = true
            changes.coverData = image.data
            // Label the picture as what it is, so other apps are not misled by a wrong `mime`.
            changes.coverMIME = CoverImage.sniffedMIME(image.data) ?? image.mime
        }
        switch existing.kind {
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

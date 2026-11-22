import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A cover image as stored in or destined for a file.
public struct CoverImage: Equatable, Sendable {
    public var data: Data
    /// Normally "image/jpeg" or "image/png". A cover read from a file reports what its bytes
    /// are, whatever the file's own label says: another image type such as "image/gif" when
    /// that is what is stored, or "application/octet-stream" when the bytes are no image
    /// ImageIO recognises.
    public var mime: String

    public init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
    }

    /// The MIME type of image `data`, judged from its bytes. Nil when it is not a recognised image.
    public static func sniffedMIME(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?
        else { return nil }
        return UTType(identifier)?.preferredMIMEType
    }

    /// A cover as read out of a file, typed by its bytes.
    static func stored(_ data: Data) -> CoverImage {
        CoverImage(data: data, mime: sniffedMIME(data) ?? "application/octet-stream")
    }
}

/// What a write should do with the cover.
public enum CoverChange: Equatable, Sendable {
    case keep
    case remove
    case set(CoverImage)
}

/// One chapter marker of an audiobook. Read-only.
public struct Chapter: Equatable, Sendable {
    public var start: Double
    public var title: String

    public init(start: Double, title: String) {
        self.start = start
        self.title = title
    }
}

/// The editable fields, used to report what a format could not store.
public enum MetadataField: String, CaseIterable, Codable, Sendable {
    case title, subtitle, authors, narrators, series, seriesNumber, genre, year
    case publisher, summary, language, isbn, asin, cover
}

/// An MP3 whose length header (the Xing, Info or VBRI header in its first frame) states a
/// length the audio does not have. The audio itself is whole; players that trust the
/// header show the wrong length and may stop early.
public struct LengthProblem: Codable, Equatable, Sendable {
    /// The length the file states, as the tag library reads it.
    public var statedSeconds: Double
    /// The length of the audio, measured frame by frame.
    public var trueSeconds: Double
    /// Whether the header is one VoxCarrel can rewrite (`LibraryService.repairLengthHeaders`).
    public var repairable: Bool

    public init(statedSeconds: Double, trueSeconds: Double, repairable: Bool) {
        self.statedSeconds = statedSeconds
        self.trueSeconds = trueSeconds
        self.repairable = repairable
    }
}

/// Everything read from one file.
public struct FileContents: Equatable, Sendable {
    /// `durationSeconds` is set for audio and `pageCount` for PDFs. For an MP3 whose
    /// length header is wrong it is the measured length, not the stated one.
    public var metadata: BookMetadata
    public var cover: CoverImage?
    public var chapters: [Chapter]
    /// Set for an MP3 that states a length it does not have.
    public var lengthProblem: LengthProblem?

    public init(
        metadata: BookMetadata = BookMetadata(), cover: CoverImage? = nil, chapters: [Chapter] = [],
        lengthProblem: LengthProblem? = nil
    ) {
        self.metadata = metadata
        self.cover = cover
        self.chapters = chapters
        self.lengthProblem = lengthProblem
    }
}

/// The outcome of a successful write.
public struct WriteReport: Equatable, Sendable {
    /// Fields this file's format cannot hold, so they live in the app database only.
    /// Contains `.cover` only when a cover change was asked for and could not be made.
    public var notWritten: Set<MetadataField>

    public init(notWritten: Set<MetadataField> = []) {
        self.notWritten = notWritten
    }
}

/// Where a file sits in a multi-part audiobook.
public struct PartPosition: Codable, Equatable, Sendable {
    /// 1-based.
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

/// An audio file's own per-track tags, as distinct from the book it belongs to.
/// Kept so a file can be put back exactly as it was.
public struct TrackTags: Codable, Equatable, Sendable {
    /// The track title (`©nam` / `TIT2`); nil when the file has none.
    public var title: String?
    /// The track number as stored (`trkn` / `TRCK`), e.g. "3/12"; nil when the file has none.
    public var number: String?

    public init(title: String?, number: String?) {
        self.title = title
        self.number = number
    }
}

public enum MetadataIOError: Error, Equatable {
    /// The extension is not one VoxCarrel reads or writes.
    case unsupportedFormat(String)
    /// The file could not be opened or parsed as its format.
    case unreadable(String)
    /// The file is password-protected, encrypted, read-only or locked in the Finder,
    /// or its folder cannot be written to.
    case locked(String)
    /// The path is a symbolic link, a folder or something else that is not a plain file.
    /// Links are never followed: the file they point at would be edited in place.
    case notARegularFile(String)
    /// The changed copy did not pass its checks; the original was left untouched.
    case verificationFailed(String)
    /// The write was abandoned and the original is untouched, but the working copy at this
    /// path could not be deleted.
    case cleanupFailed(String)
}

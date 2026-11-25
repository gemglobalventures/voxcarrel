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

/// A file's size and the date it was last changed: what tells whether it is still the
/// file it was. Asked of the file system in the plainest way there is, with nothing
/// else read along with it: the launch check asks it of every audio file.
struct QuickFileStamp: Equatable {
    var size: Int64
    /// In seconds since the reference date.
    var modified: Double

    /// Nil when there is no such file, or it cannot be looked at. A link is followed.
    init?(of url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            - Date.timeIntervalBetween1970AndReferenceDate
    }
}

/// An MP3 whose length could not be measured although something about it called for it:
/// the length it is taken to have is the one its own header states, which may be wrong.
/// Recorded with the size and date of the file as it was then, so that the same file is
/// not measured again to no purpose.
public struct UnmeasuredLength: Codable, Equatable, Sendable {
    /// The file's size in bytes when it could not be measured.
    public var size: Int64
    /// When the file was last modified, in seconds since the reference date.
    public var modified: Double
    /// The length the file states, which is the one counted for it.
    public var statedSeconds: Double

    public init(size: Int64, modified: Double, statedSeconds: Double) {
        self.size = size
        self.modified = modified
        self.statedSeconds = statedSeconds
    }

    /// For the file at `url` as it is now; nil when it cannot be looked at.
    public init?(fileAt url: URL, statedSeconds: Double) {
        guard let stamp = QuickFileStamp(of: url) else { return nil }
        self.init(size: stamp.size, modified: stamp.modified, statedSeconds: statedSeconds)
    }

    /// Whether the file at `url` is still the one that could not be measured.
    public func describes(fileAt url: URL) -> Bool {
        guard let now = UnmeasuredLength(fileAt: url, statedSeconds: statedSeconds) else { return false }
        return now.size == size && abs(now.modified - modified) < 0.001
    }
}

/// An MP3 that was read through because its book's length looked wrong for its size,
/// and was found to state its length rightly. Recorded with the size and date of the
/// file as it was then, so that the same file is not read through again at every
/// launch: a file that has changed since is read again.
public struct MeasuredLength: Codable, Equatable, Sendable {
    public var size: Int64
    /// When the file was last modified, in seconds since the reference date.
    public var modified: Double
    /// The length it was measured to have.
    public var seconds: Double

    public init(size: Int64, modified: Double, seconds: Double) {
        self.size = size
        self.modified = modified
        self.seconds = seconds
    }

    /// For the file at `url` as it is now; nil when it cannot be looked at.
    public init?(fileAt url: URL, seconds: Double) {
        guard let stamp = QuickFileStamp(of: url) else { return nil }
        self.init(size: stamp.size, modified: stamp.modified, seconds: seconds)
    }

    /// Whether the file at `url` is still the one that was measured.
    public func describes(fileAt url: URL) -> Bool {
        guard let now = MeasuredLength(fileAt: url, seconds: seconds) else { return false }
        return now.size == size && abs(now.modified - modified) < 0.001
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
    /// True for an MP3 whose frames had to be counted and could not be: its length is
    /// then the one it states, with nothing to check it against.
    public var lengthCouldNotBeMeasured: Bool

    public init(
        metadata: BookMetadata = BookMetadata(), cover: CoverImage? = nil, chapters: [Chapter] = [],
        lengthProblem: LengthProblem? = nil, lengthCouldNotBeMeasured: Bool = false
    ) {
        self.metadata = metadata
        self.cover = cover
        self.chapters = chapters
        self.lengthProblem = lengthProblem
        self.lengthCouldNotBeMeasured = lengthCouldNotBeMeasured
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

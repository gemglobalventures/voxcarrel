import Foundation

/// A cover image as stored in or destined for a file.
public struct CoverImage: Equatable, Sendable {
    public var data: Data
    /// "image/jpeg" or "image/png".
    public var mime: String

    public init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
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
public enum MetadataField: String, CaseIterable, Sendable {
    case title, subtitle, authors, narrators, series, seriesNumber, genre, year
    case publisher, summary, language, isbn, asin, cover
}

/// Everything read from one file.
public struct FileContents: Equatable, Sendable {
    /// `durationSeconds` is set for audio and `pageCount` for PDFs.
    public var metadata: BookMetadata
    public var cover: CoverImage?
    public var chapters: [Chapter]

    public init(metadata: BookMetadata = BookMetadata(), cover: CoverImage? = nil, chapters: [Chapter] = []) {
        self.metadata = metadata
        self.cover = cover
        self.chapters = chapters
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
public struct PartPosition: Equatable, Sendable {
    /// 1-based.
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

public enum MetadataIOError: Error, Equatable {
    /// The extension is not one VoxCarrel reads or writes.
    case unsupportedFormat(String)
    /// The file could not be opened or parsed as its format.
    case unreadable(String)
    /// The file is password-protected, encrypted or read-only.
    case locked(String)
    /// The changed copy did not pass its checks; the original was left untouched.
    case verificationFailed(String)
}

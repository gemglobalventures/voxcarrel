import Foundation

/// Why a book cannot be sent to the phone at all.
public enum SendBlocker: Equatable, Sendable {
    /// The book has no audio file in the library.
    case noAudio
    /// An audio file of the book is not on disk; its name.
    case missingFile(String)
    /// An audio file of the book is not an M4B, M4A or MP3; its name.
    case unsupportedFormat(String)
    /// The book has files but no folder in the library.
    case notFiled
}

/// Something the owner should know before sending a book. None of them stops the send.
public enum SendWarning: Equatable, Sendable {
    /// This many files state a length they do not have. Repair fixes it.
    case wrongLengthHeader(files: Int)
    /// This many files do not hold the book's details: the last write to them failed.
    case tagsNotWritten(files: Int)
    /// None of the audio files holds a cover.
    case noCoverInFile
    /// The book was sent before; when it last was.
    case sentBefore(Date)
    /// The files come to more than a gigabyte.
    case large(bytes: Int64)
}

/// One chapter mark of a file that was sent.
public struct SentChapter: Codable, Equatable, Sendable {
    /// Seconds from the start of its file.
    public var start: Double
    public var title: String

    public init(start: Double, title: String) {
        self.start = start
        self.title = title
    }
}

/// One file as it was sent.
public struct SentFile: Codable, Equatable, Sendable {
    /// The name it was sent under.
    public var name: String
    /// Its size on disk.
    public var bytes: Int64
    /// How long it plays; nil when that is not known.
    public var seconds: Double?
    /// Its chapter marks, in order.
    public var chapters: [SentChapter]

    public init(name: String, bytes: Int64, seconds: Double?, chapters: [SentChapter]) {
        self.name = name
        self.bytes = bytes
        self.seconds = seconds
        self.chapters = chapters
    }
}

/// What tells one sending of a book from another: its files, in playing order, each with
/// its size, length and chapter marks. Kept with the record of the send, so that what
/// comes back from the phone later can be matched to the files as they were then.
public struct SendFingerprint: Codable, Equatable, Sendable {
    public var files: [SentFile]

    public init(files: [SentFile]) {
        self.files = files
    }
}

/// Whether a book can be sent, what to warn of, and exactly which files would go.
public struct SendCheck: Equatable, Sendable {
    /// Not empty: nothing can be sent.
    public var blockers: [SendBlocker]
    public var warnings: [SendWarning]
    /// The audio files, in playing order; empty when blocked.
    public var files: [URL]
    public var totalBytes: Int64
    /// True for more than one file: they go as one zip.
    public var needsPackage: Bool
    /// The zip's name: the book's title made safe, with ".zip".
    public var packageName: String
    public var fingerprint: SendFingerprint
    /// Whether the cover inside the audio is square, or within 2% of it: that of the
    /// first audio file that holds one. Nil when none holds a cover that can be read.
    public var coverIsSquare: Bool?

    public init(
        blockers: [SendBlocker], warnings: [SendWarning], files: [URL], totalBytes: Int64, needsPackage: Bool,
        packageName: String, fingerprint: SendFingerprint, coverIsSquare: Bool? = nil
    ) {
        self.coverIsSquare = coverIsSquare
        self.blockers = blockers
        self.warnings = warnings
        self.files = files
        self.totalBytes = totalBytes
        self.needsPackage = needsPackage
        self.packageName = packageName
        self.fingerprint = fingerprint
    }
}

/// What the owner chose for a send.
public struct SendOptions: Equatable, Sendable {
    /// Send copies whose cover has been made square (`CoverSquaring`), when the cover is
    /// not square already. The library's own files are never changed.
    public var squareCover: Bool

    public init(squareCover: Bool = false) {
        self.squareCover = squareCover
    }
}

/// What was made ready to send.
public struct PreparedSend: Equatable, Sendable {
    /// The one file to send: a library file itself, or a copy or a zip in the folder given.
    public var file: URL
    /// What is actually sent: where copies were made, their sizes.
    public var fingerprint: SendFingerprint
    /// How many files are sent as copies with the squared cover.
    public var coversSquared: Int
    /// How many files would not take the squared cover and are sent as they were.
    public var coversNotSquared: Int

    public init(file: URL, fingerprint: SendFingerprint, coversSquared: Int, coversNotSquared: Int) {
        self.file = file
        self.fingerprint = fingerprint
        self.coversSquared = coversSquared
        self.coversNotSquared = coversNotSquared
    }
}

/// How a book was sent.
public enum SendMethod: String, Codable, Sendable {
    /// Through the system's share sheet.
    case share
    /// Fetched by the phone from a link.
    case link
}

/// One sending of a book.
public struct SentRecord: Equatable, Sendable {
    public var bookId: Int64
    public var sentAt: Date
    public var method: SendMethod
    public var fingerprint: SendFingerprint

    public init(bookId: Int64, sentAt: Date, method: SendMethod, fingerprint: SendFingerprint) {
        self.bookId = bookId
        self.sentAt = sentAt
        self.method = method
        self.fingerprint = fingerprint
    }
}

/// Why the file to send could not be made. Nothing in the library was changed, and
/// nothing was left in the folder given.
public enum SendError: Error, Equatable {
    /// The check has blockers, or lists no file.
    case nothingToSend
    /// The folder given for the package is the library or inside it.
    case folderInsideLibrary
    /// The package's name is not a plain file name.
    case badPackageName
    /// Two of the files have this name: they cannot both be in one zip.
    case nameClash(String)
    /// This file is a link, a folder or something else that is not a plain file.
    case notARegularFile(String)
    /// The folder given already holds something of the package's name.
    case packageExists(String)
}

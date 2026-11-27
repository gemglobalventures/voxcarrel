import Foundation
import VoxCarrelCore

/// What a warning of the Send to Phone sheet offers to put it right with.
public enum SendFix: Equatable, Sendable {
    /// Repair the wrong length headers (`AppModel.sendRepair`).
    case repair
    /// Save the unsaved changes (`AppModel.sendSave`).
    case save

    /// What the button says.
    public var title: String {
        switch self {
        case .repair: "Repair"
        case .save: "Save"
        }
    }
}

/// One warning of the Send to Phone sheet.
public struct SendWarningRow: Equatable, Sendable, Identifiable {
    /// Its place among the warnings.
    public var id: Int
    public var text: String
    /// What puts it right; nil when nothing the sheet offers does.
    public var fix: SendFix?

    public init(id: Int, text: String, fix: SendFix? = nil) {
        self.id = id
        self.text = text
        self.fix = fix
    }
}

/// Every sentence of Send to Phone (PH21, PH24, PH27, PH29).
public enum SendText {
    // MARK: Blockers and warnings

    /// PH20: the one blocker of a book whose edits are not saved.
    public static let saveFirst = "Save your changes first."

    /// PH21: why the book cannot be sent, as one sentence.
    public static func blocker(_ blocker: SendBlocker) -> String {
        switch blocker {
        case .noAudio:
            "This book has no audiobook files to send."
        case .missingFile(let name):
            "\"\(name)\" cannot be found."
        case .unsupportedFormat(let name):
            "\"\(name)\" is not an M4B, M4A or MP3 file, so the phone's player cannot take it."
        case .notFiled:
            "This book has not been filed in the library folder yet."
        }
    }

    /// PH21: what the owner should know before sending, as one sentence.
    public static func warning(
        _ warning: SendWarning, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        switch warning {
        case .wrongLengthHeader(let files):
            files == 1
                ? "1 file has a wrong length header. Some players will stop early."
                : "\(files) files have a wrong length header. Some players will stop early."
        case .tagsNotWritten(let files):
            files == 1
                ? "1 file does not hold the book's details: the last write to it failed."
                : "\(files) files do not hold the book's details: the last write to them failed."
        case .noCoverInFile:
            "The audio has no cover inside it, so the phone will show none."
        case .sentBefore(let date):
            "This book was sent to the phone on \(day(date, now: now, locale: locale, timeZone: timeZone))."
        case .large(let bytes):
            "This is a large book (\(size(bytes))). Sending it will take a while."
        }
    }

    /// SP14: said when a copy would not take the squared cover; nil when every copy did.
    public static func coverNotSquared(files: Int) -> String? {
        guard files > 0 else { return nil }
        return files == 1
            ? "The cover could not be made square for one file."
            : "The cover could not be made square for \(files) files."
    }

    // MARK: Size

    /// "Also send the ebook (EPUB, 1 MB)", "Also send the companion PDFs (2 files, 3 MB)";
    /// nil when the book has none.
    public static func alsoOffer(_ what: String, files: [URL]) -> String? {
        guard !files.isEmpty else { return nil }
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        if files.count == 1 {
            let kind = files[0].pathExtension.uppercased()
            return "Also send the \(what) (\(kind.isEmpty || what.hasSuffix("PDF") ? "" : kind + ", ")\(size(bytes)))"
        }
        return "Also send the \(what)s (\(files.count) files, \(size(bytes)))"
    }

    public static let alsoNote =
        "They go with the audiobook through AirDrop and Share, as files of their own. The link for BookPlayer carries the audiobook alone."

    /// "1 file, 412 MB" or "4 files, 1.2 GB, sent as one zip".
    public static func sizeLine(files: Int, bytes: Int64, asZip: Bool) -> String {
        "\(files == 1 ? "1 file" : "\(files) files"), \(size(bytes))" + (asZip ? ", sent as one zip" : "")
    }

    /// A size as the Finder counts it, written the same whatever the Mac's region:
    /// "512 bytes", "12 KB", "412 MB", "1.2 GB".
    public static func size(_ bytes: Int64) -> String {
        let bytes = max(bytes, 0)
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        if bytes < 999_500 { return "\(Int((Double(bytes) / 1000).rounded())) KB" }
        if bytes < 999_500_000 { return "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }
        let tenths = Int((Double(bytes) / 100_000_000).rounded())
        return "\(tenths / 10).\(tenths % 10) GB"
    }

    // MARK: The link

    public static let waiting = "Waiting for the phone…"
    public static let sent = "Sent."
    public static let expired = "The link has expired."
    public static let shared = "Shared."
    public static let noTemporaryFolder = "VoxCarrel could not make a temporary folder for the copy to send."
    public static let cancel = "Cancel"
    public static let done = "Done"
    public static let airDropUnavailable =
        "AirDrop is not available on this Mac just now. Check that Wi-Fi and Bluetooth are on."
    public static let checkingLabel = "Checking the book…"
    public static let preparingLabel = "Preparing the book…"
    public static let keepAwakeReason = "Sending a book to the phone"
    public static let makeNewLink = "Make a New Link"
    public static let scanHelp =
        "Open your phone's camera and point it at this code. BookPlayer will ask to download the book."
    public static let squareCoverTitle = "Make the cover square for the phone"
    public static let ownNetworkTitle = "This is my own network"

    /// PH24: how far the phone has got, as a whole percent that never passes 100.
    public static func sending(bytesSent: Int64, of total: Int64) -> String {
        guard total > 0 else { return "Sending…" }
        // The product is worked out at full width: a hundred times a very large size
        // does not fit in the size's own type.
        let sent = UInt64(min(max(bytesSent, 0), total))
        let percent = UInt64(total).dividingFullWidth(sent.multipliedFullWidth(by: 100)).quotient
        return "Sending… \(percent)%"
    }

    /// PH24: the link stopped for a reason of the server's own.
    public static func failed(_ why: String) -> String {
        let why = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return why.isEmpty ? "The book could not be sent." : "The book could not be sent. \(why)"
    }

    // MARK: The network

    /// PH27: on a network marked as the owner's.
    public static let sameNetwork = "Your phone must be on the same network as this Mac."
    /// PH27: on any other network.
    public static let otherNetwork = sameNetwork
        + " Anyone else on this network could see the book being sent. Use the link only on a network you trust."

    public static func networkNote(isOwn: Bool) -> String {
        isOwn ? sameNetwork : otherNetwork
    }

    // MARK: The inspector

    /// PH29: "Sent to phone 23 Nov"; with the year when that is not this year.
    public static func sentLine(
        _ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        "Sent to phone \(day(date, now: now, locale: locale, timeZone: timeZone))"
    }

    /// "23 Nov", or "23 Nov 2025" for a day of another year than `now`'s.
    static func day(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated)
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }
}

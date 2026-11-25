import Foundation
import VoxCarrelCore

/// What the bar along the bottom of the library window says.
public struct StatusBar: Equatable, Sendable {
    /// About the books in the list: "14 books · 46 h 10 min", or with a selection
    /// "3 of 14 books selected · 12 h 30 min".
    public var shown: String
    /// About the whole library: "Library: 22 books · 14 audiobooks · 9 ebooks · 212 h of audio · 8 unread · 38.2 GB".
    public var library: String
}

extension AppModel {
    /// SB1–SB4: the status bar; nil where there is no list of books to speak of (the
    /// Inbox, or a library that is not open).
    public var statusBar: StatusBar? {
        guard sidebarSelection != .inbox, rowsLoaded else { return nil }
        // SV6: the books of the library; not the rows for books it does not have.
        let listed = rows.filter { !$0.isMissing }
        let chosen = listed.filter { selection.contains($0.id) }
        return StatusBar(
            shown: StatusBarText.shown(
                count: listed.count, seconds: StatusBarText.seconds(of: listed),
                selected: chosen.count, selectedSeconds: StatusBarText.seconds(of: chosen)),
            // While the library is checked behind its list, that is said before its totals.
            library: (isCheckingLibrary ? "\(Self.checkingLabel) · " : "") + StatusBarText.library(
                books: sidebar.counts[.allBooks] ?? 0, audiobooks: sidebar.counts[.audiobooks] ?? 0,
                ebooks: sidebar.counts[.ebooks] ?? 0, unread: sidebar.counts[.unread] ?? 0,
                audioSeconds: sidebar.audioSeconds, diskBytes: sidebar.diskBytes))
    }
}

/// The wordings of the status bar.
enum StatusBarText {
    static func seconds(of rows: [BookRow]) -> Double {
        rows.reduce(0) { total, row in
            let seconds = row.book.durationSeconds ?? 0
            return total + (seconds.isFinite && seconds > 0 ? seconds : 0)
        }
    }

    /// SB1, SB2
    static func shown(count: Int, seconds: Double, selected: Int, selectedSeconds: Double) -> String {
        if selected > 0 {
            let head = "\(number(selected)) of \(books(count)) selected"
            return selectedSeconds >= 60 ? "\(head) · \(length(selectedSeconds))" : head
        }
        guard count > 0 else { return "No books" }
        return seconds >= 60 ? "\(books(count)) · \(length(seconds))" : books(count)
    }

    /// SB3
    static func library(
        books count: Int, audiobooks: Int, ebooks: Int, unread: Int, audioSeconds: Double, diskBytes: Int64 = 0
    ) -> String {
        var parts = [books(count)]
        if audiobooks > 0 { parts.append(audiobooks == 1 ? "1 audiobook" : "\(number(audiobooks)) audiobooks") }
        if ebooks > 0 { parts.append(ebooks == 1 ? "1 ebook" : "\(number(ebooks)) ebooks") }
        if audioSeconds >= 3600 { parts.append("\(number(Int((audioSeconds / 3600).rounded()))) h of audio") }
        if unread > 0 { parts.append("\(number(unread)) unread") }
        if let size = size(diskBytes) { parts.append(size) }
        return "Library: " + parts.joined(separator: " · ")
    }

    static func books(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(number(count)) books"
    }

    /// SB4: "45 min", "12 h", "12 h 30 min"; to the minute, whatever the Mac's language.
    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(number(h)) h" : "\(number(h)) h \(m) min"
    }

    /// SB5: "640 MB", "38.2 GB", "1.4 TB", in thousands as the Finder counts; nil below
    /// one megabyte, which is not worth saying.
    static func size(_ bytes: Int64) -> String? {
        guard bytes >= 1_000_000 else { return nil }
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 1000 { return "\(Int(megabytes.rounded())) MB" }
        func oneDecimal(_ value: Double) -> String {
            let tenths = Int((value * 10).rounded())
            return tenths % 10 == 0 ? "\(number(tenths / 10))" : "\(number(tenths / 10)).\(tenths % 10)"
        }
        let gigabytes = megabytes / 1000
        return gigabytes < 1000 ? "\(oneDecimal(gigabytes)) GB" : "\(oneDecimal(gigabytes / 1000)) TB"
    }

    /// A count with commas between the thousands.
    static func number(_ value: Int) -> String {
        var digits = String(abs(value))
        var out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits = String(digits.dropLast(3))
        }
        return (value < 0 ? "-" : "") + digits + out
    }
}

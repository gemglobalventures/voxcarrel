import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// G1: the small symbols that say what a book is and how far along it is. Each explains
// itself when the pointer rests on it.

/// Headphones when the book has audio, a book when it has an ebook.
struct FormatBadges: View {
    let row: BookRow
    /// A tooltip for both symbols in place of each one's own.
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            if row.hasAudio {
                Image(systemName: "headphones")
                    .help(help ?? "Audiobook")
                    .accessibilityLabel("Audiobook")
            }
            if row.hasEbook {
                Image(systemName: "book.closed")
                    .help(help ?? "Ebook")
                    .accessibilityLabel("Ebook")
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// A half-filled circle for in progress, a tick for finished, nothing for unread.
struct StatusMarker: View {
    let status: ReadStatus

    var body: some View {
        switch status {
        case .unread:
            EmptyView()
        case .inProgress:
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.tint)
                .help(status.title)
                .accessibilityLabel(status.title)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(status.title)
                .accessibilityLabel(status.title)
        }
    }
}

/// A warning triangle for a book that needs attention or has a file whose tags were not written.
struct WarningBadge: View {
    let row: BookRow

    var body: some View {
        if let warning = row.warningText {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .help(warning)
                .accessibilityLabel(warning)
        }
    }
}

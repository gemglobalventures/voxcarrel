import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// G1: the small symbols that say what a book is and how far along it is. Each explains
// itself when the pointer rests on it.

/// Headphones when the book has audio, a book when it has an ebook; a cloud beside them
/// when it is also on Audible. A book with no files here shows the cloud alone (plan 6, V2).
struct FormatBadges: View {
    let row: BookRow
    /// A tooltip for every symbol in place of each one's own.
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            if row.hasFiles {
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
            if let whereabouts = row.whereaboutsText {
                Image(systemName: SidebarItem.onAudible.symbol)
                    .help(help ?? whereabouts)
                    .accessibilityLabel(whereabouts)
                    .accessibilityIdentifier("books.badge.onAudible")
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Plan 6, V2: the small label in a corner of the cover of a book that is on Audible and
/// has no files here: a cloud and the word, on a material so that it reads over any cover.
struct AudibleCoverLabel: View {
    let row: BookRow

    var body: some View {
        if !row.hasFiles, let whereabouts = row.whereaboutsText {
            Label(ExternalKind.audible.title, systemImage: SidebarItem.onAudible.symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                }
                .padding(5)
                .help(whereabouts)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(whereabouts)
                .accessibilityIdentifier("books.cover.onAudible")
        }
    }
}

/// Plan 7, K10: what kind of edition a book is, when that is worth saying ("Abridged",
/// "Probably abridged", "Dramatised"): the words in a small capsule where there is room
/// for them, a symbol where there is not. Why it is said is in the tooltip.
struct EditionBadge: View {
    let row: BookRow

    var body: some View {
        if let label = row.editionLabel {
            ViewThatFits(in: .horizontal) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if let kind = row.book.editionKind?.kind {
                    Image(systemName: kind.symbol)
                }
            }
            .foregroundStyle(.secondary)
            .help(row.editionBadgeHelpText ?? label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("books.badge.edition")
        }
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

/// A pencil beside the title of a book that has edits not yet saved; nothing for any other.
///
/// The model is handed in, not read from the environment: a table draws each cell in a
/// view of its own, and when the table is made again a cell of the old one can be drawn
/// once more with no model in its environment, which stops the app.
struct EditedBadge: View {
    let model: AppModel
    let id: Int64

    var body: some View {
        if model.editedBookIds.contains(id) {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(EditedMark.tint)
                .help(model.editedBadgeHelp)
                .accessibilityLabel(model.editedBadgeHelp)
                .accessibilityIdentifier("books.badge.edited")
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

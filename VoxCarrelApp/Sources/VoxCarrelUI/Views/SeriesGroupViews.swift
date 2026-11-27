import AppKit
import SwiftUI
import VoxCarrelAppCore

// Plan 10: a series as one item of the list or the grid: the cells of its row in the
// list, and its stack of covers in the grid. Everything said is the group's own, and
// what a click does is the model's.
//
// The views the list draws are handed the model, not given it by the environment: a
// table draws each cell in a view of its own, and when the table is made again a cell
// of the old one can be drawn once more with no model in its environment (see
// `EditedBadge`). The grid's are handed it the same way.

/// The Title cell of a series' row: a stack for a cover, the series' name, how many
/// books it has, the pencil when any of them has unsaved edits, and the warning triangle
/// when any needs attention.
struct SeriesGroupTitleCell: View {
    let model: AppModel
    let group: SeriesGroup

    var body: some View {
        HStack(spacing: 8) {
            if group.kind == .editions, let first = group.books.first {
                // One book in several editions: its cover, as any book's row has.
                CoverView(row: first, maxSide: 30, cornerRadius: 2, dimsWithoutFiles: true)
                    .frame(width: 20, height: 30)
            } else {
                Image(systemName: SeriesGroupMark.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 30)
                    .accessibilityHidden(true)
            }
            Text(group.titleText)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(group.summaryText)
            Text(group.countText)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            SeriesGroupEditedBadge(model: model, group: group)
            SeriesGroupWarningBadge(text: group.warningText)
        }
        .accessibilityIdentifier("books.group.\(group.name)")
    }
}

/// The symbol that stands for a series' books together.
enum SeriesGroupMark {
    static let symbol = "square.stack"
}

/// A pencil for a series any of whose books has edits not yet saved; nothing for any other.
struct SeriesGroupEditedBadge: View {
    let model: AppModel
    let group: SeriesGroup

    var body: some View {
        if model.editedMark(for: group) {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(EditedMark.tint)
                .help(model.editedBadgeHelp)
                .accessibilityLabel(model.editedBadgeHelp)
                .accessibilityIdentifier("books.group.badge.edited")
        }
    }
}

/// A warning triangle for a series some of whose books have one; how many is the tooltip.
struct SeriesGroupWarningBadge: View {
    let text: String?

    var body: some View {
        if let text {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .help(text)
                .accessibilityLabel(text)
                .accessibilityIdentifier("books.group.badge.warning")
        }
    }
}

/// Headphones when any of the series' books has audio here, a book when any has an
/// ebook here, a cloud when any is on Audible, the pages of a book when any is on Kindle:
/// as `FormatBadges`, for all of them together.
struct SeriesGroupFormatBadges: View {
    let group: SeriesGroup

    var body: some View {
        HStack(spacing: 4) {
            if group.hasAudioFiles {
                Image(systemName: "headphones")
                    .help("Audiobook")
                    .accessibilityLabel("Audiobook")
            }
            if group.hasEbookFiles {
                Image(systemName: "book.closed")
                    .help("Ebook")
                    .accessibilityLabel("Ebook")
            }
            if group.isOnAudible {
                Image(systemName: SidebarItem.onAudible.symbol)
                    .help("On Audible")
                    .accessibilityLabel("On Audible")
                    .accessibilityIdentifier("books.group.badge.onAudible")
            }
            if group.isOnKindle {
                Image(systemName: SidebarItem.onKindle.symbol)
                    .help("On Kindle")
                    .accessibilityLabel("On Kindle")
                    .accessibilityIdentifier("books.group.badge.onKindle")
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: The grid

/// One series in the grid with what clicking it does: a view of its own, so that it is
/// drawn again when the selection changes, whenever the grid made it.
struct SeriesGridItem: View {
    let model: AppModel
    let group: SeriesGroup
    var isGridFocused: FocusState<Bool>.Binding

    var body: some View {
        let isSelected = model.itemSelection.contains(group.id)
        SeriesGridCell(
            model: model, group: group, isSelected: isSelected, isPartlySelected: model.isPartlySelected(group)
        )
        .overlay {
            ClickCatcher(toolTip: group.summaryText) {
                model.contextClickItem(group.id)
            } onClick: { modifiers, clickCount in
                isGridFocused.wrappedValue = true
                clicked(modifiers: modifiers, clickCount: clickCount)
            }
        }
        .contextMenu {
            BookContextMenu(model: model, ids: model.contextTarget(forItem: group.id))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.summaryText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.clickItem(group.id, modifiers: []) }
        .accessibilityIdentifier("books.stack.\(group.name)")
    }

    /// The first press of a click selects the series' books; the second of a
    /// double-click opens the series' own view.
    private func clicked(modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        switch clickCount {
        case 1: model.clickItem(group.id, modifiers: GridClicks.selectionModifiers(modifiers))
        case 2: model.openItems([group.id])
        default: break
        }
    }
}

/// One series in the grid: a stack of its first covers, its name, how many books it
/// has, and its marks. Selected like a book's cell when all its books are; with a
/// fainter fill and a broken outline when only some are.
private struct SeriesGridCell: View {
    let model: AppModel
    let group: SeriesGroup
    let isSelected: Bool
    let isPartlySelected: Bool

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            // The same upright box a book's cover has.
            Color.clear
                .aspectRatio(CoverPlaceholder.aspectRatio, contentMode: .fit)
                .overlay {
                    CoverStack(rows: group.coverRows)
                }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(group.titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SeriesGroupEditedBadge(model: model, group: group)
                    .font(.callout)
            }
            Text(group.countText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                SeriesGroupFormatBadges(group: group)
                Spacer(minLength: 0)
                SeriesGroupWarningBadge(text: group.warningText)
            }
            .font(.caption)
            .frame(height: 14)
        }
        .padding(GridMetrics.cellPadding)
        .background(outline.fill(Color.accentColor.opacity(isSelected ? 0.22 : (isPartlySelected ? 0.1 : 0))))
        .overlay {
            if isSelected {
                outline.strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isPartlySelected {
                outline.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
    }
}

/// Up to three covers as a stack: the first in front at the foot of the box, the others
/// behind it, each a step up and to the right and a little fainter.
private struct CoverStack: View {
    let rows: [BookRow]

    /// How much of the box one cover takes: the rest is the steps of those behind it.
    private static let scale: CGFloat = 0.86
    /// Where in the box a cover is held, front to back.
    private static let anchors: [UnitPoint] = [.bottomLeading, .center, .topTrailing]
    private static let opacities: [Double] = [1, 0.75, 0.5]

    var body: some View {
        ZStack {
            // Drawn back to front.
            ForEach(Array(rows.prefix(Self.anchors.count).enumerated()).reversed(), id: \.element.id) { place, row in
                Color.clear
                    .overlay(alignment: .bottom) {
                        CoverView(row: row, maxSide: GridMetrics.coverSide, dimsWithoutFiles: true)
                    }
                    .scaleEffect(Self.scale, anchor: Self.anchors[place])
                    .opacity(Self.opacities[place])
            }
        }
    }
}

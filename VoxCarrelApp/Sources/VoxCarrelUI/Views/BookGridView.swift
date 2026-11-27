import AppKit
import SwiftUI
import VoxCarrelAppCore

/// The sizes of the grid, and the sums done with them.
enum GridMetrics {
    /// The narrowest a cell may be. Cells widen to fill the row.
    static let minimumCellWidth: CGFloat = 130
    /// Between cells, across and down.
    static let spacing: CGFloat = 12
    /// Around the whole grid.
    static let padding: CGFloat = 16
    /// Inside a cell, around its cover and text.
    static let cellPadding: CGFloat = 8
    /// The tallest a cover is ever shown: cells are widest when two just fit and a third
    /// almost does, about 200 points, and a cover is half as tall again as it is wide.
    static let coverSide: CGFloat = 280

    static let columns = [GridItem(.adaptive(minimum: minimumCellWidth), spacing: spacing, alignment: .top)]

    /// How many columns an adaptive grid makes in this width: as many cells of the
    /// minimum width, with their spacing, as fit, and one at least.
    static func columnCount(inWidth width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumCellWidth + spacing)))
    }
}

/// G1, G2, G4, G5: the books as covers. Plan 10: each of the model's items is a cell: a
/// book, or a series as a stack of covers.
struct BookGridView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    /// How many columns the grid has made, for the arrow keys.
    @State private var columnCount = 1

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: GridMetrics.columns, spacing: GridMetrics.spacing) {
                        ForEach(model.items) { item in
                            switch item {
                            case .book(let row):
                                BookGridItem(model: model, row: row, isGridFocused: $isFocused)
                            case .series(let group):
                                SeriesGridItem(model: model, group: group, isGridFocused: $isFocused)
                            }
                        }
                    }
                    .onGeometryChange(for: Int.self) { grid in
                        GridMetrics.columnCount(inWidth: grid.size.width)
                    } action: { count in
                        columnCount = count
                    }
                    .padding(GridMetrics.padding)
                    // As tall as the window at least, so that a click below the last row lands here too.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .background {
                        // G2: a click on empty space.
                        ClickCatcher { _, _ in
                            isFocused = true
                            model.select([])
                        }
                    }
                }
                .focusable(true, interactions: .edit)
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    if let id = model.moveItemSelection(Self.direction(of: press.key), columns: columnCount) {
                        scroller.scrollTo(id)
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    // G4: one book is opened; one series is shown in its own view.
                    model.openItems(model.itemSelection)
                    return .handled
                }
                // G5: Delete and ⌘⌫, only while the grid has the keys.
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    model.requestRemoveSelection()
                    return .handled
                }
                .onDeleteCommand {
                    model.requestRemoveSelection()
                }
                .onCommand(#selector(NSResponder.selectAll(_:))) {
                    model.selectAll()
                }
                // Plan 10: back from a series' own view, to the stack it was opened from.
                .onChange(of: model.seriesReturnCount) {
                    guard let id = model.itemScrollTarget else { return }
                    Task { @MainActor in scroller.scrollTo(id, anchor: .center) }
                }
            }
        }
        .accessibilityIdentifier("books.grid")
    }

    private static func direction(of key: KeyEquivalent) -> SelectionLogic.Direction {
        switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
    }
}

/// One book in the grid with what clicking it does: a view of its own, so that it is
/// drawn again when the selection changes, whenever the grid made it.
private struct BookGridItem: View {
    let model: AppModel
    let row: BookRow
    var isGridFocused: FocusState<Bool>.Binding

    var body: some View {
        let isSelected = model.selection.contains(row.id)
        BookGridCell(model: model, row: row, isSelected: isSelected, formatsAreDrawnAbove: true)
            .overlay {
                ClickCatcher(toolTip: row.summaryText) {
                    model.contextClickItem(.book(row.id))
                } onClick: { modifiers, clickCount in
                    isGridFocused.wrappedValue = true
                    clicked(modifiers: modifiers, clickCount: clickCount)
                }
            }
            // The format symbols are buttons, so they stand above what catches the
            // cell's clicks, exactly where the cell leaves room for them.
            .overlay(alignment: .bottomLeading) {
                FormatBadges(row: row, onListen: { model.listen(row.id) }, onRead: { model.read(row.id) })
                    .font(.caption)
                    .frame(height: 14)
                    .padding(GridMetrics.cellPadding)
            }
            .contextMenu {
                BookContextMenu(model: model, ids: model.contextTarget(forItem: .book(row.id)))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.summaryText)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.clickItem(.book(row.id), modifiers: []) }
            .accessibilityIdentifier("books.cell.\(row.id)")
    }

    /// The first press of a click selects (G2); the second of a double-click opens (G4).
    private func clicked(modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        switch clickCount {
        case 1: model.clickItem(.book(row.id), modifiers: GridClicks.selectionModifiers(modifiers))
        case 2: model.openItems([.book(row.id)])
        default: break
        }
    }
}

/// The keys held at a click in the grid, as the model takes them.
enum GridClicks {
    static func selectionModifiers(_ flags: NSEvent.ModifierFlags) -> SelectionLogic.Modifiers {
        var modifiers: SelectionLogic.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// G1: one book in the grid: its cover in an upright box, its title, its first author
/// and its badges.
private struct BookGridCell: View {
    let model: AppModel
    let row: BookRow
    let isSelected: Bool
    /// True when the format symbols are drawn over the cell as buttons; the cell then
    /// only keeps their room.
    var formatsAreDrawnAbove = false

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            // The box is upright whatever the cover is; a square cover stands at its foot.
            Color.clear
                .aspectRatio(CoverPlaceholder.aspectRatio, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    CoverView(row: row, maxSide: GridMetrics.coverSide, dimsWithoutFiles: true)
                }
                // Plan 6, V2: only for a book that is on Audible and has no files here.
                .overlay(alignment: .bottomTrailing) {
                    AudibleCoverLabel(row: row)
                }
                // Plan 9: in the same corner, for a book the library does not have.
                .overlay(alignment: .bottomTrailing) {
                    MissingCoverLabel(row: row)
                }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.book.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(row.isMissing ? .secondary : .primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EditedBadge(model: model, id: row.id)
                    .font(.callout)
            }
            // Plan 9: under the title, for a book that differs from Audible's list.
            SeriesNoteLabel(row: row)
            Text(row.firstAuthorText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                FormatBadges(row: row)
                    .opacity(formatsAreDrawnAbove ? 0 : 1)
                // The room between the symbols is the edition label's, when there is one.
                if row.editionLabel != nil {
                    EditionBadge(row: row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                OutsideBadge(row: row)
                StatusMarker(status: row.book.readStatus)
                WarningBadge(row: row)
            }
            .font(.caption)
            .frame(height: 14)
        }
        .padding(GridMetrics.cellPadding)
        .background(outline.fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .overlay(outline.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

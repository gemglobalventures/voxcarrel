import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// One row of the list: the app's item, a book or a series. (The engine has a type of the
/// same name, which is something else.)
private typealias ListItem = VoxCarrelAppCore.LibraryItem

/// G3, G4, G5: the books as a table. The rows are the model's items, already in order: a
/// click on a column header only tells the model which sort is wanted.
///
/// Plan 10: an item is a book or, when the list is grouped by series, a series: a row
/// that opens to show its books, each drawn as any book's row is.
struct BookListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollViewReader { scroller in
            // The table fits its columns to the room there is, sharing it out equally above
            // each column's least width, so it is the least widths that decide whether all
            // seven are seen, and how wide each is when room is short. They come to 486,
            // and to about 620 with the 17 points the table puts between columns and its
            // insets: the room beside the sidebar and the inspector in a window of the
            // default size is about 630. Title's is much the largest, and only Title has
            // no greatest width: it takes the room the rest leave.
            Table(of: ListItem.self, selection: Self.selection(in: model), sortOrder: $model.itemTableSortOrder) {
                TableColumn("Title", value: \.titleSortKey) { item in
                    ItemTitleCell(model: model, item: item)
                }
                .width(min: 136, ideal: 280)
                TableColumn("Author", value: \.authorSortKey) { item in
                    ItemAuthorCell(item: item)
                }
                .width(min: 70, ideal: 140, max: 240)
                TableColumn("Series", value: \.seriesSortKey) { item in
                    ItemSeriesCell(item: item)
                }
                .width(min: 50, ideal: 120, max: 200)
                TableColumn("Formats", value: \.formatsSortKey) { item in
                    ItemFormatsCell(item: item)
                }
                .width(min: 54, ideal: 58, max: 70)
                TableColumn("Length", value: \.lengthSortKey) { item in
                    ItemLengthCell(item: item)
                }
                .width(min: 50, ideal: 60, max: 70)
                TableColumn("Added", value: \.dateAddedSortKey) { item in
                    ItemAddedCell(item: item)
                }
                .width(min: 60, ideal: 66, max: 80)
                TableColumn("Status", value: \.statusSortKey) { item in
                    ItemStatusCell(item: item)
                }
                .width(min: 52, ideal: 90, max: 100)
            } rows: {
                ForEach(model.items) { item in
                    if case .series(let group) = item {
                        DisclosureTableRow(item, isExpanded: Self.isOpen(group.name, in: model)) {
                            ForEach(group.books) { row in
                                TableRow(ListItem.book(row))
                            }
                        }
                    } else {
                        TableRow(item)
                    }
                }
            }
            .contextMenu(forSelectionType: ItemID.self) { ids in
                if !ids.isEmpty {
                    // The row the menu was opened on, or the selection when that row is
                    // part of it: a series' row stands for its books.
                    BookContextMenu(model: model, ids: model.bookIds(of: ids))
                }
            } primaryAction: { ids in
                // G4: a double-click, or Return. On a series' row, its own view.
                model.openItems(ids)
            }
            // G5: Delete and ⌘⌫, only while the list has the keys.
            .onDeleteCommand {
                model.requestRemoveSelection()
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                model.requestRemoveSelection()
                return .handled
            }
            // G8: made again when the rows are a very different list (see `RowsChange`),
            // and when they become grouped or stop being.
            .id(model.itemsVersion)
            .accessibilityIdentifier("books.table")
            // A list that has been made again starts at the top: back to what is selected.
            .onChange(of: model.itemsVersion) {
                guard let id = model.itemScrollTarget else { return }
                Task { @MainActor in scroller.scrollTo(id, anchor: .center) }
            }
        }
    }

    // Both are given the model itself, as a table's cells are: the table reads them
    // when it pleases, and not only while this view is being drawn.

    private static func selection(in model: AppModel) -> Binding<Set<ItemID>> {
        Binding(get: { model.itemSelection }, set: { model.selectItems($0) })
    }

    /// Whether the series' row is open. The model can refuse to close one, so what is
    /// shown is always read from the model.
    private static func isOpen(_ name: String, in model: AppModel) -> Binding<Bool> {
        Binding(get: { model.openGroups.contains(name) }, set: { model.setGroup(name, open: $0) })
    }
}

// One cell of each column, for a book's row or a series' row. Like every view a table
// draws, they are handed what they show, and the model where they need it: none reads
// the model from the environment (see `EditedBadge`).

private struct ItemTitleCell: View {
    let model: AppModel
    let item: ListItem

    var body: some View {
        switch item {
        case .book(let row): TitleCell(model: model, row: row)
        case .series(let group): SeriesGroupTitleCell(model: model, group: group)
        }
    }
}

private struct ItemAuthorCell: View {
    let item: ListItem

    var body: some View {
        switch item {
        case .book(let row): TextCell(text: row.authorsText)
        case .series(let group): TextCell(text: group.authorsText)
        }
    }
}

/// Nothing for a series' row: its name is its title.
private struct ItemSeriesCell: View {
    let item: ListItem

    var body: some View {
        if case .book(let row) = item {
            TextCell(text: row.seriesText)
        }
    }
}

private struct ItemFormatsCell: View {
    let item: ListItem

    var body: some View {
        switch item {
        case .book(let row): FormatsCell(row: row)
        case .series(let group):
            SeriesGroupFormatBadges(group: group)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ItemLengthCell: View {
    let item: ListItem

    var body: some View {
        switch item {
        case .book(let row):
            TextCell(text: row.lengthText)
                .monospacedDigit()
        case .series(let group):
            TextCell(text: group.lengthText)
                .monospacedDigit()
        }
    }
}

private struct ItemAddedCell: View {
    let item: ListItem

    var body: some View {
        switch item {
        case .book(let row): AddedCell(date: row.addedDate)
        case .series(let group): AddedCell(date: group.newestAdded)
        }
    }
}

private struct ItemStatusCell: View {
    let item: ListItem

    var body: some View {
        switch item {
        case .book(let row): StatusCell(status: row.shownReadStatus)
        case .series(let group):
            // The whole phrase ("2 of 5 finished") does not fit the column.
            TextCell(text: group.statusColumnText)
                .help(group.statusText)
                .accessibilityLabel(group.statusText)
        }
    }
}

/// A small cover, the title, a word for a book the library does not have, what kind of edition it is when that is worth saying, the
/// pencil of a book with unsaved edits, and the warning triangle.
private struct TitleCell: View {
    let model: AppModel
    let row: BookRow

    var body: some View {
        HStack(spacing: 8) {
            CoverView(row: row, maxSide: 30, cornerRadius: 2, dimsWithoutFiles: true)
                .frame(width: 20, height: 30)
            Text(row.book.title)
                .lineLimit(1)
                .foregroundStyle(row.isMissing ? .secondary : .primary)
                .help(row.book.title)
            MissingBadge(row: row)
            SeriesNoteLabel(row: row)
            // In words where the column has room for them, a symbol where it has not.
            EditionBadge(row: row)
            EditedBadge(model: model, id: row.id)
            WarningBadge(row: row)
        }
        .accessibilityIdentifier("books.row.\(row.id)")
    }
}

private struct TextCell: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(.secondary)
    }
}

/// The symbols alone; the formats' names are in the tooltip.
private struct FormatsCell: View {
    let row: BookRow

    var body: some View {
        FormatBadges(row: row, help: row.formatsHelpText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(row.formatsHelpText)
    }
}

/// A short date; the whole date is in the tooltip. Nothing for a row that has no date.
private struct AddedCell: View {
    let date: Date?

    var body: some View {
        if let date {
            let full = AddedDateText.full(date)
            Text(AddedDateText.compact(date))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .help(full)
                .accessibilityLabel(full)
        }
    }
}

/// Nothing for a row that has no status.
private struct StatusCell: View {
    let status: ReadStatus?

    var body: some View {
        if let status {
            HStack(spacing: 5) {
                StatusMarker(status: status)
                Text(status.title)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

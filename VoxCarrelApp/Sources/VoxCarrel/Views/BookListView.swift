import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// G3, G4, G5: the books as a table. The rows are the model's, already in order: a click
/// on a column header only tells the model which sort is wanted.
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
            Table(model.rows, selection: selection, sortOrder: $model.tableSortOrder) {
                TableColumn("Title", value: \.titleSortKey) { row in
                    TitleCell(model: model, row: row)
                }
                .width(min: 136, ideal: 280)
                TableColumn("Author", value: \.authorSortKey) { row in
                    TextCell(text: row.authorsText)
                }
                .width(min: 70, ideal: 140, max: 240)
                TableColumn("Series", value: \.seriesSortKey) { row in
                    TextCell(text: row.seriesText)
                }
                .width(min: 50, ideal: 120, max: 200)
                TableColumn("Formats", value: \.formatsSortKey) { row in
                    FormatsCell(row: row)
                }
                .width(min: 54, ideal: 58, max: 70)
                TableColumn("Length", value: \.lengthSortKey) { row in
                    TextCell(text: row.lengthText)
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 60, max: 70)
                TableColumn("Added", value: \.dateAddedSortKey) { row in
                    AddedCell(date: row.addedDate)
                }
                .width(min: 60, ideal: 66, max: 80)
                TableColumn("Status", value: \.statusSortKey) { row in
                    StatusCell(status: row.shownReadStatus)
                }
                .width(min: 52, ideal: 90, max: 100)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if !ids.isEmpty {
                    BookContextMenu(model: model, ids: ids)
                }
            } primaryAction: { ids in
                // G4: a double-click, or Return.
                model.openOne(of: ids)
            }
            // G5: Delete and ⌘⌫, only while the list has the keys.
            .onDeleteCommand {
                model.requestRemoveSelection()
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                model.requestRemoveSelection()
                return .handled
            }
            // G8: made again when the rows are a very different list; see `RowsChange`.
            .id(model.rowsVersion)
            .accessibilityIdentifier("books.table")
            // A list that has been made again starts at the top: back to what is selected.
            .onChange(of: model.rowsVersion) {
                guard let id = model.scrollTarget else { return }
                Task { @MainActor in scroller.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var selection: Binding<Set<Int64>> {
        Binding(get: { model.selection }, set: { model.select($0) })
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

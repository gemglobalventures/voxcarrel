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
            // seven are seen: with the 17 points the table puts between columns they come
            // to 600. Only Title has no greatest width, and takes the room the rest leave.
            Table(model.rows, selection: selection, sortOrder: $model.tableSortOrder) {
                TableColumn("Title", value: \.titleSortKey) { row in
                    TitleCell(row: row)
                }
                .width(min: 130, ideal: 200)
                TableColumn("Author", value: \.authorSortKey) { row in
                    TextCell(text: row.authorsText)
                }
                .width(min: 64, ideal: 130, max: 220)
                TableColumn("Series", value: \.seriesSortKey) { row in
                    TextCell(text: row.seriesText)
                }
                .width(min: 50, ideal: 120, max: 200)
                TableColumn("Formats", value: \.formatsSortKey) { row in
                    FormatsCell(row: row)
                }
                .width(min: 44, ideal: 70, max: 110)
                TableColumn("Length", value: \.lengthSortKey) { row in
                    TextCell(text: row.lengthText)
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 60, max: 70)
                TableColumn("Added", value: \.dateAddedSortKey) { row in
                    Text(row.book.dateAdded, format: .dateTime.day().month(.abbreviated).year())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 76, ideal: 84, max: 96)
                TableColumn("Status", value: \.statusSortKey) { row in
                    StatusCell(status: row.book.readStatus)
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

/// A small cover, the title, and the warning triangle.
private struct TitleCell: View {
    let row: BookRow

    var body: some View {
        HStack(spacing: 8) {
            CoverView(row: row, maxSide: 30, cornerRadius: 2)
                .frame(width: 20, height: 30)
            Text(row.book.title)
                .lineLimit(1)
                .help(row.book.title)
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

private struct FormatsCell: View {
    let row: BookRow

    var body: some View {
        HStack(spacing: 6) {
            FormatBadges(row: row)
            Text(row.formatsText)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusCell: View {
    let status: ReadStatus

    var body: some View {
        HStack(spacing: 5) {
            StatusMarker(status: status)
            Text(status.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}

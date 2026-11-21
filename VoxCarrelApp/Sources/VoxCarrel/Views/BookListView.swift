import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// G3, G4, G5: the books as a table. The rows are the model's, already in order: a click
/// on a column header only tells the model which sort is wanted.
struct BookListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Table(model.rows, selection: selection, sortOrder: $model.tableSortOrder) {
            TableColumn("Title", value: \.titleSortKey) { row in
                TitleCell(row: row)
            }
            .width(min: 160, ideal: 300)
            TableColumn("Author", value: \.authorSortKey) { row in
                TextCell(text: row.authorsText)
            }
            .width(min: 90, ideal: 170)
            TableColumn("Series", value: \.seriesSortKey) { row in
                TextCell(text: row.seriesText)
            }
            .width(min: 80, ideal: 170)
            TableColumn("Formats", value: \.formatsSortKey) { row in
                FormatsCell(row: row)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Length", value: \.lengthSortKey) { row in
                TextCell(text: row.lengthText)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Added", value: \.dateAddedSortKey) { row in
                Text(row.book.dateAdded, format: .dateTime.day().month(.abbreviated).year())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 88, ideal: 100)
            TableColumn("Status", value: \.statusSortKey) { row in
                StatusCell(status: row.book.readStatus)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if !ids.isEmpty {
                BookContextMenu(model: model, ids: ids)
            }
        } primaryAction: { ids in
            // G4: a double-click, or Return.
            model.openOne(of: ids)
        }
        // G8: made again when the rows are a very different list; see `RowsChange`.
        .id(model.rowsVersion)
        .accessibilityIdentifier("books.table")
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

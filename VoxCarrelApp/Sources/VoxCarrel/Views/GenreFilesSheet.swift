import SwiftUI
import VoxCarrelAppCore

/// G14: the preview of "Update files…": the books whose files hold another genre tag
/// than the library would write, with the tag as it is and as it will be. Nothing is
/// written until Update. Everything said is the state's; it closes the sheet itself.
struct GenreFilesSheet: View {
    let update: GenreFilesUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(update.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("genres.files.heading")
                Text(update.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genres.files.note")
            }

            if let empty = update.emptyText {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityIdentifier("genres.files.empty")
            } else {
                // The cells are handed what they show: none reads the model.
                Table(update.rows) {
                    TableColumn(update.columns[0]) { row in
                        GenreFilesBookCell(row: row)
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn(update.columns[1]) { row in
                        GenreFilesTagCell(text: row.tagNow, id: "genres.files.row.\(row.id).now")
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn(update.columns[2]) { row in
                        GenreFilesTagCell(text: row.tagAfter, id: "genres.files.row.\(row.id).after")
                    }
                    .width(min: 120, ideal: 200)
                }
                .frame(height: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .accessibilityIdentifier("genres.files.table")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    update.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("genres.files.cancel")
                Button(update.updateTitle) {
                    Task { await update.update() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!update.canUpdate)
                .accessibilityIdentifier("genres.files.update")
            }
        }
        .padding(20)
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }
}

/// A book's title, and under it how many of its files will be written.
private struct GenreFilesBookCell: View {
    let row: GenreFilesRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.title)
                .accessibilityIdentifier("genres.files.row.\(row.id).title")
            Text(row.filesText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("genres.files.row.\(row.id).files")
        }
    }
}

/// A genre tag, as it is or as it will be.
private struct GenreFilesTagCell: View {
    let text: String
    let id: String

    var body: some View {
        Text(text)
            .lineLimit(2)
            .truncationMode(.tail)
            .help(text)
            .accessibilityIdentifier(id)
    }
}

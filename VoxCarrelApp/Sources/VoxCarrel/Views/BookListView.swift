import SwiftUI
import VoxCarrelAppCore

/// Placeholder until Task 9: the books as a plain list of titles and authors.
struct BookListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.rows, selection: Binding(get: { model.selection }, set: { model.select($0) })) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(row.book.title)
                    .lineLimit(1)
                Text(row.book.authors.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityIdentifier("books.row.\(row.id)")
        }
        .accessibilityIdentifier("books.list")
    }
}

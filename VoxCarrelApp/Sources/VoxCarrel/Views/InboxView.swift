import SwiftUI
import VoxCarrelAppCore

/// The Inbox: the books that have arrived in the watch folders and wait to be reviewed.
/// Above the table, Review and Dismiss, and anything there is to say about the folders.
/// The rows are the model's, already in order.
struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            InboxHeader(model: model)
            Divider()
            if model.inboxRows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing waiting", systemImage: SidebarItem.inbox.symbol)
                } description: {
                    Text("Books that arrive in your watch folders appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("inbox.empty")
            } else {
                InboxTable(model: model)
            }
        }
    }
}

/// Review and Dismiss, and under them a line for each thing that is wrong.
private struct InboxHeader: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(model.reviewInboxTitle) {
                    Task { await model.reviewInbox() }
                }
                .disabled(!model.canReviewInbox)
                .help("Review the selected books, or all of them, before they are imported")
                .accessibilityIdentifier("inbox.review")
                Button("Dismiss") {
                    Task { await model.dismissInbox() }
                }
                .disabled(!model.canDismissInbox)
                .help("Take the selected books out of the Inbox. Their files are left where they are.")
                .accessibilityIdentifier("inbox.dismiss")
                Spacer(minLength: 0)
            }
            ForEach(model.inboxNotices, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inbox.notice")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The arrivals as a table. Its cells are given plain values: a cell may be drawn once
/// more after its table has gone, with no model in its environment.
private struct InboxTable: View {
    let model: AppModel

    var body: some View {
        Table(model.inboxRows, selection: selection) {
            TableColumn("Title") { row in
                InboxTextCell(text: row.title, isPrimary: true)
                    .accessibilityIdentifier("inbox.row.\(row.id)")
            }
            .width(min: 120, ideal: 260)
            TableColumn("Author") { row in
                InboxTextCell(text: row.author)
            }
            .width(min: 70, ideal: 140, max: 240)
            TableColumn("Kind") { row in
                InboxTextCell(text: row.kind)
            }
            .width(min: 60, ideal: 90, max: 150)
            TableColumn("Files") { row in
                InboxTextCell(text: row.files)
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 56, max: 70)
            TableColumn("Folder") { row in
                InboxTextCell(text: row.folder)
            }
            .width(min: 60, ideal: 110, max: 200)
            TableColumn("Arrived") { row in
                InboxArrivedCell(date: row.arrived)
            }
            .width(min: 60, ideal: 66, max: 80)
        }
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            // A double-click, or Return.
            Task { await model.reviewInbox(opening: ids) }
        }
        .accessibilityIdentifier("inbox.table")
    }

    private var selection: Binding<Set<String>> {
        let model = model
        return Binding(get: { model.inboxSelection }, set: { model.inboxSelection = $0 })
    }
}

private struct InboxTextCell: View {
    let text: String
    var isPrimary = false

    var body: some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(isPrimary ? .primary : .secondary)
            .help(text)
    }
}

/// A short date; the whole date is in the tooltip.
private struct InboxArrivedCell: View {
    let date: Date

    var body: some View {
        let full = AddedDateText.full(date)
        Text(AddedDateText.compact(date))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .help(full)
            .accessibilityLabel(full)
    }
}

import SwiftUI
import VoxCarrelAppCore

/// Placeholder until Task 10: says what is selected.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.inspecting {
            case .nothing:
                Text("No book selected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inspector.empty")
            case .one(let detail, _):
                Text(detail.row.book.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("inspector.title")
            case .many(let draft):
                Text("\(draft.books.count) books selected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inspector.selectionCount")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

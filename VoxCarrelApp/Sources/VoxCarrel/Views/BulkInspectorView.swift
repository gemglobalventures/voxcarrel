import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// I8: several books: the fields that can be set on all of them at once.
struct BulkInspectorView: View {
    @Environment(AppModel.self) private var model
    let draft: BulkDraft

    var body: some View {
        // The same pane as one book's inspector. Nothing in it may ask for more width
        // than the column at its narrowest gives: 240 points less the padding.
        InspectorPane {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inspector.selectionCount")
                Text("A field you change is set on every selected book. Tags are added to the tags each book has.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InspectorSection("Details") {
                ForEach(BulkField.allCases, id: \.self) { field in
                    InspectorField(
                        field.title, hint: field.takesSeveral ? InspectorMetrics.semicolonHint : nil
                    ) {
                        TextField(text: text(field), prompt: Text(draft.placeholder(for: field))) {
                            Text(field.title)
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(field.title)
                        .accessibilityIdentifier("inspector.bulk.\(field.rawValue)")
                        if let note = draft.note(for: field) {
                            Label(note, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("inspector.bulk.\(field.rawValue).note")
                        }
                    }
                }
            }

            InspectorSection("Reading") {
                InspectorField("Mark all as") {
                    // Side by side where the three fit whole (they need 215 points);
                    // one under another in a narrower column, never cut short.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { readStatusButtons }
                        VStack(alignment: .leading, spacing: 6) { readStatusButtons }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var readStatusButtons: some View {
        ForEach(ReadStatus.allCases, id: \.self) { status in
            Button(status.title) {
                Task { await model.setReadStatus(status, for: model.selection) }
            }
            .fixedSize()
            .accessibilityIdentifier("inspector.bulk.readStatus.\(status.rawValue)")
        }
    }

    /// A field's text, read from the draft as it is now and written through the model.
    private func text(_ field: BulkField) -> Binding<String> {
        let model = model
        let shown = draft
        return Binding(
            get: {
                if case .many(let current) = model.inspecting { return current.text(for: field) }
                return shown.text(for: field)
            },
            set: { newValue in
                model.setBulkText(newValue, for: field)
            })
    }
}

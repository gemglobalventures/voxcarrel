import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// I8: several books: the fields that can be set on all of them at once.
struct BulkInspectorView: View {
    @Environment(AppModel.self) private var model
    let draft: BulkDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.headline)
                        .font(.headline)
                        .accessibilityIdentifier("inspector.selectionCount")
                    Text("A field you change is set on every selected book. Tags are added to the tags each book has.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                                    .accessibilityIdentifier("inspector.bulk.\(field.rawValue).note")
                            }
                        }
                    }
                }

                InspectorSection("Reading") {
                    InspectorField("Mark all as") {
                        HStack(spacing: 6) {
                            ForEach(ReadStatus.allCases, id: \.self) { status in
                                Button(status.title) {
                                    Task { await model.setReadStatus(status, for: model.selection) }
                                }
                                .accessibilityIdentifier("inspector.bulk.readStatus.\(status.rawValue)")
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(InspectorMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InspectorActions()
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

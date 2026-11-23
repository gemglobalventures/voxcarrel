import SwiftUI
import VoxCarrelAppCore

/// Settings ▸ General: how the library's folders are arranged. A picker of the presets
/// and Custom, the pattern (typed only for Custom), where it would file a book, what is
/// wrong with it when something is, and the button that previews the change.
///
/// Nothing here changes the library: Change Layout… opens the preview, on the library
/// window, and the change is made from there.
struct FolderLayoutSettings: View {
    let model: AppModel

    var body: some View {
        Section {
            Picker("Layout", selection: choice) {
                ForEach(model.layoutChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .disabled(!model.isLibraryOpen)
            .accessibilityIdentifier("settings.layout.choice")

            LabeledContent("Pattern") {
                TextField("Pattern", text: draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .disabled(!model.isLibraryOpen || !model.layoutIsCustom)
                    .accessibilityLabel("Pattern")
                    .accessibilityIdentifier("settings.layout.pattern")
            }

            if let example = model.layoutExampleText {
                LabeledContent("Example") {
                    Text(example)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.layout.example")
                }
            }
            if let problem = model.layoutProblemText {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.layout.problem")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tokens: \(model.layoutTokensText)")
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.layout.tokens")
                Text(model.layoutBracketsText)
                    .accessibilityIdentifier("settings.layout.help")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Change Layout…") {
                    Task { await model.previewLayoutChange() }
                }
                .disabled(!model.canChangeLayout)
                .accessibilityIdentifier("settings.layout.change")
            }
        } header: {
            Text("Folder Layout")
        }
    }

    private var choice: Binding<String> {
        let model = model
        return Binding(get: { model.layoutChoiceId }, set: { model.chooseLayout($0) })
    }

    private var draft: Binding<String> {
        let model = model
        return Binding(get: { model.layoutDraftText }, set: { model.layoutDraftText = $0 })
    }
}

/// What changing the folder layout would do, before it is done: how many books move,
/// a few of the moves, the books that stay and why. The model closes it, when the
/// change is made or cancelled.
struct LayoutPreviewSheet: View {
    let model: AppModel
    let preview: LayoutPreview
    @State private var showsStaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("layoutPreview.heading")
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("layoutPreview.line.\(index)")
                }
            }

            if !preview.examples.isEmpty {
                Table(preview.examples) {
                    TableColumn("Title") { example in
                        LayoutPreviewCell(text: example.title, id: "layoutPreview.example.\(example.id).title")
                    }
                    .width(min: 100, ideal: 150)
                    TableColumn("From") { example in
                        LayoutPreviewCell(text: example.from, id: "layoutPreview.example.\(example.id).from")
                    }
                    TableColumn("To") { example in
                        LayoutPreviewCell(text: example.to, id: "layoutPreview.example.\(example.id).to")
                    }
                }
                // Tall enough for the examples there are, of which there are at most eight.
                .frame(height: CGFloat(preview.examples.count) * 26 + 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .accessibilityIdentifier("layoutPreview.examples")
            }

            if !preview.staying.isEmpty {
                DisclosureGroup(isExpanded: $showsStaying) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(preview.staying) { row in
                                LayoutStayRowView(row: row)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 160)
                } label: {
                    Text("Books that stay where they are")
                        .accessibilityIdentifier("layoutPreview.staying.label")
                }
                .accessibilityIdentifier("layoutPreview.staying")
            }

            Text(model.layoutPreviewNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("layoutPreview.note")

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelLayoutChange()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("layoutPreview.cancel")
                Button("Change Layout") {
                    Task { await model.applyLayoutChange() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.canApply)
                .accessibilityIdentifier("layoutPreview.apply")
            }
        }
        .padding(20)
        .frame(width: 680)
        .interactiveDismissDisabled()
    }
}

/// One cell of the table of examples. Given plain values: it is a table's cell.
private struct LayoutPreviewCell: View {
    let text: String
    let id: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
            .accessibilityIdentifier(id)
    }
}

/// One book that stays, and why. Given plain values: it is a row of a list.
private struct LayoutStayRowView: View {
    let row: LayoutStayRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(row.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("layoutPreview.staying.\(row.id)")
    }
}

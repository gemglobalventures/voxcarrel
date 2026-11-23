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
            if let unreadable = model.layoutUnreadableText {
                Label(unreadable, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.layout.unreadable")
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
///
/// Every part has a height of its own, so the sheet is as tall as what it shows from
/// the start: the books that stay are listed at once, in a list that scrolls when
/// there are more than a few.
struct LayoutPreviewSheet: View {
    let model: AppModel
    let preview: LayoutPreview

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
                    // The title is the least of it: the two paths share all the rest.
                    .width(min: 90, ideal: 150, max: 220)
                    TableColumn("From") { example in
                        LayoutPreviewCell(
                            text: example.from, id: "layoutPreview.example.\(example.id).from", keepsEnd: true)
                    }
                    .width(min: 220)
                    TableColumn("To") { example in
                        LayoutPreviewCell(
                            text: example.to, id: "layoutPreview.example.\(example.id).to", keepsEnd: true)
                    }
                    .width(min: 220)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Books that stay where they are")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("layoutPreview.staying.label")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(preview.staying) { row in
                                LayoutStayRowView(row: row)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    // A height of its own, never one squeezed out of what is left: room
                    // for each row up to four, and the rest are scrolled to.
                    .frame(height: CGFloat(min(preview.staying.count, 4)) * 42 + 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    }
                    .accessibilityIdentifier("layoutPreview.staying")
                }
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
        .frame(width: 1000)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }
}

/// One cell of the table of examples. Given plain values: it is a table's cell.
///
/// A folder that does not fit keeps its end: the book's own folder and the levels just
/// above it. The whole of it is in the tooltip.
private struct LayoutPreviewCell: View {
    let text: String
    let id: String
    var keepsEnd = false

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(keepsEnd ? .head : .tail)
            .frame(maxWidth: .infinity, alignment: .leading)
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

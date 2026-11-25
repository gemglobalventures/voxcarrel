import SwiftUI
import VoxCarrelAppCore

// The highlights of one book: all of them, narrowed by a filter, with the commands on
// each and the form that adds one. Everything said and every "can" is the session's; it
// closes the sheet itself.

/// One highlight's words: the passage as a quotation, the note beneath, and where and
/// when in small text. Handed what it shows; the inspector and the sheet both use it.
struct HighlightBody: View {
    let row: HighlightRow
    /// The most lines of the passage shown; nil for all of it.
    var lineLimit: Int?
    /// Whether the words can be selected, and whether the source is named.
    var isInSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let mark = row.markText {
                Text(mark)
                    .italic()
                    .foregroundStyle(.secondary)
            } else if !row.text.isEmpty {
                Text(row.text)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(Selectable(isOn: isInSheet))
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(.tertiary)
                            .frame(width: 3)
                    }
            }
            if let note = row.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(Selectable(isOn: isInSheet))
            }
            if let caption = isInSheet ? row.sourcedCaptionText : row.captionText {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lets text be selected, or leaves it as it is.
private struct Selectable: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

struct HighlightsSheet: View {
    let session: HighlightsSession

    var body: some View {
        @Bindable var session = session

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlights")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("highlights.sheet.heading")
                    Text(session.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("highlights.sheet.title")
                }
                Spacer(minLength: 0)
                Text(session.countText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("highlights.sheet.count")
            }

            TextField("Filter", text: $session.filterText, prompt: Text("Filter highlights"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Filter highlights")
                .accessibilityIdentifier("highlights.sheet.filter")

            list

            if session.isAdding {
                addForm
            }

            HStack(spacing: 8) {
                if !session.isAdding {
                    Button("Add Highlight…") {
                        session.beginAdd()
                    }
                    .accessibilityIdentifier("highlights.sheet.beginAdd")
                }
                Spacer(minLength: 0)
                Button("Done") {
                    session.close()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("highlights.sheet.done")
            }
        }
        .padding(20)
        .frame(width: 600)
        .interactiveDismissDisabled()
        .confirmationDialog(
            session.deleteTitle,
            isPresented: Binding(get: { session.deleting != nil }, set: { if !$0 { session.cancelDelete() } })
        ) {
            Button("Delete", role: .destructive) {
                Task { await session.confirmDelete() }
            }
            .accessibilityIdentifier("highlights.sheet.delete.confirm")
            Button("Cancel", role: .cancel) {
                session.cancelDelete()
            }
        } message: {
            Text(session.deleteMessage ?? "")
        }
    }

    // MARK: The list

    @ViewBuilder private var list: some View {
        let session = session
        Group {
            if let empty = session.emptyText {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("highlights.sheet.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.rows) { row in
                            // Handed what it shows and what its commands do.
                            HighlightSheetRow(
                                row: row, canCopy: session.canCopy(row),
                                isEditing: session.editing?.id == row.id,
                                noteDraft: Binding(get: { session.noteDraft }, set: { session.noteDraft = $0 }),
                                copy: { session.copy(row) }, open: { session.open(row) },
                                editNote: { session.editNote(row) }, cancelNote: { session.cancelEditNote() },
                                saveNote: { Task { await session.saveNote() } }, delete: { session.delete(row) })
                            Divider()
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(height: 340)
        .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityIdentifier("highlights.sheet.list")
    }

    // MARK: Adding

    @ViewBuilder private var addForm: some View {
        @Bindable var session = session

        VStack(alignment: .leading, spacing: 6) {
            Text("New highlight")
                .font(.subheadline.weight(.semibold))
            TextField("Passage", text: $session.newText, prompt: Text("The passage"), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Passage")
                .accessibilityIdentifier("highlights.sheet.add.text")
            TextField("Note", text: $session.newNote, prompt: Text("A note of your own (optional)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Note")
                .accessibilityIdentifier("highlights.sheet.add.note")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    session.cancelAdd()
                }
                .accessibilityIdentifier("highlights.sheet.add.cancel")
                Button("Add") {
                    Task { await session.add() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canAdd)
                .accessibilityIdentifier("highlights.sheet.add.confirm")
            }
        }
    }
}

/// One highlight of the sheet's list, with its commands; and, while its note is being
/// written, the field for it.
private struct HighlightSheetRow: View {
    let row: HighlightRow
    let canCopy: Bool
    let isEditing: Bool
    let noteDraft: Binding<String>
    let copy: () -> Void
    let open: () -> Void
    let editNote: () -> Void
    let cancelNote: () -> Void
    let saveNote: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                HighlightBody(row: row, isInSheet: true)
                Menu {
                    Button("Copy", action: copy)
                        .disabled(!canCopy)
                        .accessibilityIdentifier("highlights.sheet.row.copy")
                    if let title = row.openTitle {
                        Button(title, action: open)
                            .accessibilityIdentifier("highlights.sheet.row.open")
                    }
                    Button("Edit Note…", action: editNote)
                        .accessibilityIdentifier("highlights.sheet.row.editNote")
                    Divider()
                    Button("Delete…", role: .destructive, action: delete)
                        .accessibilityIdentifier("highlights.sheet.row.delete")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy, edit the note, or delete")
                .accessibilityLabel("Actions")
                .accessibilityIdentifier("highlights.sheet.row.\(row.id).menu")
            }
            if isEditing {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Note", text: noteDraft, prompt: Text("A note of your own"), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(saveNote)
                        .accessibilityLabel("Note")
                        .accessibilityIdentifier("highlights.sheet.note.field")
                    Button("Cancel", action: cancelNote)
                        .accessibilityIdentifier("highlights.sheet.note.cancel")
                    Button("Save", action: saveNote)
                        .accessibilityIdentifier("highlights.sheet.note.save")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("highlights.sheet.row.\(row.id)")
    }
}

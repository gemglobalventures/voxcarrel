import SwiftUI
import VoxCarrelAppCore

// The editor of a smart shelf: its name, whether a book must meet every condition or
// any one, the conditions, and how many books it would hold now. Everything said and
// every "can" is the editor's; the sheet shows values and passes on what is typed.

/// The sheet. Closed by the model, when the shelf is saved or Cancel is pressed.
struct ShelfEditorSheet: View {
    let editor: ShelfEditor
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("shelf.editor.heading")

            TextField("Name", text: name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onAppear {
                    nameIsFocused = true
                }
                .accessibilityLabel("Name")
                .accessibilityIdentifier("shelf.editor.name")

            HStack(spacing: 8) {
                Text("Match")
                Picker("Match", selection: matchesAll) {
                    ForEach(editor.matchChoices) { choice in
                        Text(choice.title).tag(choice.matchesAll)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("shelf.editor.match")
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(editor.conditions) { row in
                        // Handed the editor and its row: it reads nothing from the environment.
                        ShelfConditionRowView(editor: editor, row: row)
                    }
                    Menu("Add Condition") {
                        ForEach(editor.kinds) { kind in
                            Button(kind.title) {
                                editor.addCondition(kind)
                            }
                            .accessibilityIdentifier("shelf.editor.add.\(kind.rawValue)")
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("shelf.editor.add")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 260)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .accessibilityIdentifier("shelf.editor.conditions")

            HStack(spacing: 8) {
                Text(editor.matchText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("shelf.editor.matchText")
                Spacer(minLength: 8)
                Button("Cancel") {
                    editor.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("shelf.editor.cancel")
                Button("Save") {
                    Task { await editor.save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
                .accessibilityIdentifier("shelf.editor.save")
            }
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }

    private var name: Binding<String> {
        let editor = editor
        return Binding(get: { editor.name }, set: { editor.name = $0 })
    }

    private var matchesAll: Binding<Bool> {
        let editor = editor
        return Binding(get: { editor.matchesAll }, set: { editor.matchesAll = $0 })
    }
}

/// One condition: its kind, its value, and the button that takes it away.
private struct ShelfConditionRowView: View {
    let editor: ShelfEditor
    let row: ShelfConditionRow

    var body: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: kind) {
                ForEach(editor.kinds) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityIdentifier("\(prefix).kind")

            if !row.choices.isEmpty {
                Picker("Value", selection: choice) {
                    ForEach(row.choices) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("\(prefix).choice")
            }
            if row.showsText {
                TextField(row.textPrompt, text: text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(row.textPrompt)
                    .accessibilityIdentifier("\(prefix).text")
                if !row.suggestions.isEmpty {
                    Menu {
                        ForEach(row.suggestions, id: \.self) { name in
                            Button(name) {
                                editor.setText(name, for: row.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose from the library")
                    .accessibilityLabel("Choose from the library")
                    .accessibilityIdentifier("\(prefix).suggestions")
                }
            }
            if row.showsNumber {
                if !row.prefix.isEmpty {
                    Text(row.prefix)
                }
                TextField("", value: number, format: .number.precision(.fractionLength(0...2)).grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel(row.kind.title)
                    .accessibilityIdentifier("\(prefix).number")
                Stepper("", value: number, in: row.numberRange, step: row.numberStep)
                    .labelsHidden()
                    .accessibilityIdentifier("\(prefix).stepper")
                if !row.unit.isEmpty {
                    Text(row.unit)
                }
            }
            Spacer(minLength: 0)
            Button {
                editor.removeCondition(row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this condition")
            .accessibilityLabel("Remove Condition")
            .accessibilityIdentifier("\(prefix).remove")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(prefix)
    }

    /// The start of each control's accessibility identifier.
    private var prefix: String {
        "shelf.editor.condition.\(row.id)"
    }

    // Each binding reads the row it was handed and writes through the editor.

    private var kind: Binding<ShelfConditionKind> {
        let (editor, row) = (editor, row)
        return Binding(get: { row.kind }, set: { editor.setKind($0, for: row.id) })
    }

    private var choice: Binding<String> {
        let (editor, row) = (editor, row)
        return Binding(get: { row.choice }, set: { editor.setChoice($0, for: row.id) })
    }

    private var text: Binding<String> {
        let (editor, row) = (editor, row)
        return Binding(get: { row.text }, set: { editor.setText($0, for: row.id) })
    }

    private var number: Binding<Double> {
        let (editor, row) = (editor, row)
        return Binding(get: { row.number }, set: { editor.setNumber($0, for: row.id) })
    }
}

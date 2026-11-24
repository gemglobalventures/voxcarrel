import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// Manage Genres (G23–G27): the library's genres by group, each with its number of books,
// and Rename, Merge into, Move to and Delete for each. Everything said and every "can"
// is the manager's; each change is made at once and can be undone from here.

/// The sheet. Closed by the model, when Done is pressed.
struct ManageGenresSheet: View {
    let model: AppModel
    let manager: GenreManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(manager.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("genres.manage.heading")

            List {
                ForEach(manager.groups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            // A row of a list: handed the manager, it reads nothing from the environment.
                            GenreManagerRowView(manager: manager, row: row)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 380)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .accessibilityIdentifier("genres.manage.list")

            if let problem = manager.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genres.manage.problem")
            }
            if let note = manager.filesNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genres.manage.filesNote")
            }

            HStack(spacing: 8) {
                Button(manager.resetTitle) {
                    Task { await manager.reset() }
                }
                .disabled(!manager.canReset)
                .accessibilityIdentifier("genres.manage.reset")
                Button(manager.undoTitle) {
                    Task { await manager.undo() }
                }
                .disabled(!manager.canUndo)
                .accessibilityIdentifier("genres.manage.undo")
                if manager.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("genres.manage.spinner")
                }
                Spacer(minLength: 0)
                Button("Done") {
                    model.closeManageGenres()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(manager.isBusy)
                .accessibilityIdentifier("genres.manage.done")
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
        // G24, G26: a merge by renaming, and a delete, are asked about first.
        .confirmationDialog(
            manager.question?.title ?? "", isPresented: isAsking, titleVisibility: .visible
        ) {
            Button(manager.question?.confirmTitle ?? "") {
                Task { await manager.confirmQuestion() }
            }
            .accessibilityIdentifier("genres.manage.question.confirm")
            Button("Cancel", role: .cancel) {
                manager.cancelQuestion()
            }
            .accessibilityIdentifier("genres.manage.question.cancel")
        } message: {
            Text(manager.question?.message ?? "")
        }
    }

    /// The question is closed by its buttons, each of which answers the manager. The
    /// dialog closing is not itself an answer, so setting this does nothing.
    private var isAsking: Binding<Bool> {
        let manager = manager
        return Binding(get: { manager.question != nil }, set: { _ in })
    }
}

/// One genre: its name, or the box it is renamed in; what it was built in as; its
/// number of books; and what can be done with it, in a menu and on a right-click.
private struct GenreManagerRowView: View {
    let manager: GenreManager
    let row: GenreManagerRow
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if manager.renaming == row.name {
                TextField("Name", text: renameText)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($nameIsFocused)
                    .onSubmit {
                        Task { await manager.commitRename() }
                    }
                    .onExitCommand {
                        manager.cancelRename()
                    }
                    .onAppear {
                        nameIsFocused = true
                    }
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("genres.manage.rename.name")
                Button("Rename") {
                    Task { await manager.commitRename() }
                }
                .controlSize(.small)
                .disabled(!manager.canCommitRename)
                .accessibilityIdentifier("genres.manage.rename.commit")
                Button("Cancel") {
                    manager.cancelRename()
                }
                .controlSize(.small)
                .accessibilityIdentifier("genres.manage.rename.cancel")
            } else {
                Text(row.name)
                    .lineLimit(1)
                    .accessibilityIdentifier("genres.manage.genre.\(row.name).name")
                if let note = row.builtInNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("genres.manage.genre.\(row.name).builtIn")
                }
                Spacer(minLength: 8)
                Text(row.countText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityIdentifier("genres.manage.genre.\(row.name).count")
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(manager.isBusy)
                .help("Rename, merge, move or delete")
                .accessibilityLabel("Actions")
                .accessibilityIdentifier("genres.manage.genre.\(row.name).actions")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genres.manage.genre.\(row.name)")
    }

    /// G23: what can be done with the genre.
    @ViewBuilder private var actions: some View {
        let name = row.name
        Button("Rename") {
            manager.beginRename(name)
        }
        .disabled(manager.isBusy)
        .accessibilityIdentifier("genres.manage.action.rename")
        Menu("Merge into") {
            ForEach(manager.mergeTargets(for: name)) { group in
                Section(group.title) {
                    ForEach(group.genres, id: \.self) { other in
                        Button(other) {
                            Task { await manager.merge(name, into: other) }
                        }
                        .accessibilityIdentifier("genres.manage.action.mergeInto.\(other)")
                    }
                }
            }
        }
        .disabled(manager.isBusy)
        .accessibilityIdentifier("genres.manage.action.mergeInto")
        Menu("Move to") {
            ForEach(manager.moveTargets(for: name)) { target in
                Button(target.title) {
                    Task { await manager.move(name, to: target.group) }
                }
                .accessibilityIdentifier("genres.manage.action.moveTo.\(target.group.rawValue)")
            }
        }
        .disabled(manager.isBusy)
        .accessibilityIdentifier("genres.manage.action.moveTo")
        // G26: for the owner's own genres only.
        if row.canDelete {
            Divider()
            Button("Delete…", role: .destructive) {
                manager.requestDelete(name)
            }
            .disabled(manager.isBusy)
            .accessibilityIdentifier("genres.manage.action.delete")
        }
    }

    /// The name box's text, read from the manager as it is now and written to it.
    private var renameText: Binding<String> {
        let manager = manager
        return Binding(get: { manager.renameText }, set: { manager.renameText = $0 })
    }
}

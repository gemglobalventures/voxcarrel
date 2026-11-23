import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// Merge Books (merge books plan, Task 3): the sheet with the entries, the one to keep,
// each file's role, and what the merge will do. Everything said and every "can" is the
// model's; the model closes the sheet.

/// The sheet. Shown with the model's state for it, which changes under it as the merge
/// is planned again for each choice.
struct MergeBooksSheet: View {
    let model: AppModel
    let state: MergeSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Merge Books")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("merge.heading")
                Text("These entries become one book. The entry you keep keeps its details and takes the files of the others.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("merge.intro")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Entries")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("merge.entries.label")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.entries) { row in
                            MergeEntryRowView(row: row, canChange: state.canChange, keep: keep)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                // A height of its own: room for each entry up to four, and the rest are scrolled to.
                .frame(height: CGFloat(min(max(state.entries.count, 1), 4)) * 46 + 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .accessibilityIdentifier("merge.entries")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Files")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("merge.files.label")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.files) { row in
                            MergeFileRowView(row: row, canChange: state.canChange, setRole: setRole)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: CGFloat(min(max(state.files.count, 1), 5)) * 46 + 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .accessibilityIdentifier("merge.files")
            }

            if !state.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.blockers.enumerated()), id: \.offset) { index, blocker in
                        Label(blocker, systemImage: "xmark.octagon")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("merge.blocker.\(index)")
                    }
                }
            }

            Label(state.summary, systemImage: state.willNeedAttention ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(state.willNeedAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("merge.summary")

            HStack(spacing: 8) {
                if let busy = state.busyText {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("merge.spinner")
                    Text(busy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("merge.busy")
                }
                Spacer(minLength: 0)
                Button("Cancel") {
                    model.cancelMerge()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!state.canChange)
                .accessibilityIdentifier("merge.cancel")
                Button("Merge") {
                    Task { await model.confirmMerge() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canMerge)
                .accessibilityIdentifier("merge.confirm")
            }
        }
        .padding(20)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }

    private func keep(_ id: Int64) {
        let model = model
        Task { await model.setMergeKeep(id) }
    }

    private func setRole(_ role: FileRole, _ id: Int64) {
        let model = model
        Task { await model.setMergeRole(role, forFile: id) }
    }
}

/// One entry, and the choice to keep it. Given plain values and what to call: it is a
/// row of a list, and reads nothing from the environment.
private struct MergeEntryRowView: View {
    let row: MergeEntryRow
    let canChange: Bool
    let keep: (Int64) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.title)
                    .accessibilityIdentifier("merge.entry.\(row.id).title")
                Text(row.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("merge.entry.\(row.id).contents")
            }
            Spacer(minLength: 8)
            // Radio-style: one entry is kept, and choosing another takes the choice from it.
            Button {
                keep(row.id)
            } label: {
                Label("Keep this one", systemImage: row.isKept ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(row.isKept ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .disabled(!canChange)
            .fixedSize()
            .accessibilityAddTraits(row.isKept ? .isSelected : [])
            .accessibilityIdentifier("merge.entry.\(row.id).keep")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One file, where it comes from, and what it will be to the kept book. Given plain
/// values and what to call: it is a row of a list, and reads nothing from the environment.
private struct MergeFileRowView: View {
    let row: MergeFileRow
    let canChange: Bool
    let setRole: (FileRole, Int64) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.name)
                    .accessibilityIdentifier("merge.file.\(row.id).name")
                Text(row.sourceText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("merge.file.\(row.id).entry")
            }
            Spacer(minLength: 8)
            if row.isChanged {
                Text("Changed")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .help("You gave this file another role than VoxCarrel would")
                    .accessibilityIdentifier("merge.file.\(row.id).changed")
            }
            role
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A menu when the file may take more than one role; otherwise the role in words.
    @ViewBuilder private var role: some View {
        if row.allowedRoles.count > 1 {
            Picker(
                "Role",
                selection: Binding(
                    get: { row.role },
                    set: { role in setRole(role, row.id) })
            ) {
                ForEach(row.allowedRoles, id: \.self) { role in
                    Text(role.title).tag(role)
                }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .disabled(!canChange)
            .help("What this file will be to the book")
            .accessibilityIdentifier("merge.file.\(row.id).role")
        } else {
            Text(row.role.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityIdentifier("merge.file.\(row.id).role")
        }
    }
}

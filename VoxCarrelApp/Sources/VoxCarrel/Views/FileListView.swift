import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// I6: the book's files, each with its role, and what is wrong with any of them.
struct FileListView: View {
    @Environment(AppModel.self) private var model
    let detail: BookDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(detail.files) { file in
                FileItem(file: file)
            }
            if detail.showsRewriteTags {
                Button("Rewrite Tags") {
                    Task { await model.rewriteTags() }
                }
                .help("Try again to write this book's details into its files")
                .accessibilityIdentifier("inspector.rewriteTags")
            }
            if detail.showsRepairLength {
                Button("Repair") {
                    Task { await model.repairLengthHeaders() }
                }
                .help("Rewrite the length header of each file that states the wrong length. Undo puts the files back exactly.")
                .accessibilityIdentifier("inspector.repairLength")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FileItem: View {
    @Environment(AppModel.self) private var model
    let file: FileRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.name)
                .foregroundStyle(file.isMissing ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(file.url.path)
                .accessibilityIdentifier("inspector.file.\(file.id).name")

            HStack(spacing: 6) {
                role
                Spacer(minLength: 4)
                if file.isMissing {
                    Button("Locate…") {
                        Panels.locate(file, for: model)
                    }
                    .help("Choose the file to use in place of the missing one")
                    .accessibilityIdentifier("inspector.file.\(file.id).locate")
                }
                Button {
                    model.reveal(file: file)
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(file.isMissing)
                .help("Reveal in Finder")
                .accessibilityIdentifier("inspector.file.\(file.id).reveal")
            }
            .controlSize(.small)

            if file.isMissing {
                Text("This file is missing.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("inspector.file.\(file.id).missing")
            }
            if let problem = file.file.writeProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("inspector.file.\(file.id).writeProblem")
            }
            if let problem = file.lengthProblemText {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("inspector.file.\(file.id).lengthProblem")
            }
            if let note = file.lengthUnmeasuredText {
                Label(note, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("inspector.file.\(file.id).lengthUnmeasured")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A menu when the file may take more than one role; otherwise the role in words.
    @ViewBuilder private var role: some View {
        if file.allowedRoles.count > 1 {
            Picker(
                "Role",
                selection: Binding(
                    get: { file.file.role },
                    set: { role in
                        Task { await model.setRole(role, forFile: file.id) }
                    })
            ) {
                ForEach(file.allowedRoles, id: \.self) { role in
                    Text(role.title).tag(role)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("What this file is to the book")
            .accessibilityIdentifier("inspector.file.\(file.id).role")
        } else {
            Text(file.file.role.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("inspector.file.\(file.id).role")
        }
    }
}

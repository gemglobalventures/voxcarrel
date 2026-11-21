import SwiftUI
import VoxCarrelAppCore

/// V5: the sheets, alerts and questions the model asks the window to show.
///
/// One sheet at a time, in this order: progress, the import review, a result, and
/// the launch check.
struct Dialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Set a moment after an operation starts, so a short one shows no sheet at all.
    @State private var progressDue = false

    private enum ActiveSheet: Identifiable {
        case progress(String)
        case review(ImportReview)
        case result(ResultSummary)
        case check(LibraryCheckSummary)

        var id: String {
            switch self {
            case .progress: "progress"
            case .review: "review"
            case .result: "result"
            case .check: "check"
            }
        }
    }

    private var sheet: ActiveSheet? {
        if progressDue, let label = model.busyLabel { return .progress(label) }
        if let review = model.review { return .review(review) }
        if let result = model.result { return .result(result) }
        if let check = model.libraryCheckSummary { return .check(check) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .task(id: model.busyLabel != nil) {
                guard model.busyLabel != nil else {
                    progressDue = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { progressDue = true }
            }
            // The model closes each sheet itself; nothing else can.
            .sheet(item: Binding(get: { sheet }, set: { _ in })) { sheet in
                switch sheet {
                case .progress(let label):
                    ProgressSheet(label: label)
                case .review(let review):
                    ImportReviewSheet(review: review)
                        .modifier(Questions(isActive: true))
                case .result(let summary):
                    ResultSheet(summary: summary)
                        .modifier(Questions(isActive: true))
                case .check(let summary):
                    LibraryCheckSheet(summary: summary)
                        .modifier(Questions(isActive: true))
                }
            }
            // While a sheet is up, the sheet shows them.
            .modifier(Questions(isActive: sheet == nil))
    }
}

/// The alert, and the questions in `model.prompt`.
private struct Questions: ViewModifier {
    @Environment(AppModel.self) private var model
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .alert(
                model.alert ?? "",
                isPresented: Binding(
                    get: { isActive && model.alert != nil },
                    set: { shown in
                        if !shown { model.alert = nil }
                    })
            ) {
                Button("OK") { model.alert = nil }
                    .accessibilityIdentifier("alert.ok")
            }
            .confirmationDialog(
                model.prompt?.title ?? "", isPresented: isAsking(unsavedChanges), titleVisibility: .visible
            ) {
                Button("Save") {
                    Task { await model.resolveUnsaved(.save) }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("prompt.unsaved.save")
                Button("Discard", role: .destructive) {
                    Task { await model.resolveUnsaved(.discard) }
                }
                .accessibilityIdentifier("prompt.unsaved.discard")
                Button("Cancel", role: .cancel) {
                    model.prompt = nil
                }
                .accessibilityIdentifier("prompt.unsaved.cancel")
            } message: {
                Text(model.prompt?.message ?? "")
            }
            .confirmationDialog(
                model.prompt?.title ?? "", isPresented: isAsking(removeBooks), titleVisibility: .visible
            ) {
                Button("Move Files to Trash", role: .destructive) {
                    Task { await model.confirmRemove(moveFilesToTrash: true) }
                }
                .accessibilityIdentifier("prompt.remove.trash")
                Button("Remove from Library Only") {
                    Task { await model.confirmRemove(moveFilesToTrash: false) }
                }
                .accessibilityIdentifier("prompt.remove.libraryOnly")
                // Return is Cancel: sending files to the Trash takes a deliberate click.
                Button("Cancel", role: .cancel) {
                    model.prompt = nil
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("prompt.remove.cancel")
            } message: {
                Text(model.prompt?.message ?? "")
            }
            .confirmationDialog(
                model.prompt?.title ?? "", isPresented: isAsking(folderWithFiles != nil),
                titleVisibility: .visible, presenting: folderWithFiles
            ) { folder in
                Button("Use This Folder") {
                    Task { await model.confirmChooseLibrary(folder) }
                }
                .accessibilityIdentifier("prompt.folder.use")
                Button("Cancel", role: .cancel) {
                    model.prompt = nil
                }
                .accessibilityIdentifier("prompt.folder.cancel")
            } message: { _ in
                Text(model.prompt?.message ?? "")
            }
    }

    private var unsavedChanges: Bool {
        model.prompt == .unsavedChanges
    }

    private var removeBooks: Bool {
        if case .removeBooks = model.prompt { true } else { false }
    }

    private var folderWithFiles: URL? {
        if case .chooseFolderWithFiles(let folder, _, _) = model.prompt { folder } else { nil }
    }

    /// A question is closed by its buttons, each of which answers the model. The dialog
    /// closing is not itself an answer, so setting this does nothing.
    private func isAsking(_ asking: Bool) -> Binding<Bool> {
        Binding(get: { isActive && asking }, set: { _ in })
    }
}

/// V5: a spinner and what is being done. It goes when the work is done, not before.
private struct ProgressSheet: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("progress.spinner")
            Text(label)
                .accessibilityIdentifier("progress.label")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 320)
        .interactiveDismissDisabled()
    }
}

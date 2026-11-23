import SwiftUI
import VoxCarrelAppCore

/// V5: the sheets, alerts and questions the model asks the window to show.
///
/// One sheet at a time, in the model's order (`AppModel.windowSheet`): progress, the
/// import review, a result, the launch check, the choice between Audible series, and a
/// lookup: for the inspected book, or to add an Audible book. Which is up is
/// `SheetPresentation`'s to say: a sheet of another kind is shown only when the one that
/// is up has closed, so each has a sheet window of its own, at its own size.
///
/// A lookup is last: it is begun only when none of the others is wanted, and if one
/// arrives while it is open (files opened from the Finder, say) that one is shown, and
/// the lookup comes back as it was when it has been dealt with. A lookup for an entry of
/// an import is not the window's sheet: it is shown over the import sheet (`ImportLookup`).
///
/// The progress sheet's words are the model's `progressSheetLabel`, which is nil while an
/// Audible book is being added: the add sheet shows that itself, and stays up meanwhile.
struct Dialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Set a moment after an operation starts, so a short one shows no sheet at all.
    @State private var progressDue = false
    @State private var sheets = SheetPresentation<WindowSheet>()

    /// The sheet the model wants shown now.
    private var wanted: WindowSheet? {
        model.windowSheet(progressDue: progressDue)
    }

    func body(content: Content) -> some View {
        content
            .task(id: model.progressSheetLabel != nil) {
                guard model.progressSheetLabel != nil else {
                    progressDue = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { progressDue = true }
            }
            .onChange(of: wanted, initial: true) {
                sheets.want(wanted)
            }
            // The model closes each sheet itself; nothing else can.
            .sheet(item: Binding(get: { sheets.presented }, set: { _ in })) {
                sheets.didDismiss(wanted: wanted)
            } content: { presented in
                // What the model has for this sheet now; what it last had, while the sheet closes.
                switch wanted?.id == presented.id ? wanted ?? presented : presented {
                case .progress(let label):
                    ProgressSheet(label: label)
                case .review(let review):
                    ImportReviewSheet(review: review)
                        .modifier(ImportLookup())
                case .result(let summary):
                    ResultSheet(summary: summary)
                        .modifier(Questions(isActive: true))
                case .check(let summary):
                    LibraryCheckSheet(summary: summary)
                        .modifier(Questions(isActive: true))
                case .layoutPreview:
                    EmptyView()
                case .seriesChoice(let choices):
                    SeriesPickerSheet(model: model, choices: choices)
                        .modifier(Questions(isActive: true))
                case .lookup(let lookup):
                    LookupSheet(shown: lookup)
                        .modifier(Questions(isActive: true))
                }
            }
            // While a sheet is up, or about to be, the sheet shows them.
            .modifier(Questions(isActive: sheets.isIdle && wanted == nil))
    }
}

/// V5: on the import sheet: the lookup for one of its entries, as a sheet of its own
/// over it, at its own size. The import sheet is as it was when the lookup closes.
///
/// The alert and the questions are shown by whichever of the two is in front: the
/// lookup while it is up, and the import sheet once the lookup has gone (which is when
/// it is told that a cover could not be downloaded).
private struct ImportLookup: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var sheets = SheetPresentation<Shown>()

    private struct Shown: Identifiable, Equatable {
        let lookup: LookupSession

        var id: String { "lookup" }
    }

    private var wanted: Shown? {
        model.importLookup.map(Shown.init)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: wanted, initial: true) {
                sheets.want(wanted)
            }
            // The model closes the lookup itself; nothing else can.
            .sheet(item: Binding(get: { sheets.presented }, set: { _ in })) {
                sheets.didDismiss(wanted: wanted)
            } content: { presented in
                LookupSheet(shown: presented.lookup)
                    .modifier(Questions(isActive: true))
            }
            .modifier(Questions(isActive: sheets.isIdle && wanted == nil))
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
                // Plan 6, V6: books that have no files have nothing to send to the Trash:
                // the model then names one button only.
                if let title = model.prompt?.removeTrashTitle {
                    Button(title, role: .destructive) {
                        Task { await model.confirmRemove(moveFilesToTrash: true) }
                    }
                    .accessibilityIdentifier("prompt.remove.trash")
                }
                if let title = model.prompt?.removeOnlyTitle {
                    Button(title) {
                        Task { await model.confirmRemove(moveFilesToTrash: false) }
                    }
                    .accessibilityIdentifier("prompt.remove.libraryOnly")
                }
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
/// Work that can be stopped (the model says which) has a Cancel button.
private struct ProgressSheet: View {
    @Environment(AppModel.self) private var model
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("progress.spinner")
            Text(label)
                .monospacedDigit()
                .accessibilityIdentifier("progress.label")
            Spacer(minLength: 0)
            if let title = model.progressCancelTitle {
                Button(title) {
                    model.cancelProgress()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("progress.cancel")
            }
        }
        .padding(20)
        .frame(width: 320)
        .interactiveDismissDisabled()
    }
}

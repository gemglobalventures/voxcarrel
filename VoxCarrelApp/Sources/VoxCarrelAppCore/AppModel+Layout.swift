import Foundation
import VoxCarrelCore

// The folder layout setting and its preview (folder layout plan, Task 4). FL1–FL10.
//
// The library keeps its own folder pattern. Settings shows it as a choice of presets or
// a custom pattern; the pattern field holds a draft, which changes nothing until it has
// been previewed and the preview accepted. The change itself is one operation of the
// library's, which Undo reverses whole.

extension AppModel {
    // MARK: FL1 The choices

    /// FL1: the presets by name, then Custom.
    public var layoutChoices: [LayoutChoice] {
        LayoutText.choices
    }

    /// FL1: the choice that is shown as made: the preset the draft is, unless Custom
    /// was chosen or the draft is no preset. The draft starts as the library's pattern
    /// (FL9), so to begin with this is the library's own layout.
    public var layoutChoiceId: String {
        guard !layoutCustomChosen, let name = (try? FolderPattern(layoutDraft))?.presetName else {
            return LayoutText.customId
        }
        return name
    }

    /// Whether the pattern can be typed: Custom is the choice.
    public var layoutIsCustom: Bool {
        layoutChoiceId == LayoutText.customId
    }

    /// The pattern field. Nothing is changed until the draft is previewed and applied.
    public var layoutDraftText: String {
        get { layoutDraft }
        set { layoutDraft = newValue }
    }

    /// A preset fills the draft with its pattern; Custom keeps what is there, to be typed over.
    public func chooseLayout(_ id: String) {
        guard let choice = layoutChoices.first(where: { $0.id == id }) else { return }
        if choice.id == LayoutText.customId {
            layoutCustomChosen = true
        } else {
            layoutCustomChosen = false
            layoutDraft = choice.patternText
        }
    }

    /// FL9: the setting shows the library's own pattern, whatever was drafted.
    func showLibraryLayout() {
        layoutDraft = libraryPattern.text
        layoutCustomChosen = libraryPattern.presetName == nil
    }

    // MARK: FL2, FL3 What the draft is

    /// FL2: why the draft cannot be used, as one sentence; nil when it can.
    public var layoutProblemText: String? {
        LayoutText.problem(in: layoutDraft)
    }

    /// FL3: where the draft would file a book: the one selected book, else the first
    /// book of the library that is in a series, else a sample of the app's own. A
    /// sentence instead when that book lacks what the draft needs; nil when the draft
    /// cannot be used. Worked out from the book's details: the disk is not looked at.
    public var layoutExampleText: String? {
        LayoutText.example(of: layoutDraft, for: layoutExampleBook)
    }

    private var layoutExampleBook: LayoutSample {
        if case .one(let detail, _) = inspecting {
            // The book as it is saved, and by its files: an audiobook that is only on
            // Audible is no file here.
            return LayoutSample(
                metadata: detail.row.book.metadata,
                hasAudio: detail.row.formats.contains { $0.defaultRole == .audio })
        }
        return layoutSample ?? LayoutText.builtInSample
    }

    /// What a pattern can name a folder after, for the help line.
    public var layoutTokensText: String { LayoutText.tokens }

    /// What square brackets and "|" do, for the help line.
    public var layoutBracketsText: String { LayoutText.bracketsHelp }

    /// What the preview says under its lists.
    public var layoutPreviewNote: String { LayoutText.onlyFoldersMove }

    // MARK: FL4 Whether the layout can be changed

    /// FL8, FL12: whether anything that moves or rewrites the library's files may be
    /// begun: not while a change of layout is being previewed, nor while one that was
    /// interrupted has not been put right.
    var filesCanChange: Bool {
        !layoutChangeIsUnresolved && layoutPreview == nil
    }

    /// Whether a file's role can be changed or a missing file located now.
    public var canChangeFiles: Bool {
        isLibraryOpen && busyLabel == nil && filesCanChange
    }

    /// FL4: whether the draft can be previewed: a library is open, nothing is running,
    /// no question, sheet or unsaved edit is in the way, and the draft is a usable
    /// pattern other than the library's own.
    public var canChangeLayout: Bool {
        guard isLibraryOpen, busyLabel == nil, storedPrompt == nil, filesCanChange, review == nil, result == nil,
              libraryCheck == nil, seriesChoice == nil, lookup == nil, !hasUnsavedChanges,
              let pattern = try? FolderPattern(layoutDraft)
        else { return false }
        return pattern != libraryPattern
    }

    // MARK: FL5–FL7 Previewing and changing

    /// FL5: works out what changing to the draft would do and opens the preview.
    /// Nothing is changed. An operation, since a large library takes a moment to plan.
    /// Does nothing unless `canChangeLayout`.
    public func previewLayoutChange() async {
        guard canChangeLayout, let pattern = try? FolderPattern(layoutDraft),
              let worker = await begin(LayoutText.planningLabel)
        else { return }
        do {
            let plan = try await worker.planLayoutChange(to: pattern)
            layoutPreview = LayoutText.preview(of: plan, changesPattern: pattern != libraryPattern)
        } catch {
            show(error)
        }
        // Planning changes nothing in the library, so there is nothing to read again.
        busyLabel = nil
    }

    /// FL6: makes the change that is previewed, as one operation that Undo reverses.
    /// The preview closes. Books that stayed where they were are told in the result
    /// sheet; if the change could not be made nothing has changed, `alert` says why,
    /// and the draft is still there to preview again.
    public func applyLayoutChange() async {
        guard let preview = layoutPreview, preview.canApply,
              let worker = await begin(LayoutText.changingLabel, overLayoutPreview: true)
        else { return }
        do {
            result = LayoutText.result(of: try await worker.applyLayoutChange(to: preview.pattern))
        } catch {
            show(error)
        }
        layoutPreview = nil
        // FL9: reading everything again brings the library's pattern, and the setting follows it.
        await finish()
    }

    /// FL7: closes the preview. The draft stays as it was typed.
    public func cancelLayoutChange() {
        guard busyLabel == nil, layoutPreview != nil else { return }
        layoutPreview = nil
        // FL8: files the app was asked to open meanwhile.
        importHeldFiles()
    }
}

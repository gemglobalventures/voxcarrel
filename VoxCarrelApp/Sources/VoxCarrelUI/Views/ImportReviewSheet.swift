import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// X2–X5: the books of an import, to look over and put right before anything moves.
///
/// Every change goes through `model.updateReview`, and an entry is always named by its
/// id. The sheet keeps only which entries are selected, and the text of the two boxes
/// that hold several names while they are typed in.
struct ImportReviewSheet: View {
    @Environment(AppModel.self) private var model
    let review: ImportReview
    @State private var selection: Set<UUID>
    @State private var skippedShown = false

    init(review: ImportReview) {
        self.review = review
        // X2: the first book is selected when the sheet opens.
        _selection = State(initialValue: Set(review.entries.prefix(1).map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                EntryList(review: review, selection: $selection)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 520, maxHeight: .infinity)
                detail
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if !review.tidyingLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(review.tidyingLines, id: \.self) { line in
                        Label(line, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .accessibilityIdentifier("review.tidying")
                Divider()
            }
            if let title = review.skippedTitle {
                SkippedList(title: title, lines: review.skippedLines, isExpanded: $skippedShown)
                Divider()
            }
            BottomBar(review: review)
        }
        .frame(
            minWidth: 760, idealWidth: 900, maxWidth: .infinity,
            minHeight: 440, idealHeight: 600, maxHeight: .infinity
        )
        .presentationSizing(.fitted)
        .interactiveDismissDisabled()
    }

    /// One entry's details, the offer to merge several, or a hint.
    @ViewBuilder private var detail: some View {
        switch review.selected(selection) {
        case .none:
            Text("Select a book to see its details")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review.detail.empty")
        case .one(let entry):
            EntryDetail(review: review, entry: entry)
                // Another book is another form, with its own text in the name boxes.
                .id(entry.id)
        case .many(let headline):
            // X3
            VStack(spacing: 12) {
                Text(headline)
                    .font(.title3)
                    .accessibilityIdentifier("review.selected.headline")
                Button("Merge into One Book") {
                    let ids = selection
                    model.updateReview { $0.merge(ids) }
                }
                .disabled(!review.canMerge(selection))
                .accessibilityIdentifier("review.merge")
                Text("Their files become one book, with the details of the first of them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }
}

// MARK: - The list

private struct EntryList: View {
    @Environment(AppModel.self) private var model
    let review: ImportReview
    @Binding var selection: Set<UUID>

    var body: some View {
        // A row in the list does not read the model itself: it is handed what it does.
        let model = model
        VStack(spacing: 0) {
            if review.offersFilter {
                HStack(spacing: 8) {
                    Picker("Show", selection: Binding(
                        get: { review.filter },
                        set: { chosen in model.updateReview { $0.filter = chosen } })) {
                        ForEach(ImportReview.Filter.allCases, id: \.self) { filter in
                            Text(review.title(of: filter)).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("review.filter")
                    Menu {
                        Button("Tick All Shown") { model.updateReview { $0.setIncluded(true) } }
                        Button("Untick All Shown") { model.updateReview { $0.setIncluded(false) } }
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Tick or untick every book shown")
                    .accessibilityIdentifier("review.filter.tickMenu")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
            }
            entryList(model)
        }
    }

    private func entryList(_ model: AppModel) -> some View {
        List(selection: $selection) {
            ForEach(Array(review.shownEntries.enumerated()), id: \.element.id) { index, entry in
                EntryRow(
                    entry: entry, status: review.status(of: entry.id), question: review.question(of: entry.id),
                    index: index, isSelected: selection.contains(entry.id),
                    setIncluded: { included in
                        model.updateReview { $0.update(entry.id) { $0.included = included } }
                    })
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("review.entries")
    }
}

/// X2: the checkbox, the cover, and what the book is.
private struct EntryRow: View {
    let entry: ImportReview.Entry
    let status: ImportReview.Status?
    /// IH6: what there is to check about the book; nil when nothing.
    let question: String?
    let index: Int
    /// Whether the list shows this row as selected, on its highlight.
    let isSelected: Bool
    /// Ticks or unticks the book for import.
    let setIncluded: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Import \(entry.titleText)", isOn: included)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Import this book")
                .accessibilityIdentifier("review.entry.\(index).included")

            HStack(spacing: 8) {
                EntryCover(entry: entry, side: 44, cornerRadius: 2)
                    .frame(width: 30, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.titleText)
                            .lineLimit(1)
                            .accessibilityIdentifier("review.entry.\(index).title")
                        if let question {
                            // IH6: the caution mark says what, when pointed at.
                            Image(systemName: ImportReview.questionSymbol)
                                .font(.caption)
                                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                                .help(question)
                                .accessibilityLabel(question)
                                .accessibilityIdentifier("review.entry.\(index).question")
                        }
                    }
                    Text(entry.authorsText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("review.entry.\(index).authors")
                    HStack(spacing: 4) {
                        if entry.hasAudio {
                            Image(systemName: FileRole.audio.symbol)
                                .accessibilityLabel(FileRole.audio.title)
                        }
                        if entry.hasEbook {
                            Image(systemName: FileRole.ebook.symbol)
                                .accessibilityLabel(FileRole.ebook.title)
                        }
                        Text(entry.filesText)
                            .lineLimit(1)
                            .accessibilityIdentifier("review.entry.\(index).files")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let status {
                        // Orange and red cannot be read on the highlight of a selected row:
                        // there the words take the row's own text colour, and the symbol
                        // says which kind of status it is.
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Image(systemName: status.symbol)
                                .accessibilityHidden(true)
                            Text(status.text)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("review.entry.\(index).status")
                        }
                        .font(.caption)
                        .foregroundStyle(statusStyle(status))
                    }
                }
            }
            // A book that is left out is shown fainter.
            .opacity(entry.included ? 1 : 0.5)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusStyle(_ status: ImportReview.Status) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        return status.isBlocking ? AnyShapeStyle(.red) : AnyShapeStyle(.orange)
    }

    private var included: Binding<Bool> {
        Binding(get: { entry.included }, set: setIncluded)
    }
}

/// The cover found in an entry's files, or the placeholder of its title.
private struct EntryCover: View {
    let entry: ImportReview.Entry
    /// The longest side it is shown at.
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if let cover = entry.cover {
            DataCover(data: cover.data, maxSide: side, cornerRadius: cornerRadius)
                .equatable()
                .accessibilityHidden(true)
        } else {
            CoverPlaceholder(
                initials: entry.coverInitials, hue: entry.placeholderHue, side: side, cornerRadius: cornerRadius,
                wording: PlaceholderCover.wording(
                    title: entry.candidate.metadata.title, authors: entry.candidate.metadata.authors))
        }
    }
}

// MARK: - One entry

/// X2: the selected book's details, where it will go, and its files.
private struct EntryDetail: View {
    private static let coverSide: CGFloat = 132

    @Environment(AppModel.self) private var model
    let review: ImportReview
    let entry: ImportReview.Entry
    /// The boxes that hold several names keep their own text while it is typed, so
    /// that "A; " is not tidied away under the user's hands. The names go to the model
    /// at every keystroke.
    @State private var authors: String
    @State private var narrators: String

    init(review: ImportReview, entry: ImportReview.Entry) {
        self.review = review
        self.entry = entry
        _authors = State(initialValue: review.text(for: .authors, of: entry.id))
        _narrators = State(initialValue: review.text(for: .narrators, of: entry.id))
    }

    var body: some View {
        // The genre field is handed the model's commands: it does not read the model.
        let model = model
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                HStack(alignment: .top, spacing: 16) {
                    EntryCover(entry: entry, side: Self.coverSide, cornerRadius: 5)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .frame(width: Self.coverSide * CoverPlaceholder.aspectRatio, height: Self.coverSide)

                    VStack(alignment: .leading, spacing: InspectorMetrics.fieldSpacing) {
                        InspectorField("Title") {
                            textField("Title", text: text(.title), id: "title")
                        }
                        InspectorField("Authors", hint: InspectorMetrics.semicolonHint) {
                            textField("Authors", text: $authors, id: "authors")
                        }
                        // IH4: what of these was read from the file's name.
                        if let note = review.guessNote(of: entry.id) {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("review.guessNote")
                        }
                        if let copies = review.copiesText(of: entry.id) {
                            Text(copies)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("review.copies")
                        }
                        HStack(spacing: 8) {
                            // V1
                            Button("Look Up…") {
                                model.beginLookup(forEntry: entry.id)
                            }
                            .disabled(!model.canLookUpEntry(entry.id))
                            .help(model.lookUpHelp(forEntry: entry.id))
                            .accessibilityIdentifier("review.lookup")
                            // Merge books plan: for files that had the two in each other's place.
                            Button("Swap Title and Author") {
                                model.swapReviewTitleAndAuthor(for: entry.id)
                                // The authors box keeps its own text: it takes the entry's again.
                                authors = (model.review ?? review).text(for: .authors, of: entry.id)
                            }
                            // IH5: it stands out while the two may be in each other's place.
                            .modifier(StandingOut(isOn: review.offersProminentSwap(of: entry.id)))
                            .disabled(!model.canSwapReviewTitleAndAuthor(for: entry.id))
                            .help("Exchange the title and the first author")
                            .accessibilityIdentifier("review.swapTitleAndAuthor")
                        }
                        // IH4: an Audible ID that was read from the file's name.
                        if let audibleID = review.guessedAudibleIDText(of: entry.id),
                           let note = review.audibleIDNote(of: entry.id) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(audibleID)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("review.audibleID")
                                Text(note)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("review.audibleIDNote")
                            }
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: InspectorMetrics.fieldSpacing) {
                    HStack(alignment: .top, spacing: 8) {
                        InspectorField("Series") {
                            textField("Series", text: text(.series), id: "series")
                                .disabled(review.isLocked(.series, of: entry.id))
                        }
                        InspectorField("Number") {
                            textField("Number", text: text(.seriesNumber), id: "seriesNumber")
                                .disabled(review.isLocked(.seriesNumber, of: entry.id))
                        }
                        .frame(width: 72)
                    }
                    if entry.hasAudio {
                        InspectorField("Narrators", hint: InspectorMetrics.semicolonHint) {
                            textField("Narrators", text: $narrators, id: "narrators")
                                .disabled(review.isLocked(.narrators, of: entry.id))
                        }
                    }
                    // G19: the genres the file's tag came to, to put right before the import.
                    InspectorField("Genres") {
                        GenreChipsField(
                            chips: entry.genres.map { GenreChipsField.Chip(name: $0) },
                            identifier: "import.entry.\(entry.id).genres",
                            suggestions: { model.genreSuggestions(for: $0, excluding: entry.genres) },
                            add: { model.addImportGenre($0, to: entry.id) },
                            remove: { model.removeImportGenre($0, from: entry.id) },
                            move: { model.moveImportGenre(from: $0, to: $1, in: entry.id) },
                            create: { name, group in
                                Task { await model.createImportGenre(name, group: group, for: entry.id) }
                            })
                    }
                    if let note = review.keptDetailsNote(of: entry.id) {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("review.keptDetails")
                    }
                }

                InspectorSection("Where It Goes") {
                    if let offer = entry.existingMatchText {
                        Toggle(isOn: addToExisting) {
                            // IH1: a possible match is a question, and a long one.
                            Text(offer)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("review.addToExisting")
                    }
                    if entry.offersReplaceAudio {
                        Toggle(isOn: replacesAudio) {
                            Text(ImportReview.replaceAudioOffer)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("review.replaceAudio")
                        if let text = review.replaceAudioText(of: entry.id) {
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("review.replaceAudioText")
                        }
                    }
                    if entry.offersEdition {
                        Toggle(isOn: asEdition) {
                            Text(ImportReview.editionOffer)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("review.asEdition")
                    }
                    Label(review.destinationText(of: entry.id), systemImage: "folder")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("review.destination")
                }

                InspectorSection("Files") {
                    ForEach(Array(review.files(of: entry.id).enumerated()), id: \.element.id) { index, file in
                        FileLineView(entryId: entry.id, file: file, index: index)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: authors) { _, typed in
            setText(typed, for: .authors)
        }
        .onChange(of: narrators) { _, typed in
            setText(typed, for: .narrators)
        }
        // A lookup may have put other names into the entry: the boxes that keep their
        // own text take the entry's again when it closes.
        .onChange(of: model.importLookup == nil) { _, closed in
            guard closed else { return }
            let now = model.review ?? review
            authors = now.text(for: .authors, of: entry.id)
            narrators = now.text(for: .narrators, of: entry.id)
        }
    }

    private func setText(_ typed: String, for field: ImportReview.Field) {
        let id = entry.id
        model.updateReview { $0.setText(typed, for: field, of: id) }
    }

    /// A field's text, read from the review as it is now and written through the model.
    private func text(_ field: ImportReview.Field) -> Binding<String> {
        let model = model
        let shown = review
        let id = entry.id
        return Binding(
            get: { (model.review ?? shown).text(for: field, of: id) },
            set: { typed in
                model.updateReview { $0.setText(typed, for: field, of: id) }
            })
    }

    private var replacesAudio: Binding<Bool> {
        let model = model
        let id = entry.id
        return Binding(
            get: { entry.replacesAudio },
            set: { on in model.updateReview { $0.setReplacesAudio(on, for: id) } })
    }

    private var asEdition: Binding<Bool> {
        let model = model
        let id = entry.id
        return Binding(
            get: { entry.asEdition },
            set: { on in model.updateReview { $0.setAsEdition(on, for: id) } })
    }

    private var addToExisting: Binding<Bool> {
        let model = model
        let id = entry.id
        return Binding(
            get: { entry.addToExisting },
            set: { add in
                // IH2: the owner's own choice for the book that is offered.
                model.updateReview { $0.setAddToExisting(add, for: id) }
            })
    }

    private func textField(_ title: String, text: Binding<String>, id: String) -> some View {
        TextField(text: text, prompt: Text("")) {
            Text(title)
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(title)
        .accessibilityIdentifier("review.\(id)")
    }
}

/// IH5: a button that stands out, or stands as the others do.
private struct StandingOut: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        } else {
            content
        }
    }
}

/// X2: one file: its name, what it is to the book, and the way out into a book of its own.
private struct FileLineView: View {
    @Environment(AppModel.self) private var model
    let entryId: UUID
    private static let detachTitle = "Move to Its Own Book"

    let file: ImportReview.FileLine
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.role.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            // The name has the room the rest leave; the role and the button keep their own.
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(file.url.path)
                .accessibilityIdentifier("review.file.\(index).name")
            role
            Button {
                let (id, url) = (entryId, file.url)
                model.updateReview { $0.detach(file: url, from: id) }
            } label: {
                Label(Self.detachTitle, systemImage: "arrow.up.right.square")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .fixedSize()
            .disabled(!file.canDetach)
            .help(Self.detachTitle)
            .accessibilityLabel(Self.detachTitle)
            .accessibilityIdentifier("review.file.\(index).detach")
        }
        .controlSize(.small)
    }

    /// A menu when the file may take more than one role; otherwise the role in words.
    @ViewBuilder private var role: some View {
        if file.allowedRoles.count > 1 {
            Picker(
                "Role",
                selection: Binding(
                    get: { file.role },
                    set: { role in
                        let (id, url) = (entryId, file.url)
                        model.updateReview { $0.setRole(role, file: url, in: id) }
                    })
            ) {
                ForEach(file.allowedRoles, id: \.self) { role in
                    Text(role.title).tag(role)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("What this file is to the book")
            .accessibilityIdentifier("review.file.\(index).role")
        } else {
            Text(file.role.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityIdentifier("review.file.\(index).role")
        }
    }
}

// MARK: - The bottom

/// X4: what was dropped or chosen and cannot be imported.
private struct SkippedList: View {
    let title: String
    let lines: [ImportReview.SkippedLine]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VoxCarrel cannot import these. They were left as they are.")
                        .foregroundStyle(.secondary)
                    ForEach(lines) { line in
                        Text(line.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(line.path)
                            .accessibilityIdentifier("review.skipped.\(line.id)")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .frame(maxHeight: 96)
        } label: {
            Text(title)
                .accessibilityIdentifier("review.skipped")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// X4
private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    let review: ImportReview

    var body: some View {
        HStack(spacing: 12) {
            if let note = review.calibreNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review.calibreNote")
            } else if review.offersCopy {
                Toggle("Copy files, leave originals in place", isOn: copy)
                    .toggleStyle(.checkbox)
                    .disabled(review.leavesInPlace)
                    .accessibilityIdentifier("review.copy")
                // WF19: why Copy is ticked for books from the Inbox.
                if let note = review.inboxNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("review.inboxNote")
                }
            } else {
                Text("These files are in the library folder already, so they will be moved into place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review.moveOnly")
            }
            if review.offersInPlace {
                Toggle(ImportReview.leaveInPlaceTitle, isOn: inPlace)
                    .toggleStyle(.checkbox)
                    .help(ImportReview.leaveInPlaceHelp)
                    .accessibilityIdentifier("review.inPlace")
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(review.countText)
                    .lineLimit(1)
                    .accessibilityIdentifier("review.count")
                // A question never stops the import: it is only said.
                if let questions = review.questionsText {
                    Text(questions)
                        .font(.callout)
                        .lineLimit(1)
                        .accessibilityIdentifier("review.questions")
                }
            }
            .foregroundStyle(.secondary)
            Button("Cancel") {
                model.cancelImport()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("review.cancel")
            Button("Import") {
                Task { await model.confirmImport() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!review.canImport)
            .accessibilityIdentifier("review.import")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var inPlace: Binding<Bool> {
        let model = model
        return Binding(get: { review.leavesInPlace }, set: { on in model.updateReview { $0.leavesInPlace = on } })
    }

    private var copy: Binding<Bool> {
        let model = model
        return Binding(
            get: { review.copyInsteadOfMove },
            set: { copy in
                model.updateReview { $0.copyInsteadOfMove = copy }
            })
    }
}

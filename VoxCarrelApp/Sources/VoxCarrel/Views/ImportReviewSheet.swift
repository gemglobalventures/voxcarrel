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
    let review: ImportReview
    @Binding var selection: Set<UUID>

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(review.entries.enumerated()), id: \.element.id) { index, entry in
                EntryRow(entry: entry, status: review.status(of: entry.id), index: index)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("review.entries")
    }
}

/// X2: the checkbox, the cover, and what the book is.
private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: ImportReview.Entry
    let status: ImportReview.Status?
    let index: Int

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
                    Text(entry.titleText)
                        .lineLimit(1)
                        .accessibilityIdentifier("review.entry.\(index).title")
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
                        Text(status.text)
                            .font(.caption)
                            .foregroundStyle(status.isBlocking ? AnyShapeStyle(.red) : AnyShapeStyle(.orange))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("review.entry.\(index).status")
                    }
                }
            }
            // A book that is left out is shown fainter.
            .opacity(entry.included ? 1 : 0.5)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var included: Binding<Bool> {
        let model = model
        let id = entry.id
        return Binding(
            get: { entry.included },
            set: { included in
                model.updateReview { $0.update(id) { $0.included = included } }
            })
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
            DataCover(data: cover.data, cornerRadius: cornerRadius)
                .equatable()
                .accessibilityHidden(true)
        } else {
            CoverPlaceholder(
                initials: entry.coverInitials, hue: entry.placeholderHue, side: side, cornerRadius: cornerRadius)
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
                    }
                }

                VStack(alignment: .leading, spacing: InspectorMetrics.fieldSpacing) {
                    HStack(alignment: .top, spacing: 8) {
                        InspectorField("Series") {
                            textField("Series", text: text(.series), id: "series")
                        }
                        InspectorField("Number") {
                            textField("Number", text: text(.seriesNumber), id: "seriesNumber")
                        }
                        .frame(width: 72)
                    }
                    if entry.hasAudio {
                        InspectorField("Narrators", hint: InspectorMetrics.semicolonHint) {
                            textField("Narrators", text: $narrators, id: "narrators")
                        }
                    }
                }

                InspectorSection("Where It Goes") {
                    if let offer = entry.existingMatchText {
                        Toggle(offer, isOn: addToExisting)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("review.addToExisting")
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

    private var addToExisting: Binding<Bool> {
        let model = model
        let id = entry.id
        return Binding(
            get: { entry.addToExisting },
            set: { add in
                model.updateReview { $0.update(id) { $0.addToExisting = add } }
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

/// X2: one file: its name, what it is to the book, and the way out into a book of its own.
private struct FileLineView: View {
    @Environment(AppModel.self) private var model
    let entryId: UUID
    let file: ImportReview.FileLine
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.role.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.url.path)
                .accessibilityIdentifier("review.file.\(index).name")
            Spacer(minLength: 8)
            role
            Button("Move to Its Own Book") {
                let (id, url) = (entryId, file.url)
                model.updateReview { $0.detach(file: url, from: id) }
            }
            .disabled(!file.canDetach)
            .help("Take this file out of the book and make it a book of its own")
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
            Toggle("Copy files, leave originals in place", isOn: copy)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("review.copy")
            Spacer(minLength: 12)
            Text(review.countText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("review.count")
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

    private var copy: Binding<Bool> {
        let model = model
        return Binding(
            get: { review.copyInsteadOfMove },
            set: { copy in
                model.updateReview { $0.copyInsteadOfMove = copy }
            })
    }
}

import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// I1–I9: the inspector column: one book's details to edit, a selection's shared
/// fields, or a few words when nothing is selected.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.inspecting {
        case .nothing:
            InspectorEmptyView()
        case .missing(let entry):
            // Plan 9: a book that is on Audible's list of the series and not in the library.
            MissingBookInspector()
                .id(entry.id)
        case .one(let detail, let draft):
            BookInspector(detail: detail, draft: draft)
                // Another book is another form: its own scroll position, and no field
                // left focused. The same book keeps its form while it is typed in.
                .id(detail.row.id)
        case .many(let draft):
            BulkInspectorView(draft: draft)
                .id(draft.books.map(\.id))
        }
    }
}

/// I9: a few words when there is nothing to inspect.
struct InspectorEmptyView: View {
    var body: some View {
        Text("No book selected")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("inspector.empty")
    }
}

/// The sizes the inspector's parts share.
enum InspectorMetrics {
    static let padding: CGFloat = 14
    static let sectionSpacing: CGFloat = 16
    static let fieldSpacing: CGFloat = 10
    static let semicolonHint = "Separate with semicolons"
}

/// I1: one book.
private struct BookInspector: View {
    @Environment(AppModel.self) private var model
    let detail: BookDetail
    let draft: BookDraft

    var body: some View {
        let markers = model.appOnlyMarkers
        let reasons = detail.attentionReasons

        InspectorPane(offersLookUp: true) {
            if !reasons.isEmpty {
                AttentionBanner(reasons: reasons)
            }

            VStack(spacing: 6) {
                CoverWell(row: detail.row, cover: model.draftCover)
                if markers.contains(.cover) {
                    AppOnlyMarker()
                }
            }
            .frame(maxWidth: .infinity)

            InspectorSection("Details") {
                field("Title", \.title, .title, id: "title")
                field("Subtitle", \.subtitle, .subtitle, id: "subtitle")
                field("Authors", \.authors, .authors, id: "authors", hint: InspectorMetrics.semicolonHint)
                if detail.row.hasAudio {
                    field(
                        "Narrators", \.narrators, .narrators, id: "narrators",
                        hint: InspectorMetrics.semicolonHint)
                }
                HStack(alignment: .top, spacing: 8) {
                    field("Series", \.series, .series, id: "series")
                    InspectorField("Number", isAppOnly: markers.contains(.seriesNumber), compactMarker: true) {
                        textField("Number", \.seriesNumber, id: "seriesNumber")
                    }
                    .frame(width: 64)
                }
                field("Genre", \.genre, .genre, id: "genre")
                field("Tags", \.tags, nil, id: "tags", hint: InspectorMetrics.semicolonHint)
                InspectorField("Rating") {
                    RatingControl(rating: draft.rating)
                }
            }

            InspectorSection("Publishing") {
                HStack(alignment: .top, spacing: 8) {
                    field("Year", \.year, .year, id: "year")
                    field("Language", \.language, .language, id: "language")
                }
                field("Publisher", \.publisher, .publisher, id: "publisher")
                if model.showsEditionKind {
                    EditionControl()
                }
                field("ISBN", \.isbn, .isbn, id: "isbn")
                field("ASIN", \.asin, .asin, id: "asin")
            }

            InspectorSection("Description", isAppOnly: markers.contains(.summary)) {
                TextEditor(text: text(\.summary))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 5)
                    .frame(height: 120)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("inspector.description")
            }

            InspectorSection("Reading") {
                ReadingControls(detail: detail)
            }

            InspectorSection("Files") {
                if let none = detail.noFilesText {
                    // Plan 6, V3: a book that is owned on Audible and has no files here.
                    Text(none)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inspector.noFiles")
                } else {
                    FileListView(detail: detail)
                }
            }
        }
    }

    /// I2: a field's text, read from the draft as it is now and written through the model.
    private func text(_ keyPath: WritableKeyPath<BookDraft, String>) -> Binding<String> {
        let model = model
        let shown = draft
        return Binding(
            get: {
                // The model's draft, not the one this view was made with: what was
                // typed a moment ago is already there.
                if case .one(_, let current) = model.inspecting { return current[keyPath: keyPath] }
                return shown[keyPath: keyPath]
            },
            set: { newValue in
                model.updateDraft { $0[keyPath: keyPath] = newValue }
            })
    }

    private func textField(_ title: String, _ keyPath: WritableKeyPath<BookDraft, String>, id: String) -> some View {
        TextField(text: text(keyPath), prompt: Text("")) {
            Text(title)
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(title)
        .accessibilityIdentifier("inspector.\(id)")
    }

    /// A titled text field; `marked` is the field whose "saved in app only" marker it shows.
    private func field(
        _ title: String, _ keyPath: WritableKeyPath<BookDraft, String>, _ marked: MetadataField?, id: String,
        hint: String? = nil
    ) -> some View {
        InspectorField(title, isAppOnly: marked.map(model.appOnlyMarkers.contains) ?? false, hint: hint) {
            textField(title, keyPath, id: id)
        }
    }
}

// MARK: - Parts

/// What both inspectors are laid out in: their sections one under another, as wide as
/// the column less the same padding on both sides, scrolling over Revert and Save.
struct InspectorPane<Content: View>: View {
    /// V1: whether Look Up… stands beside Revert: for one book, not for several.
    var offersLookUp = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                content
            }
            .padding(InspectorMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Above everything, and not scrolled away: it stays in sight while it is true.
        .safeAreaInset(edge: .top, spacing: 0) {
            InspectorEditedLabel()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InspectorActions(offersLookUp: offersLookUp)
        }
    }
}

/// The colour of everything that says "there are edits not yet saved".
enum EditedMark {
    static let tint = Color.orange
}

/// A pencil and a few words across the top of the inspector while there are edits not
/// yet saved; nothing when there are none.
private struct InspectorEditedLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.inspectorEditedText {
            Label(text, systemImage: "pencil.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(EditedMark.tint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InspectorMetrics.padding)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Divider()
                }
                .accessibilityIdentifier("inspector.edited")
        }
    }
}

/// A heading and what belongs under it.
struct InspectorSection<Content: View>: View {
    let title: String
    var isAppOnly = false
    @ViewBuilder var content: Content

    init(_ title: String, isAppOnly: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isAppOnly = isAppOnly
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.fieldSpacing) {
            Divider()
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if isAppOnly {
                    AppOnlyMarker()
                }
            }
            content
        }
    }
}

/// A small title, the control under it, and a hint under that.
struct InspectorField<Content: View>: View {
    let title: String
    var isAppOnly = false
    /// For a narrow field: the marker's symbol without its words.
    var compactMarker = false
    var hint: String?
    @ViewBuilder var content: Content

    init(
        _ title: String, isAppOnly: Bool = false, compactMarker: Bool = false, hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isAppOnly = isAppOnly
        self.compactMarker = compactMarker
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isAppOnly {
                    AppOnlyMarker(isCompact: compactMarker)
                }
            }
            content
            if let hint {
                // I3
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// I4: marks a field that none of the book's files can hold.
struct AppOnlyMarker: View {
    static let title = "Saved in app only"
    static let explanation = "None of this book's files can hold this field. It is kept in VoxCarrel's library."

    var isCompact = false

    var body: some View {
        Group {
            if isCompact {
                Image(systemName: "internaldrive")
            } else {
                Label(Self.title, systemImage: "internaldrive")
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(Self.explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.title)
        .accessibilityHint(Self.explanation)
        .accessibilityIdentifier("inspector.appOnly")
    }
}

/// I7: why the book needs attention.
private struct AttentionBanner: View {
    let reasons: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(reasons, id: \.self) { reason in
                    Text(reason)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector.attention")
    }
}

/// I1: five stars. A click on a star gives that rating; on the rating's own star, none.
private struct RatingControl: View {
    @Environment(AppModel.self) private var model
    let rating: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    model.updateDraft { $0.clickStar(star) }
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
                .accessibilityAddTraits(star <= rating ? .isSelected : [])
                .accessibilityIdentifier("inspector.rating.\(star)")
            }
        }
        .font(.title3)
        .help("Click a star to rate the book. Click the same star again to clear the rating.")
    }
}

/// Plan 7, K9, K10: what kind of edition an audiobook is: chosen by hand here and saved
/// with the book, or as it was worked out. Under the choice, the label the book carries
/// in the list, and how the kind is known.
private struct EditionControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let help = model.inspectorEditionHelp

        InspectorField("Edition", isAppOnly: model.editionKindIsAppOnly) {
            Picker("Edition", selection: kind) {
                ForEach(AppModel.editionKindChoices) { choice in
                    Text(choice.title).tag(choice.kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Edition")
            .accessibilityIdentifier("inspector.edition")
            if let label = model.inspectorEditionLabel {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(help ?? label)
                    .accessibilityIdentifier("inspector.edition.label")
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inspector.edition.help")
            }
        }
    }

    /// The kind as the draft has it now, changed through the model: nothing is written
    /// until Save.
    private var kind: Binding<EditionKind?> {
        let model = model
        return Binding(
            get: { model.inspectorEditionKind },
            set: { model.setEditionKind($0) })
    }
}

/// I1: read status, its dates, Listen and Read, and the audiobook's length; where the
/// book is owned other than as files, and the switch that says it is on Audible (plan 6, V3).
private struct ReadingControls: View {
    @Environment(AppModel.self) private var model
    let detail: BookDetail

    var body: some View {
        let book = detail.row.book
        let id = detail.row.id

        Picker(
            "Read status",
            selection: Binding(
                get: { book.readStatus },
                set: { status in
                    Task { await model.setReadStatus(status, for: [id]) }
                })
        ) {
            ForEach(ReadStatus.allCases, id: \.self) { status in
                Text(status.title).tag(status)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("inspector.readStatus")

        ForEach(book.readDateLines(), id: \.self) { line in
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("inspector.readDates")

        if detail.row.hasAudio || detail.row.hasEbook {
            HStack(spacing: 8) {
                if detail.row.hasAudio {
                    Button {
                        model.listen(id)
                    } label: {
                        Label(detail.row.listenTitle, systemImage: detail.row.listenSymbol)
                    }
                    .help(detail.row.listenHelpText)
                    .accessibilityIdentifier("inspector.listen")
                }
                if detail.row.hasEbook {
                    Button {
                        model.read(id)
                    } label: {
                        Label("Read", systemImage: "book")
                    }
                    .help("Open the ebook")
                    .accessibilityIdentifier("inspector.read")
                }
            }
        }

        if let summary = detail.audioSummaryText {
            Label(summary, systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("inspector.audioSummary")
        }

        // Send to phone plan, PH29.
        if let sent = detail.sentToPhoneText() {
            Label(sent, systemImage: "iphone")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("inspector.sentToPhone")
        }

        if let ownership = model.inspectorOwnershipText {
            Label(ownership, systemImage: SidebarItem.onAudible.symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inspector.ownership")
        }

        // Applied at once, like the read status: it is not part of what Save saves.
        Toggle(
            "On Audible",
            isOn: Binding(
                get: { model.inspectorIsOnAudible },
                set: { on in
                    Task { await model.setOnAudible(on, for: [id]) }
                })
        )
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!model.canMarkOnAudible(for: [id]))
        .help("You own this book on Audible. Changes nothing in the book’s files.")
        .accessibilityIdentifier("inspector.onAudible")
    }
}

/// I1, I2: Revert and Save, pinned under whatever is being edited; for one book, Look
/// Up… too (V1).
struct InspectorActions: View {
    private static let lookUpTitle = "Look Up…"

    @Environment(AppModel.self) private var model
    var offersLookUp = false

    var body: some View {
        // Look Up… in words where the column is wide enough for all three; in a narrow
        // column, as a magnifying glass, so that none of them is cut short.
        ViewThatFits(in: .horizontal) {
            bar(lookUpInWords: true)
            bar(lookUpInWords: false)
        }
        .padding(.horizontal, InspectorMetrics.padding)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func bar(lookUpInWords: Bool) -> some View {
        HStack(spacing: 8) {
            if offersLookUp {
                Button {
                    model.beginLookup()
                } label: {
                    if lookUpInWords {
                        Text(Self.lookUpTitle)
                    } else {
                        Label(Self.lookUpTitle, systemImage: "magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                }
                .fixedSize()
                .disabled(!model.canLookUp)
                .help(model.lookUpHelp)
                .accessibilityLabel(Self.lookUpTitle)
                .accessibilityIdentifier("inspector.lookup")
            }

            Button("Revert") {
                model.discardChanges()
            }
            .fixedSize()
            .disabled(!model.hasUnsavedChanges)
            .help("Put back the values as they were last saved")
            .accessibilityIdentifier("inspector.revert")

            Spacer(minLength: 8)

            // ⌘S belongs to File ▸ Save, which works when the inspector is hidden too.
            Button("Save") {
                Task { await model.save() }
            }
            .buttonStyle(.borderedProminent)
            // The one thing left to do while the inspector says "not saved".
            .tint(model.inspectorEditedText == nil ? nil : EditedMark.tint)
            .fixedSize()
            .disabled(!model.canSave)
            .accessibilityIdentifier("inspector.save")
        }
    }
}

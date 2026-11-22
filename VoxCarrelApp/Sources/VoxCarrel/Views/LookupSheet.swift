import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V2–V4: looking a book up online: what to search for, what was found, and which of
/// the chosen match's values to take.
///
/// Everything shown is the model's `lookup`, and every change goes through the model,
/// which alone closes the sheet. `shown` is the lookup the sheet was opened with: what it
/// goes on showing while it closes.
struct LookupSheet: View {
    @Environment(AppModel.self) private var model
    let shown: LookupSession

    var body: some View {
        let lookup = model.lookup ?? shown
        let isApplying = lookup.phase == .applying

        VStack(spacing: 0) {
            SearchBar(lookup: lookup)
                .disabled(isApplying)
            Divider()
            if let failure = lookup.failureText {
                FailureBanner(text: failure)
                Divider()
            }
            HSplitView {
                ResultsPane(lookup: lookup)
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 480, maxHeight: .infinity)
                OffersPane(lookup: lookup)
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(isApplying)
            Divider()
            BottomBar(lookup: lookup)
        }
        .frame(
            minWidth: 700, idealWidth: 820, maxWidth: .infinity,
            minHeight: 460, idealHeight: 560, maxHeight: .infinity
        )
        .presentationSizing(.fitted)
        .interactiveDismissDisabled()
    }
}

// MARK: - What to search for

/// V2: the title and the author, the book's numbers when it has them, and Search.
/// Return in any box searches.
private struct SearchBar: View {
    @Environment(AppModel.self) private var model
    let lookup: LookupSession

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            InspectorField("Title") {
                box("Title", \.title, id: "title")
            }
            InspectorField("Author") {
                box("Author", \.author, id: "author")
            }
            if lookup.showsISBNBox {
                InspectorField("ISBN") {
                    box("ISBN", \.isbnText, id: "isbn")
                }
                .frame(width: 132)
            }
            if lookup.showsAudibleIDBox {
                InspectorField("Audible ID") {
                    box("Audible ID", \.asinText, id: "asin")
                }
                .frame(width: 112)
            }
            Button("Search") {
                search()
            }
            .fixedSize()
            .disabled(!lookup.canSearch)
            .accessibilityIdentifier("lookup.search")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func search() {
        Task { await model.searchLookup() }
    }

    /// One box of the query, read from the lookup as it is now and written through the model.
    private func box(_ title: String, _ keyPath: WritableKeyPath<LookupQuery, String>, id: String) -> some View {
        let model = model
        let shown = lookup
        let text = Binding(
            get: { (model.lookup ?? shown).query[keyPath: keyPath] },
            set: { typed in
                model.updateLookupQuery { $0[keyPath: keyPath] = typed }
            })
        return TextField(text: text, prompt: Text("")) {
            Text(title)
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .onSubmit {
            search()
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("lookup.\(id)")
    }
}

/// V3: a source that could not be asked. What the others found is still shown.
private struct FailureBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lookup.failure")
    }
}

// MARK: - What was found

/// V2: the results, a spinner while they are on their way, or why there are none.
private struct ResultsPane: View {
    @Environment(AppModel.self) private var model
    let lookup: LookupSession

    var body: some View {
        switch lookup.phase {
        case .idle:
            message("Press Search to look for this book.")
                .accessibilityIdentifier("lookup.idle")
        case .searching:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("lookup.spinner")
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noResults:
            message("No matches found. Try a shorter title or check the spelling.")
                .accessibilityIdentifier("lookup.noResults")
        case .results, .applying:
            List(selection: selection) {
                ForEach(Array(lookup.candidates.enumerated()), id: \.element.id) { index, candidate in
                    ResultRow(candidate: candidate, index: index)
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("lookup.results")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The selected result, read from the lookup and changed through the model.
    private var selection: Binding<String?> {
        let model = model
        let shown = lookup
        return Binding(
            get: { (model.lookup ?? shown).selectedId },
            set: { id in
                Task { await model.selectLookupCandidate(id) }
            })
    }
}

/// V2: one result: its cover, what it is, and where it was found.
private struct ResultRow: View {
    let candidate: LookupCandidate
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ResultCover(candidate: candidate)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.titleText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(candidate.authorsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(candidate.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lookup.result.\(index)")
    }
}

/// V6: a result's cover, asked of the model when the row comes on screen; a quiet box
/// until it has arrived, and for a result that has none.
private struct ResultCover: View {
    private static let width: CGFloat = 36
    private static let height: CGFloat = 54

    @Environment(AppModel.self) private var model
    let candidate: LookupCandidate
    @State private var fetched: Data?

    var body: some View {
        Group {
            if let data = fetched ?? model.cachedLookupThumbnail(for: candidate) {
                DataCover(data: data, maxSide: Self.height, cornerRadius: 2)
                    .equatable()
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.quaternary)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityHidden(true)
        .task(id: candidate.coverURL) {
            let data = await model.lookupThumbnail(for: candidate)
            if !Task.isCancelled { fetched = data }
        }
    }
}

// MARK: - What to take

/// V2: the selected result's values that differ from the book's, each with its tick.
private struct OffersPane: View {
    let lookup: LookupSession

    var body: some View {
        if lookup.selected == nil {
            if !lookup.candidates.isEmpty {
                message("Select a match to see what it offers.")
                    .accessibilityIdentifier("lookup.offers.none")
            } else {
                Color.clear
            }
        } else if lookup.offers.isEmpty {
            message("This match has nothing new for this book.")
                .accessibilityIdentifier("lookup.offers.empty")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(lookup.offers) { offer in
                        OfferRow(offer: offer)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("lookup.offers")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// V2: one value: its tick and name, what was found, and under it what the book has now.
private struct OfferRow: View {
    private static let labelWidth: CGFloat = 128

    @Environment(AppModel.self) private var model
    let offer: LookupSession.Offer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(offer.label, isOn: ticked)
                .toggleStyle(.checkbox)
                .frame(width: Self.labelWidth, alignment: .leading)
                .accessibilityIdentifier("lookup.offer.\(offer.id.rawValue)")
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.found)
                    .lineLimit(3)
                    .help(offer.found)
                    .accessibilityIdentifier("lookup.offer.\(offer.id.rawValue).found")
                Text(offer.currentText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(offer.currentText)
                    .accessibilityIdentifier("lookup.offer.\(offer.id.rawValue).current")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ticked: Binding<Bool> {
        let model = model
        let field = offer.id
        return Binding(
            get: { offer.ticked },
            set: { ticked in
                model.setLookupTicked(ticked, for: field)
            })
    }
}

// MARK: - The bottom

/// V4: where the results are from, what applying leaves to do, Cancel and Apply.
private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    let lookup: LookupSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.lookupSourcesText)
                    .lineLimit(1)
                    .accessibilityIdentifier("lookup.sources")
                Text(lookup.reminderText)
                    .lineLimit(1)
                    .accessibilityIdentifier("lookup.reminder")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if lookup.phase == .applying {
                // A cover is on its way.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("lookup.applying")
            }
            // Stays enabled while applying: closing then applies nothing.
            Button("Cancel") {
                model.cancelLookup()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("lookup.cancel")
            // Not the default button: Return belongs to the search boxes, and must never
            // apply while a query is being typed. ⌘Return applies.
            Button("Apply") {
                Task { await model.applyLookup() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!lookup.canApply)
            .help("Put the ticked values into the book (⌘Return)")
            .accessibilityIdentifier("lookup.apply")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

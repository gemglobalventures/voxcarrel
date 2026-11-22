import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V2–V4: looking a book up online: what to search for, what was found, and which of
/// the chosen match's values to take.
///
/// Everything shown is the model's `lookup`, and every change goes through the model,
/// which alone closes the sheet. `shown` is the lookup the sheet was opened with: what it
/// goes on showing while it closes.
///
/// Plan 6, V5: the same sheet adds an Audible book (`isAddMode`): it has a heading, the
/// chosen result's details are only read (there is nothing to tick), and Add stands in
/// place of Apply.
struct LookupSheet: View {
    @Environment(AppModel.self) private var model
    let shown: LookupSession

    var body: some View {
        let lookup = model.lookup ?? shown
        let isApplying = lookup.phase == .applying

        VStack(spacing: 0) {
            if let heading = lookup.headingText {
                Text(heading)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("lookup.heading")
            }
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
                Group {
                    if lookup.isAddMode {
                        DetailsPane(lookup: lookup)
                    } else {
                        OffersPane(lookup: lookup)
                    }
                }
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
/// Return in any box searches, when the model has something new to search for.
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
            message(lookup.idleText)
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
                    ResultRow(lookup: lookup, candidate: candidate, index: index)
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

/// V2: one result: its cover, what it is, and where it was found. Plan 7, V1: a symbol
/// for its source, whether it is the book's own edition, and for an Audible result the
/// stores that list it when that is more than the user's own.
private struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let lookup: LookupSession
    let candidate: LookupCandidate
    let index: Int

    var body: some View {
        let badge = lookup.badgeText(for: candidate.id)
        let stores = model.lookupStoresText(for: candidate)

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
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: candidate.source.symbol)
                        .help(candidate.source.title)
                        .accessibilityHidden(true)
                    Text(candidate.note)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if badge != nil || stores != nil {
                    // Side by side where both fit whole; one under the other in a narrow pane.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { marks(badge: badge, stores: stores) }
                        VStack(alignment: .leading, spacing: 2) { marks(badge: badge, stores: stores) }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its parts are told apart: the badge and the stores have identifiers of their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookup.result.\(index)")
    }

    @ViewBuilder
    private func marks(badge: String?, stores: String?) -> some View {
        if let badge {
            VerdictBadge(
                text: badge, verdict: lookup.verdict(for: candidate.id), help: lookup.badgeHelp(for: candidate.id)
            )
            .accessibilityIdentifier("lookup.result.\(index).badge")
        }
        if let stores {
            Label(stores, systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("The Audible stores that list this edition")
                .accessibilityIdentifier("lookup.result.\(index).stores")
        }
    }
}

/// Plan 7, V1: "Your edition" or "Different edition", in a small capsule: a symbol in
/// the verdict's colour and the words in the text's own, so that they read in light and
/// dark. On a selected row, whose background is the accent colour, the colour is left out.
private struct VerdictBadge: View {
    @Environment(\.backgroundProminence) private var prominence
    let text: String
    let verdict: EditionVerdict
    /// Why, for a different edition.
    let help: String?

    var body: some View {
        let onSelection = prominence == .increased
        let tint = verdict.badgeTint

        HStack(spacing: 3) {
            Image(systemName: verdict.badgeSymbol)
                .foregroundStyle(onSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            onSelection ? AnyShapeStyle(.primary.opacity(0.18)) : AnyShapeStyle(tint.opacity(0.18)), in: Capsule()
        )
        .help(help ?? text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint(help ?? "")
    }
}

/// V6: a result's cover, asked of the model when the row comes on screen; a quiet box
/// until it has arrived, and for a result that has none.
private struct ResultCover: View {
    @Environment(AppModel.self) private var model
    let candidate: LookupCandidate
    var width: CGFloat = 36
    var height: CGFloat = 54
    @State private var fetched: Data?

    var body: some View {
        Group {
            if let data = fetched ?? model.cachedLookupThumbnail(for: candidate) {
                DataCover(data: data, maxSide: max(width, height), cornerRadius: 2)
                    .equatable()
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.quaternary)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
        .task(id: candidate.coverURL) {
            let data = await model.lookupThumbnail(for: candidate)
            if !Task.isCancelled { fetched = data }
        }
    }
}

// MARK: - What to take

/// V2: the selected result's values that differ from the book's, each with its tick.
/// Plan 7, V2: under them, what the results say of the book's edition, which is offered
/// whichever result is selected.
private struct OffersPane: View {
    let lookup: LookupSession

    var body: some View {
        let edition = lookup.editionOffer
        let remark = lookup.editionRemark

        if lookup.selected == nil {
            if !lookup.candidates.isEmpty {
                placeholder(lookup.noSelectionText, id: "lookup.offers.none", edition: edition, remark: remark)
            } else {
                Color.clear
            }
        } else if lookup.offers.isEmpty {
            placeholder(
                "This match has nothing new for this book.", id: "lookup.offers.empty", edition: edition,
                remark: remark)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(lookup.offers) { offer in
                        OfferRow(offer: offer)
                    }
                    EditionPart(offer: edition, remark: remark)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("lookup.offers")
        }
    }

    /// A few words in place of the offers, and at the foot what there is to say of the
    /// book's edition.
    private func placeholder(
        _ text: String, id: String, edition: LookupSession.EditionOffer?, remark: String?
    ) -> some View {
        VStack(spacing: 0) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(id)
            if edition != nil || remark != nil {
                Divider()
                EditionPart(offer: edition, remark: remark)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// V2: one value: its tick and name, what was found, and under it what the book has now.
/// Plan 7, V2: and why it may not be the book's, for a value of a different edition.
private struct OfferRow: View {
    @Environment(AppModel.self) private var model
    let offer: LookupSession.Offer

    var body: some View {
        OfferLayout(
            label: offer.label, ticked: ticked, found: offer.found, current: offer.currentText,
            reason: offer.reason, reasonIsWarning: true, id: offer.id.rawValue)
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

/// Plan 7, V2: what kind of edition the results show the book to be, offered like any
/// other value; or, when they show no more than something about its length, that.
private struct EditionPart: View {
    @Environment(AppModel.self) private var model
    let offer: LookupSession.EditionOffer?
    let remark: String?

    var body: some View {
        if let offer {
            OfferLayout(
                label: offer.label, ticked: ticked(offer), found: offer.found, current: offer.currentText,
                reason: offer.reason, reasonIsWarning: false, id: "edition")
        } else if let remark {
            Label(remark, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lookup.editionRemark")
        }
    }

    private func ticked(_ offer: LookupSession.EditionOffer) -> Binding<Bool> {
        let model = model
        return Binding(
            get: { offer.ticked },
            set: { ticked in
                model.setLookupEditionTicked(ticked)
            })
    }
}

/// How an offer is laid out: its tick and name, and beside them what was found, what
/// the book has now, and a line of explanation when there is one.
private struct OfferLayout: View {
    private static let labelWidth: CGFloat = 128

    let label: String
    let ticked: Binding<Bool>
    let found: String
    let current: String
    let reason: String?
    /// Orange for a reason to think twice; quiet for one that only explains.
    let reasonIsWarning: Bool
    /// The end of the row's accessibility identifiers.
    let id: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(label, isOn: ticked)
                .toggleStyle(.checkbox)
                .frame(width: Self.labelWidth, alignment: .leading)
                .accessibilityIdentifier("lookup.offer.\(id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(found)
                    .lineLimit(3)
                    .help(found)
                    .accessibilityIdentifier("lookup.offer.\(id).found")
                Text(current)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(current)
                    .accessibilityIdentifier("lookup.offer.\(id).current")
                if let reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(reasonIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                        .help(reason)
                        .accessibilityIdentifier("lookup.offer.\(id).reason")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - What is added

/// Plan 6, V5: the selected result's cover and details, to read: this is the book that
/// Add adds. Nothing here is ticked or changed.
private struct DetailsPane: View {
    private static let labelWidth: CGFloat = 84
    private static let coverSide: CGFloat = 120

    let lookup: LookupSession

    var body: some View {
        if let candidate = lookup.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ResultCover(candidate: candidate, width: Self.coverSide, height: Self.coverSide)
                        // Another result is another picture, fetched for itself.
                        .id(candidate.id)
                        .padding(.bottom, 4)
                    ForEach(lookup.detailLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.label)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: Self.labelWidth, alignment: .leading)
                            Text(line.value)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("lookup.detail.\(line.label)")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("lookup.details")
        } else if !lookup.candidates.isEmpty {
            Text(lookup.noSelectionText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("lookup.details.none")
        } else {
            Color.clear
        }
    }
}

// MARK: - The bottom

/// V4: what Apply will take, where the results are from, what applying does, Cancel and Apply. For a
/// book that is being added (plan 6, V5): Cancel, Add Without a Match and Add.
private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    let lookup: LookupSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Plan 7, V2: what Apply will take, and from which results: it changes
                // with every tick, so it stands first and in the text's own colour.
                if let summary = lookup.applySummary {
                    Text(summary)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(summary)
                        .accessibilityIdentifier("lookup.applySummary")
                }
                // Once a search has finished this says what each source found (and, plan 7
                // A7, that nothing was read by the book's narrator): two lines at most,
                // and all of it in the tooltip.
                Text(model.lookupSourcesText(for: lookup))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.lookupSourcesText(for: lookup))
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
            if lookup.isAddMode {
                // Offered once the catalogue has been tried.
                if lookup.offersAddByHand {
                    Button(lookup.addByHandTitle) {
                        Task { await model.addAudibleBookByHand() }
                    }
                    .disabled(!lookup.canAddByHand)
                    .help(lookup.addByHandHelp)
                    .accessibilityIdentifier("lookup.addByHand")
                }
                // Not the default button, as Apply is not: ⌘Return adds.
                Button("Add") {
                    Task { await model.addLookupSelection() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!lookup.canAdd)
                .help("Add the selected book to your library (⌘Return)")
                .accessibilityIdentifier("lookup.add")
            } else {
                // Not the default button: Return belongs to the search boxes, and must never
                // apply while a query is being typed. ⌘Return applies.
                Button(lookup.applyTitle) {
                    Task { await model.applyLookup() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!lookup.canApply)
                .help(lookup.applyHelp)
                .accessibilityIdentifier("lookup.apply")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

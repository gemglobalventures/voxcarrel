import SwiftUI
import VoxCarrelAppCore

// Plan 9: what is shown of Audible's list of a series: the strip above the series' books,
// the sheet that asks which Audible series is meant, what the inspector shows of a book
// the library does not have, and that book's context menu. Everything said and every
// "can" is the model's.

/// Above the books of a series: how much of Audible's list the library has, where the
/// list came from, anything worth a note, and what can be done about it.
struct SeriesHeaderStrip: View {
    let model: AppModel
    let header: SeriesHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            backButton
            VStack(alignment: .leading, spacing: 2) {
                Text(header.summary)
                    .font(.headline)
                    .accessibilityIdentifier("series.summary")
                if let source = header.source {
                    Text(source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("series.source")
                }
                ForEach(header.notes, id: \.self) { note in
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("series.note")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // In one row where the column is wide enough for it, in two where it is not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    checkButton
                    numbersButton
                    hiddenToggle
                    Spacer(minLength: 0)
                    moreMenu
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        checkButton
                        hiddenToggle
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        numbersButton
                        Spacer(minLength: 0)
                        moreMenu
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("series.header")
    }

    /// Plan 10: back to the list the series was opened from, by a double-click on its
    /// row or its stack there; nothing when it was reached any other way.
    @ViewBuilder private var backButton: some View {
        if let title = model.seriesBackTitle {
            Button {
                model.goBackFromSeries()
            } label: {
                Label(title, systemImage: "chevron.backward")
            }
            .buttonStyle(.link)
            .help("Go back to the list this series was opened from")
            .accessibilityIdentifier("series.back")
        }
    }

    private var checkButton: some View {
        Button(header.checkTitle) {
            Task { await model.checkSeries() }
        }
        .fixedSize()
        .disabled(!header.canCheck)
        .help("Ask Audible for its list of this series, to see which books you do not have")
        .accessibilityIdentifier("series.check")
    }

    private var numbersButton: some View {
        Button("Use Audible's Numbers") {
            Task { await model.useAudibleNumbers() }
        }
        .fixedSize()
        .disabled(!header.canUseAudibleNumbers)
        .help("Give the books that Audible numbers differently Audible's numbers")
        .accessibilityIdentifier("series.useAudibleNumbers")
    }

    @ViewBuilder private var hiddenToggle: some View {
        if header.hiddenCount > 0 {
            Toggle("Show Hidden", isOn: showsHidden)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Show the missing books you have hidden")
                .accessibilityIdentifier("series.showHidden")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Unlink") {
                Task { await model.unlinkSeries() }
            }
            .disabled(!header.canUnlink)
            .accessibilityIdentifier("series.unlink")
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More to do with Audible's list of this series")
        .accessibilityLabel("More")
        .accessibilityIdentifier("series.more")
    }

    private var showsHidden: Binding<Bool> {
        let model = model
        return Binding(get: { model.showsHiddenMissing }, set: { model.showsHiddenMissing = $0 })
    }
}

/// Asks which of several Audible series a library series is. The model closes it, when
/// one is chosen or the question is cancelled.
struct SeriesPickerSheet: View {
    let model: AppModel
    let choices: [SeriesChoice]
    /// The row that is selected in the list.
    @State private var picked: SeriesChoice.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which series is this?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("seriesPicker.heading")
            Text("Audible lists these books in more than one series. Choose the one to compare your books with.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(choices, selection: $picked) { choice in
                SeriesChoiceRow(choice: choice)
            }
            .listStyle(.inset)
            .frame(height: 220)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .accessibilityIdentifier("seriesPicker.choices")
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSeriesChoice()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("seriesPicker.cancel")
                Button("Choose") {
                    guard let picked else { return }
                    Task { await model.chooseSeries(picked) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil)
                .accessibilityIdentifier("seriesPicker.choose")
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}

/// One Audible series in the picker. Given plain values: it is a list's row.
private struct SeriesChoiceRow: View {
    let choice: SeriesChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(choice.title)
                .lineLimit(2)
            Text(choice.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("seriesPicker.choice.\(choice.id)")
    }
}

/// The inspector for one book that is on Audible's list of the series and not in the
/// library: what Audible says of it, and the three things that can be done with it.
struct MissingBookInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let info = model.missingBook {
            ScrollView {
                VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("inspector.missing.title")
                        Text(info.seriesText)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("inspector.missing.series")
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Text(info.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inspector.missing.note")

                    InspectorSection("Details") {
                        MissingBookField(title: "Authors", text: info.authorsText, id: "authors")
                        MissingBookField(title: "Narrators", text: info.narratorsText, id: "narrators")
                        MissingBookField(title: "Length", text: info.lengthText, id: "length")
                        MissingBookField(title: "Store", text: info.storeText, id: "store")
                    }

                    InspectorSection("Actions") {
                        Button("Add as Audible Book") {
                            Task { await model.addMissingAsAudibleBook() }
                        }
                        .disabled(!info.canChange)
                        .help("Add this book to your library as a book you have on Audible, with no files here")
                        .accessibilityIdentifier("inspector.missing.add")
                        Button("Show on Audible") {
                            model.showMissingOnAudible()
                        }
                        .help("Open this book's page on Audible in your browser")
                        .accessibilityIdentifier("inspector.missing.showOnAudible")
                        Button(info.hideTitle) {
                            Task { await model.setSelectedMissingHidden(!info.isHidden) }
                        }
                        .disabled(!info.canChange)
                        .help("A hidden book is not counted as missing, and is not shown unless hidden books are")
                        .accessibilityIdentifier("inspector.missing.hide")
                    }
                }
                .padding(InspectorMetrics.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("inspector.missing")
        } else {
            InspectorEmptyView()
        }
    }
}

/// A small title and what Audible says under it; nothing when Audible says nothing.
private struct MissingBookField: View {
    let title: String
    let text: String
    let id: String

    var body: some View {
        if !text.isEmpty {
            InspectorField(title) {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inspector.missing.\(id)")
            }
        }
    }
}

/// A context menu's items for a book the library does not have: the three actions, in
/// place of the book commands. They act on the row the menu was opened on, whether or
/// not it is selected.
struct MissingBookMenuItems: View {
    let model: AppModel
    let actions: MissingActions
    /// The rows the menu is for.
    let ids: Set<Int64>

    var body: some View {
        Button("Add as Audible Book") {
            Task { await model.addMissingAsAudibleBook(for: ids) }
        }
        .disabled(!actions.canAdd)
        .accessibilityIdentifier("contextMenu.missing.add")
        Button("Show on Audible") {
            model.showMissingOnAudible(for: ids)
        }
        .disabled(!actions.canShow)
        .accessibilityIdentifier("contextMenu.missing.showOnAudible")
        Button(actions.hideTitle) {
            Task { await model.setMissingHidden(!actions.isHidden, for: ids) }
        }
        .disabled(!actions.canSetHidden)
        .accessibilityIdentifier("contextMenu.missing.hide")
    }
}

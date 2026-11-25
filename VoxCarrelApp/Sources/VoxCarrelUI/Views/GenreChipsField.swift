import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// Genres as chips (G21, G22): one chip, a row of chips that wraps, and the field that
// edits a book's genres. Each is handed everything it shows and what to call: none
// reads the model, so they can be used in a list's rows as well as in the inspector.

/// One genre: its name in a rounded capsule, with a small button that takes it away
/// when there is something to call for that.
struct GenreChip: View {
    let name: String
    /// Said after the name: "2 of 3 books" for a genre only some books have.
    var detail: String?
    /// Drawn with a broken outline: only some of the books have it.
    var isMixed = false
    let identifier: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove \(name)")
                .accessibilityLabel("Remove \(name)")
                .accessibilityIdentifier("\(identifier).remove")
            }
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, remove == nil ? 8 : 5)
        .padding(.vertical, 2)
        .background(isMixed ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary), in: Capsule())
        .overlay {
            if isMixed {
                Capsule()
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Genres to read, as chips that wrap; with `remove`, each can be taken away.
struct GenreChipsRow: View {
    let names: [String]
    /// The start of each chip's accessibility identifier.
    let identifier: String
    var remove: ((String) -> Void)?

    var body: some View {
        ChipFlow {
            ForEach(names, id: \.self) { name in
                GenreChip(
                    name: name, identifier: "\(identifier).chip.\(name)",
                    remove: remove.map { remove in { remove(name) } })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Lays chips out in lines, starting a new line when the next does not fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(subviews, in: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let frames = arrange(subviews, in: bounds.width).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where each chip goes in a given width, and the room they take together. A chip
    /// wider than the width is given the width, and cuts its name short.
    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + lineHeight))
    }
}

/// G21, G22: a book's genres as chips that can be taken away and put in another order,
/// and under them a box to add one: what is typed is matched against the library's
/// list, by group, and a name the list does not have can be made a genre of a group.
///
/// What is offered, and what a name comes to, is the caller's to say (`suggestions`,
/// `add`, `create`): the field keeps only the text being typed and which offer is lit.
struct GenreChipsField: View {
    struct Chip: Identifiable {
        var name: String
        /// Said after the name: "2 of 3 books" for a genre only some books have.
        var detail: String?
        /// Whether only some of the books have it.
        var isMixed = false

        var id: String { name }
    }

    /// One line of what is offered.
    private struct Offer: Identifiable {
        enum Kind {
            case heading
            case genre
            case create
        }

        var kind: Kind
        var text: String
        /// For a genre, its name; for the offer to make one, the name it would have.
        var name = ""
        /// Its place among the lines that can be chosen; nil for a heading.
        var choice: Int?

        var id: String { "\(kind).\(text)" }
    }

    private static let offerHeight: CGFloat = 22
    private static let offersShown = 8

    let chips: [Chip]
    /// Said under the field: the wording the genres came in, when it differs.
    var note: String?
    let identifier: String
    /// What to offer for what has been typed.
    let suggestions: (String) -> GenreSuggestions
    /// Adds a genre by name, or by a name a source has for it.
    let add: (String) -> Void
    let remove: (String) -> Void
    /// Puts the chip at one place at another; nil where the order cannot be changed.
    var move: ((Int, Int) -> Void)?
    /// Makes a genre of this name in a group, and adds it.
    let create: (String, GenreGroup) -> Void

    @State private var typed = ""
    /// Whether the whole list is shown with nothing typed.
    @State private var showsAll = false
    /// The place of the offer that Return chooses.
    @State private var lit = 0
    /// The name whose group is being asked for; nil when none is.
    @State private var creating: String?

    var body: some View {
        let offered = suggestions(typed)
        let offers = showsAll || !typed.isEmpty ? Self.offers(offered) : []

        VStack(alignment: .leading, spacing: 6) {
            if !chips.isEmpty {
                ChipFlow {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                        chipView(chip, at: index)
                    }
                }
            }
            HStack(spacing: 4) {
                TextField(text: $typed, prompt: Text("Add a genre")) {
                    Text("Add a genre")
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    choose(offers.first { $0.choice == lit })
                }
                .onKeyPress(.downArrow) {
                    light(lit + 1, among: offers)
                }
                .onKeyPress(.upArrow) {
                    light(lit - 1, among: offers)
                }
                .onExitCommand {
                    typed = ""
                    showsAll = false
                }
                .accessibilityLabel("Add a genre")
                .accessibilityIdentifier("\(identifier).add")
                Button {
                    showsAll.toggle()
                } label: {
                    Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Show every genre")
                .accessibilityLabel("Show every genre")
                .accessibilityIdentifier("\(identifier).showAll")
            }
            // G22: the group of a new genre is asked for here.
            .popover(isPresented: isCreating, arrowEdge: .bottom) {
                groupChoice
            }
            if let problem = offered.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).problem")
            }
            if !offers.isEmpty {
                offerList(offers)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).note")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: typed) {
            lit = 0
        }
        // A genre was added or taken away: the box is ready for the next.
        .onChange(of: chips.map(\.name)) {
            typed = ""
            showsAll = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Chips

    private func chipView(_ chip: Chip, at index: Int) -> some View {
        let name = chip.name
        return GenreChip(
            name: name, detail: chip.detail, isMixed: chip.isMixed, identifier: "\(identifier).chip.\(name)",
            remove: { remove(name) }
        )
        .contextMenu {
            if chip.isMixed {
                Button("Add to All") { add(name) }
                    .accessibilityIdentifier("\(identifier).chip.addToAll")
            }
            if let move {
                Button("Move Left") { move(index, index - 1) }
                    .disabled(index == 0)
                    .accessibilityIdentifier("\(identifier).chip.moveLeft")
                Button("Move Right") { move(index, index + 1) }
                    .disabled(index == chips.count - 1)
                    .accessibilityIdentifier("\(identifier).chip.moveRight")
            }
            Button("Remove") { remove(name) }
                .accessibilityIdentifier("\(identifier).chip.remove")
        }
        .modifier(ChipReordering(name: name, index: index, names: chips.map(\.name), move: move))
    }

    // MARK: What is offered

    /// The lines of what is offered: each group's heading and its genres, then the
    /// offer to make what was typed a genre.
    private static func offers(_ offered: GenreSuggestions) -> [Offer] {
        var offers: [Offer] = []
        var choice = 0
        for group in offered.groups {
            offers.append(Offer(kind: .heading, text: group.title))
            for genre in group.genres {
                offers.append(Offer(kind: .genre, text: genre.name, name: genre.name, choice: choice))
                choice += 1
            }
        }
        if let title = offered.createTitle, let name = offered.createName {
            offers.append(Offer(kind: .create, text: title, name: name, choice: choice))
        }
        return offers
    }

    private func offerList(_ offers: [Offer]) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(offers) { offer in
                        offerLine(offer)
                            .id(offer.id)
                    }
                }
            }
            .frame(height: CGFloat(min(offers.count, Self.offersShown)) * Self.offerHeight)
            .background(
                Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .onChange(of: lit) {
                if let id = offers.first(where: { $0.choice == lit })?.id { scroller.scrollTo(id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).suggestions")
    }

    @ViewBuilder private func offerLine(_ offer: Offer) -> some View {
        switch offer.kind {
        case .heading:
            Text(offer.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(
                    maxWidth: .infinity, minHeight: Self.offerHeight, maxHeight: Self.offerHeight, alignment: .leading
                )
                .accessibilityAddTraits(.isHeader)
        case .genre, .create:
            Button {
                choose(offer)
            } label: {
                Text(offer.text)
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .frame(
                        maxWidth: .infinity, minHeight: Self.offerHeight, maxHeight: Self.offerHeight,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(offer.choice == lit ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            .accessibilityIdentifier(
                offer.kind == .create ? "\(identifier).create" : "\(identifier).suggestion.\(offer.name)")
        }
    }

    /// Return, or a click: adds the genre, or asks for the group of a new one. With no
    /// offer to choose, what was typed is handed over as it is.
    private func choose(_ offer: Offer?) {
        switch offer?.kind {
        case .genre: add(offer?.name ?? typed)
        case .create: creating = offer?.name
        case .heading, nil: add(typed)
        }
    }

    /// An arrow key: lights the offer at `place`, when there is one.
    private func light(_ place: Int, among offers: [Offer]) -> KeyPress.Result {
        guard !offers.isEmpty else { return .ignored }
        if offers.contains(where: { $0.choice == place }) { lit = place }
        return .handled
    }

    // MARK: A new genre's group

    private var isCreating: Binding<Bool> {
        Binding(
            get: { creating != nil },
            set: { shown in
                if !shown { creating = nil }
            })
    }

    /// G22: the groups a new genre can be put in.
    private var groupChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a group for the new genre")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(GenreSuggestions.createGroups, id: \.self) { group in
                Button {
                    let name = creating
                    creating = nil
                    if let name { create(name, group) }
                } label: {
                    Text(group.title)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("\(identifier).create.\(group.rawValue)")
            }
        }
        .padding(12)
        .frame(minWidth: 200)
    }
}

/// G21: a chip can be dragged onto another to take its place. Nothing where the order
/// cannot be changed.
private struct ChipReordering: ViewModifier {
    let name: String
    let index: Int
    /// The chips' names, in order: where a dropped one came from.
    let names: [String]
    let move: ((Int, Int) -> Void)?

    func body(content: Content) -> some View {
        if let move {
            content
                .draggable(name)
                .dropDestination(for: String.self) { dropped, _ in
                    guard let from = dropped.first.flatMap(names.firstIndex(of:)) else { return false }
                    move(from, index)
                    return true
                }
        } else {
            content
        }
    }
}

import Foundation
import Observation
import VoxCarrelCore

/// One book of the review list of Fill in Genres.
public struct GenreFillRow: Identifiable, Equatable, Sendable {
    /// The book's id.
    public var id: Int64
    public var title: String
    /// The book's first author; empty when it has none.
    public var author: String
    /// The genres proposed, as the library names them, less any the owner took away.
    public var genres: [String]
    /// Where they were found: "Audible"; nil when nothing was.
    public var sourceText: String?
    /// What to say under the book: that nothing was found, why it could not be looked
    /// up, or what was found when that is not surely the book. Nil for a sure match.
    public var note: String?
    /// Whether the book is to be given the genres.
    public var isTicked: Bool
    /// Whether there is anything to tick: there are genres to give.
    public var canTick: Bool { !genres.isEmpty }

    /// The wording the genres came in, kept with them when they are applied.
    var genreSource: String?

    static let nothingFound = "Nothing found"

    /// G32: a proposal as its row. A sure match is ticked; one that is not is shown
    /// with the title and author that were found, for the owner to check.
    init(_ proposal: GenreProposal) {
        id = proposal.id
        title = proposal.title
        author = proposal.author ?? ""
        genres = proposal.genres
        genreSource = proposal.genreSource
        sourceText = proposal.foundNothing ? nil : proposal.source?.title
        isTicked = !proposal.foundNothing && proposal.isSure
        if proposal.foundNothing {
            note = proposal.failure.map { "Could not be looked up. \(UserMessage.text(for: $0))" } ?? Self.nothingFound
        } else if !proposal.isSure {
            let found = "Found as \"\(proposal.foundTitle ?? proposal.title)\""
            let by = proposal.foundAuthor?.trimmedOrNil.map { " by \($0)" } ?? ""
            note = "\(found)\(by) — check before ticking"
        }
    }
}

/// G29–G33: the state of Fill in Genres. It decides everything the sheet shows. Books
/// are looked up one at a time, off the main thread; nothing in the library changes
/// until `apply()`.
@MainActor @Observable
public final class GenreFillSession {
    public enum Phase: Equatable, Sendable {
        /// Nothing has been looked up yet.
        case ready
        case lookingUp
        /// The lookups are over, or were stopped: what was found is shown.
        case review
        case applying
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let withNoGenre: [GenreFillBook]
    @ObservationIgnored private let withGeneral: [GenreFillBook]

    init(model: AppModel, withNoGenre: [GenreFillBook], withGeneral: [GenreFillBook]) {
        self.model = model
        self.withNoGenre = withNoGenre
        self.withGeneral = withGeneral
    }

    public let title = "Fill in Genres"
    public let includesGeneralTitle = "Also books with only a general genre"
    public let startTitle = "Look Up"
    public let stopTitle = "Stop"

    public private(set) var phase = Phase.ready

    // MARK: Which books

    private var storedIncludesGeneral = false

    /// G29: whether books whose only genre is a general one (Literary & General, or
    /// any genre in Other) are looked up too. Off to begin with; it can be changed
    /// only before the lookups begin.
    public var includesGeneral: Bool {
        get { storedIncludesGeneral }
        set {
            guard phase == .ready else { return }
            storedIncludesGeneral = newValue
        }
    }

    private var candidates: [GenreFillBook] {
        storedIncludesGeneral ? withGeneral : withNoGenre
    }

    /// How many books would be looked up.
    public var candidateCount: Int {
        candidates.count
    }

    /// "12 books have no genre."
    public var candidateText: String {
        let count = candidateCount
        guard count > 0 else { return "Every book has a genre." }
        let general = storedIncludesGeneral ? ", or only a general one" : ""
        return count == 1 ? "1 book has no genre\(general)." : "\(count) books have no genre\(general)."
    }

    public var canStart: Bool {
        phase == .ready && candidateCount > 0
    }

    // MARK: Looking up

    /// The books that have been looked up, in the order they were, each with what was found.
    public private(set) var rows: [GenreFillRow] = []
    /// How many books the lookups that were begun are for.
    private var total = 0
    private var wasStopped = false
    /// G30: why nothing could be looked up, as a sentence; nil when it could.
    public private(set) var problem: String?
    /// The lookups that are running, or the last that ran. Tests wait for it.
    @ObservationIgnored var lookingUp: Task<Void, Never>?

    /// G30: looks the books up, one at a time. What is found is added to `rows` as it
    /// arrives. Without the network nothing is found and `problem` says so.
    public func start() {
        guard canStart, let worker = model.worker else { return }
        let books = candidates
        phase = .lookingUp
        problem = nil
        rows = []
        total = books.count
        wasStopped = false
        lookingUp = Task { [weak self] in
            do {
                // Off the main thread: the list is read, and each lookup waits on the network.
                let fill = try await worker.genreFill()
                for try await proposal in fill.proposals(for: books) {
                    guard let self, !Task.isCancelled else { return }
                    self.rows.append(GenreFillRow(proposal))
                }
                self?.finishLookingUp(failure: nil)
            } catch {
                self?.finishLookingUp(failure: error)
            }
        }
    }

    private func finishLookingUp(failure: Error?) {
        guard phase == .lookingUp else { return }
        if let failure {
            problem = (failure as? LookupError) == .notReachable
                ? UserMessage.genreFillNotReachable
                : "Genres could not be looked up. \(UserMessage.text(for: failure)) Nothing was changed."
        }
        // With nothing found there is nothing to review: it can be tried again.
        phase = rows.isEmpty && failure != nil ? .ready : .review
    }

    /// "Looking up 3 of 12…" while a book is being looked up; nil at any other time.
    public var progressText: String? {
        guard phase == .lookingUp else { return nil }
        return "Looking up \(min(rows.count + 1, total)) of \(total)…"
    }

    public var canStop: Bool {
        phase == .lookingUp && !wasStopped
    }

    /// G33: stops looking up. What was found so far is shown, and can be applied.
    public func stop() {
        guard phase == .lookingUp else { return }
        wasStopped = true
        lookingUp?.cancel()
        phase = .review
    }

    /// What the lookups came to: "Genres found for 2 of 3 books."
    public var summary: String? {
        guard phase == .review else { return nil }
        let found = rows.filter(\.canTick).count
        let looked = rows.count
        let sentence = "Genres found for \(found) of \(looked == 1 ? "1 book" : "\(looked) books")."
        guard wasStopped, looked < total else { return sentence }
        return "Stopped after \(looked) of \(total) books. \(sentence)"
    }

    // MARK: Reviewing

    /// G32: ticks or unticks a book. A book with no genres to give cannot be ticked.
    public func setTicked(_ ticked: Bool, for id: Int64) {
        guard phase == .review, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isTicked = ticked && rows[index].canTick
    }

    /// Takes one of the proposed genres away before applying. A book left with none
    /// has nothing to be given, and is unticked.
    public func removeGenre(_ name: String, from id: Int64) {
        guard phase == .review, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].genres = GenreChips.removing(name, from: rows[index].genres)
        if !rows[index].canTick { rows[index].isTicked = false }
    }

    public var tickedCount: Int {
        rows.filter(\.isTicked).count
    }

    /// G33: nothing to apply with nothing ticked.
    public var canApply: Bool {
        phase == .review && tickedCount > 0 && model.busyLabel == nil && model.filesCanChange
    }

    /// "Apply to 3 Books"
    public var applyTitle: String {
        switch tickedCount {
        case 0: "Apply"
        case 1: "Apply to 1 Book"
        default: "Apply to \(tickedCount) Books"
        }
    }

    // MARK: Applying and closing

    /// G33: gives the ticked books their genres, as one operation that Undo reverses,
    /// writes their files as a save does, and closes the sheet. G31: nothing else of a
    /// book is changed. What could not be saved is reported as other saves report it.
    public func apply() async {
        guard canApply else { return }
        let ticked = rows.filter(\.isTicked)
        let chosen = ticked.map { GenreChoice(bookId: $0.id, genres: $0.genres, genreSource: $0.genreSource) }
        let titles = Dictionary(ticked.map { ($0.id, $0.title) }) { first, _ in first }
        let model = model
        phase = .applying
        model.genreFill = nil
        await model.perform("Filling in genres…") { worker in
            let summary = UserMessage.summary(of: try await worker.applyGenres(chosen), titles: titles)
            if !summary.isClean { model.result = summary }
        }
    }

    /// Closes the sheet: lookups that are running are stopped, and nothing is applied.
    public func cancel() {
        lookingUp?.cancel()
        if phase == .lookingUp { phase = .review }
        model.genreFill = nil
    }
}

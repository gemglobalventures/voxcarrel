import Foundation
import VoxCarrelCore

// Abridged, unabridged or dramatised (plan 7, Task 5b). K8–K10.
//
// A book's edition kind is kept in the catalogue only. It is set by hand in the
// inspector and saved with the book, or worked out by Check Edition, which looks each
// selected book up, changes only this one field, and is undone as one operation.

/// One choice of the inspector's edition control.
public struct EditionKindChoice: Identifiable, Equatable, Sendable {
    /// Nil for "Not known".
    public var kind: EditionKind?
    public var title: String

    public var id: String { kind?.rawValue ?? "unknown" }
}

extension AppModel {
    // MARK: K9 The inspector

    /// K9: the inspector's choices, in order: Unabridged, Abridged, Dramatised, Not known.
    public static let editionKindChoices: [EditionKindChoice] =
        EditionKind.allCases.map { EditionKindChoice(kind: $0, title: $0.title) }
        + [EditionKindChoice(kind: nil, title: "Not known")]

    /// K9: what the inspector's edition control shows: the one inspected book's kind as
    /// its draft has it; nil for not known, and when one book is not what is inspected.
    public var inspectorEditionKind: EditionKind? {
        guard case .one(_, let draft) = inspecting else { return nil }
        return draft.editionKind?.kind
    }

    /// K9: whether the edition control is shown: one book is inspected, and it is an audiobook.
    public var showsEditionKind: Bool {
        guard case .one(let detail, _) = inspecting else { return false }
        return detail.row.hasAudio
    }

    /// K9: the user's own choice of kind for the inspected book; nil for "Not known".
    /// Nothing is written until `save()`.
    public func setEditionKind(_ kind: EditionKind?) {
        updateDraft { $0.chooseEditionKind(kind) }
    }

    /// K9: whether the edition kind is marked "saved in app only": it was set by hand.
    /// (It is never written into a file, but only the user's own choice is marked.)
    public var editionKindIsAppOnly: Bool {
        guard case .one(let detail, let draft) = inspecting, detail.row.hasFiles else { return false }
        return draft.editionKindIsAppOnly
    }

    /// K10: the inspector's small label, "Abridged", "Probably abridged" or
    /// "Dramatised"; nil when there is nothing to show.
    public var inspectorEditionLabel: String? {
        guard case .one(_, let draft) = inspecting else { return nil }
        return draft.editionKind?.label
    }

    /// K10: how the inspected book's kind is known, with the reason: the label's
    /// tooltip, and the line under the control. Nil when the kind is not known.
    public var inspectorEditionHelp: String? {
        guard case .one(_, let draft) = inspecting else { return nil }
        return draft.editionKind?.helpText
    }

    // MARK: K8 Check Edition

    static let checkEditionTitle = "Check Edition"

    /// K8: what the command says.
    public var checkEditionTitle: String { Self.checkEditionTitle }

    /// K8: whether the selected books' editions can be checked now.
    public var canCheckEdition: Bool {
        canCheckEdition(for: selection)
    }

    /// The same for these books, for a context menu: a library is open, nothing is
    /// running, and at least one of the books is an audiobook.
    public func canCheckEdition(for ids: Set<Int64>) -> Bool {
        isLibraryOpen && busyLabel == nil && storedPrompt == nil
            && rows.contains { ids.contains($0.id) && $0.hasAudio }
    }

    /// K8: what the command's tooltip says.
    public var checkEditionHelp: String {
        "Look each selected audiobook up and work out whether it is unabridged, abridged or dramatised"
    }

    /// K8: checks the selection.
    public func checkEdition() async {
        await checkEdition(for: selection)
    }

    /// K8: works out the edition kind of each of these audiobooks: one lookup for each,
    /// one after another, with `busyLabel` saying "Checking 2 of 5…", and then one
    /// change to the catalogue that Undo reverses whole ("Check edition of 5 books").
    /// Only the edition kind is changed, and never one that was set by hand.
    ///
    /// Nothing is looked up for a book whose kind was set by hand, nor when every
    /// lookup source is off: its files are still read for what they say. Books without
    /// audio are passed over.
    ///
    /// `cancelEditionCheck()` stops it: nothing is then written at all. Unsaved edits
    /// are kept. When it ends, `alert` says so if some book's edition is still not known.
    public func checkEdition(for ids: Set<Int64>) async {
        let books = rows.filter { ids.contains($0.id) && $0.hasAudio }
        guard canCheckEdition(for: ids), !books.isEmpty else { return }
        let total = books.count
        guard let worker = await begin(Self.checkingLabel(1, of: total)) else { return }
        isCheckingEdition = true
        let language = lookupLanguage
        let looksUp = canAskLookupSources

        let work = Task { () -> [EditionCheck]? in
            var checks: [EditionCheck] = []
            for (index, row) in books.enumerated() {
                guard !Task.isCancelled else { return nil }
                self.busyLabel = Self.checkingLabel(index + 1, of: total)
                var results: [LookupCandidate] = []
                // K1: a kind set by hand is not replaced, so nothing is asked about it.
                if looksUp, row.book.editionKind?.isSetByHand != true {
                    let evidence = try? await worker.editionEvidence(for: row.id)
                    let query = Self.editionQuery(for: row.book)
                    if !query.isEmpty {
                        let context = LookupBookContext(
                            metadata: row.book.metadata, audioSeconds: evidence?.audioSeconds,
                            isAbridged: row.book.editionKind?.kind.isAbridged)
                        results = await worker.lookUp(
                            query, preferAudio: true, language: language, book: context
                        ).candidates
                    }
                }
                // A lookup that was cancelled comes back empty: it is not an answer.
                guard !Task.isCancelled else { return nil }
                checks.append(EditionCheck(bookId: row.id, results: results))
            }
            return checks
        }
        editionCheck = work
        let checks = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        editionCheck = nil
        isCheckingEdition = false

        var said: String?
        if let checks {
            busyLabel = "Updating…"
            do {
                let outcomes = try await worker.checkEditions(checks)
                said = Self.editionCheckSummary(outcomes, titles: Dictionary(books.map { ($0.id, $0.book.title) }) { a, _ in a })
            } catch {
                show(error)
            }
        }
        await finish()
        if let said, alert == nil { alert = said }
    }

    /// K8: stops a check that is running. Nothing it found is written.
    public func cancelEditionCheck() {
        editionCheck?.cancel()
    }

    /// "Checking 2 of 5…"
    static func checkingLabel(_ number: Int, of total: Int) -> String {
        "Checking \(number) of \(total)…"
    }

    /// What a check looks a book up by: its title, first author and first narrator.
    /// (Not its ASIN or ISBN: those find the one edition, and the others are wanted too.)
    static func editionQuery(for book: Book) -> LookupQuery {
        LookupQuery(
            title: book.title.trimmed, author: book.authors.lazy.compactMap(\.trimmedOrNil).first ?? "",
            narrator: book.narrators.lazy.compactMap(\.trimmedOrNil).first { !EditionMatch.isFullCast($0) },
            wantsAudioEditions: true)
    }

    /// What is said when a check ends with some book's edition still not known; nil
    /// when every book has one.
    static func editionCheckSummary(_ outcomes: [EditionCheckOutcome], titles: [Int64: String]) -> String? {
        let unknown = outcomes.filter { $0.kind == nil }
        guard !unknown.isEmpty else { return nil }
        if outcomes.count == 1, let only = unknown.first {
            let title = titles[only.bookId]?.trimmedOrNil.map { "“\($0)”" } ?? "this book"
            let text = "The edition of \(title) could not be worked out."
            return only.remark.map { "\(text) \($0)" } ?? text
        }
        return unknown.count == outcomes.count
            ? "The edition of these \(outcomes.count) books could not be worked out."
            : "The edition of \(unknown.count) of \(outcomes.count) books could not be worked out."
    }
}

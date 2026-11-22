import Foundation
import VoxCarrelCore

// Abridged, unabridged or dramatised (plan 7, Task 5b). K8–K10.
//
// A book's edition kind is kept in the catalogue only. It is set by hand in the
// inspector and saved with the book, or worked out by Check Edition, which looks each
// selected book up, changes only this one field, and is undone as one operation.

/// What the lookups of a Check Edition came to.
struct EditionLookups: Sendable {
    /// The books to work out, each with what was found for it.
    var checks: [EditionCheck] = []
    /// The books passed over because a source did not answer, with the sources that
    /// did not: half an answer is not written down as the whole of one.
    var unanswered: [Int64: Set<LookupSource>] = [:]
    /// True when no source at all could be reached, and the lookups were given up.
    var nothingReachable = false
}

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
        guard case .one(_, let draft) = inspecting, let note = draft.editionKind, !note.isNotKnown else { return nil }
        return note.kind
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
        // SV7: not when any of them is a book the library does not have.
        isLibraryOpen && busyLabel == nil && storedPrompt == nil && !holdsMissing(ids)
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
    /// A book for which any source did not answer is not written: what the others
    /// found is only part of the evidence. When no source at all can be reached the
    /// lookups are given up there and then. Either way `alert` says how many books
    /// were passed over, and which sources could not be reached.
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

        let work = Task { () -> EditionLookups? in
            var looked = EditionLookups()
            for (index, row) in books.enumerated() {
                guard !Task.isCancelled else { return nil }
                self.busyLabel = Self.checkingLabel(index + 1, of: total)
                var results: [LookupCandidate] = []
                var failed: Set<LookupSource> = []
                // K1: a kind set by hand is not replaced, so nothing is asked about it.
                let query = Self.editionQuery(for: row.book)
                if looksUp, row.book.editionKind?.isSetByHand != true, !query.isEmpty {
                    if looked.nothingReachable {
                        // Not asked again of sources that are not there.
                        looked.unanswered[row.id] = []
                        continue
                    }
                    let evidence = try? await worker.editionEvidence(for: row.id)
                    let context = LookupBookContext(
                        metadata: row.book.metadata, audioSeconds: evidence?.audioSeconds,
                        isAbridged: row.book.editionKind?.abridgedForMatching)
                    let found = await worker.lookUp(query, preferAudio: true, language: language, book: context)
                    // A lookup that was cancelled comes back empty: it is not an answer.
                    guard !Task.isCancelled else { return nil }
                    results = found.candidates
                    failed = Set(found.failures.keys)
                    if !found.searched.isEmpty, failed == Set(found.searched),
                       found.failures.values.allSatisfy({ $0 == .notReachable }) {
                        looked.nothingReachable = true
                    }
                }
                guard !Task.isCancelled else { return nil }
                if failed.isEmpty {
                    looked.checks.append(EditionCheck(bookId: row.id, results: results))
                } else {
                    looked.unanswered[row.id] = failed
                }
            }
            return looked
        }
        editionCheck = work
        let looked = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        editionCheck = nil
        isCheckingEdition = false

        var said: String?
        if let looked {
            busyLabel = "Updating…"
            do {
                let titles = Dictionary(books.map { ($0.id, $0.book.title) }) { a, _ in a }
                let outcomes = try await worker.checkEditions(looked.checks)
                said = [
                    Self.editionCheckSummary(outcomes, titles: titles),
                    Self.editionCheckSkippedText(looked, checked: outcomes.count, titles: titles),
                ].compactMap { $0 }.joined(separator: " ").trimmedOrNil
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

    // MARK: The progress sheet's Cancel

    /// What the progress sheet's button that stops the work says; nil while the work
    /// shown cannot be stopped, which is all of it but the lookups of Check Edition.
    public var progressCancelTitle: String? {
        isCheckingEdition && progressSheetLabel != nil ? "Cancel" : nil
    }

    /// Stops the work the progress sheet shows, when it can be stopped.
    public func cancelProgress() {
        guard progressCancelTitle != nil else { return }
        cancelEditionCheck()
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

    static let nothingReachableText = "No lookup source could be reached."

    /// What is said of the books a check passed over because a source did not answer:
    /// "2 books were skipped because Audible and Open Library could not be reached."
    /// Nil when every source answered for every book. `checked`: how many books were
    /// worked out all the same.
    static func editionCheckSkippedText(_ looked: EditionLookups, checked: Int, titles: [Int64: String]) -> String? {
        let skipped = looked.unanswered
        guard !skipped.isEmpty else { return nil }
        let count: String
        if skipped.count == 1, let only = skipped.keys.first {
            let title = titles[only]?.trimmedOrNil.map { "“\($0)”" } ?? "1 book"
            count = "\(title) was skipped"
        } else {
            count = "\(skipped.count) books were skipped"
        }
        if looked.nothingReachable {
            return checked == 0 && skipped.count == 1
                ? Self.nothingReachableText : "\(Self.nothingReachableText) \(count)."
        }
        let failed = skipped.values.reduce(into: Set<LookupSource>()) { $0.formUnion($1) }
        let names = LookupSource.allCases.filter(failed.contains).map(\.nameInSentence)
        return "\(count) because \(Self.list(names)) could not be reached."
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

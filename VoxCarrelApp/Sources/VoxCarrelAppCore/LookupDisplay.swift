import Foundation
import VoxCarrelCore

// What the lookup screens show (plan 5, Task 6): the words and the small decisions that
// are not a view's to make.

extension LookupSession {
    /// V2: whether Search can be pressed: there is something to search for, and nothing
    /// is being applied.
    public var canSearch: Bool {
        phase != .applying && !query.isEmpty
    }

    /// V2: whether the sheet has an ISBN box: the book had an ISBN when the lookup began.
    /// It stays while the box is emptied, so that a number can be typed again.
    public var showsISBNBox: Bool {
        current.isbn?.trimmedOrNil != nil
    }

    /// V2: the same for the Audible ID (the ASIN).
    public var showsAudibleIDBox: Bool {
        current.asin?.trimmedOrNil != nil
    }

    /// V4: what is still to be done once values have been applied.
    public var reminderText: String {
        switch target {
        case .book: "Applied values still need Save."
        case .importEntry: "Applied values are imported with the book."
        }
    }
}

extension LookupSession.Offer {
    /// V2: what the book has now: "Now: Harbour Press", or "Now: —" when it has nothing.
    public var currentText: String {
        "Now: \(current.isEmpty ? "—" : current)"
    }
}

extension LookupQuery {
    /// The ISBN box's text. An emptied box is no ISBN.
    public var isbnText: String {
        get { isbn ?? "" }
        set { isbn = newValue.trimmedOrNil == nil ? nil : newValue }
    }

    /// The Audible ID box's text. An emptied box is no ASIN.
    public var asinText: String {
        get { asin ?? "" }
        set { asin = newValue.trimmedOrNil == nil ? nil : newValue }
    }
}

extension LookupCandidate {
    /// V2: the title, or "Untitled" when it is blank.
    public var titleText: String {
        metadata.title.trimmedOrNil ?? "Untitled"
    }

    /// V2: the authors with commas between them, or "No author".
    public var authorsText: String {
        let authors = metadata.authors.compactMap(\.trimmedOrNil)
        return authors.isEmpty ? "No author" : authors.joined(separator: ", ")
    }
}

extension AppModel {
    // MARK: V6 Result covers

    /// A result's cover if it has been fetched since the lookup opened. Asks nothing of
    /// the network.
    public func cachedLookupThumbnail(for candidate: LookupCandidate) -> Data? {
        candidate.coverURL.flatMap { lookupThumbnails[$0] }
    }

    /// V6: a result's cover, for its row: fetched through the library's lookup service
    /// (so only from the hosts it allows), once however many rows ask, and kept while the
    /// lookup is open. Nil when the result has no cover, when it cannot be fetched or is
    /// no image (it is tried again when asked again), and when no lookup is open.
    ///
    /// Nothing about the lookup or the book changes, and a failure is not reported.
    public func lookupThumbnail(for candidate: LookupCandidate) async -> Data? {
        guard lookup != nil, let worker, let url = candidate.coverURL else { return nil }
        if let data = lookupThumbnails[url] { return data }
        let generation = lookupGeneration
        let load: Task<Data?, Never>
        if let running = lookupThumbnailLoads[url] {
            load = running
        } else {
            load = Task { try? await worker.lookupCover(for: candidate).data }
            lookupThumbnailLoads[url] = load
        }
        let data = await load.value
        // The lookup it was for has closed: its covers went with it.
        guard lookupGeneration == generation else { return nil }
        if lookupThumbnailLoads[url] == load { lookupThumbnailLoads[url] = nil }
        if let data { lookupThumbnails[url] = data }
        return data
    }

    /// The covers of a lookup's results go when it closes or another opens.
    func forgetLookupThumbnails() {
        lookupThumbnailLoads.values.forEach { $0.cancel() }
        lookupThumbnailLoads = [:]
        lookupThumbnails = [:]
    }
}

import Foundation

/// Looks audiobooks up in several Audible stores at once and gives each edition once,
/// with the stores that list it. Stores differ in the editions they have.
public struct AudibleStoresProvider: LookupProvider {
    public let source = LookupSource.audible
    private let stores: [AudibleStore]
    private let providers: [AudibleProvider]

    /// `stores`: the user's own store first; asked in that order, at the same time. A
    /// store named twice is asked once. `limit`: the most results asked of each store.
    public init(http: any HTTPFetching, stores: [AudibleStore], limit: Int = 12) {
        var seen: Set<AudibleStore> = []
        self.stores = stores.filter { seen.insert($0).inserted }
        providers = self.stores.map { AudibleProvider(http: http, store: $0, limit: limit) }
    }

    /// One store failing does not fail the others: throws only when every store
    /// failed, and then the first store's error.
    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        guard !providers.isEmpty else { return [] }
        let answers = await LookupService.askAll(providers, query)

        var found: [[LookupCandidate]] = []
        var firstError: (any Error)?
        for answer in answers {
            switch answer {
            case .success(let candidates): found.append(candidates)
            case .failure(let error): firstError = firstError ?? error
            case nil: break
            }
        }
        if found.isEmpty, let firstError { throw firstError }
        return Self.merged(found)
    }

    /// Every edition once, in the first list's order and then what only later lists
    /// have, in their order. An edition several stores list keeps the first's details
    /// and names all of them.
    static func merged(_ lists: [[LookupCandidate]]) -> [LookupCandidate] {
        var editions: [LookupCandidate] = []
        for list in lists {
            for candidate in list {
                // Never two results of one store: each store's own listing is taken as it is.
                let stores = candidate.edition.stores
                if let index = editions.firstIndex(where: {
                    Set($0.edition.stores).isDisjoint(with: stores) && sameEdition($0, candidate)
                }) {
                    editions[index].edition.stores += stores
                } else {
                    editions.append(candidate)
                }
            }
        }
        return editions
    }

    /// The same title, first author, narrators and length (to the minute). ASINs differ
    /// from store to store and say nothing.
    static func sameEdition(_ a: LookupCandidate, _ b: LookupCandidate) -> Bool {
        guard LookupText.comparable(a.metadata.title) == LookupText.comparable(b.metadata.title) else { return false }
        switch (a.metadata.authors.first, b.metadata.authors.first) {
        case (nil, nil): break
        case (let first?, let second?): guard LookupText.samePerson(first, second) else { return false }
        default: return false
        }
        switch (a.metadata.durationSeconds, b.metadata.durationSeconds) {
        case (nil, nil): break
        case (let first?, let second?): guard abs(first - second) <= 60 else { return false }
        default: return false
        }
        let first = a.metadata.narrators, second = b.metadata.narrators
        return first.allSatisfy { name in second.contains { LookupText.samePerson(name, $0) } }
            && second.allSatisfy { name in first.contains { LookupText.samePerson(name, $0) } }
    }
}

import Foundation
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// Stands in for Open Library, Audible and the network behind them: every `Harness`
/// model looks things up here, so no test reaches the network.
///
/// Each source finds nothing until a test says otherwise with `find`, `fail` or `hold`.
final class FakeLookup: @unchecked Sendable {
    typealias Search = @Sendable (LookupQuery) async throws -> [LookupCandidate]
    typealias Details = @Sendable (LookupCandidate) async throws -> LookupCandidate
    typealias Cover = @Sendable (URL) async throws -> (data: Data, status: Int)

    struct Asked: Equatable {
        var source: LookupSource
        /// The Audible store the service that was asked had been built for.
        var store: AudibleStore
        var query: LookupQuery
    }

    private let lock = NSLock()
    private var searches: [LookupSource: Search] = [:]
    private var detailing: Details = { $0 }
    private var covering: Cover = { _ in throw LookupError.notReachable }
    private var recordedAsked: [Asked] = []
    private var recordedStores: [AudibleStore] = []
    private var recordedDetails: [String] = []
    private var recordedCovers: [URL] = []
    private var recordedCancelled = 0

    /// Every search a source was asked to make, in order.
    var asked: [Asked] { lock.withLock { recordedAsked } }
    /// The store of each service that was built, in order.
    var builtFor: [AudibleStore] { lock.withLock { recordedStores } }
    /// The ids of the candidates details were asked for.
    var detailsAsked: [String] { lock.withLock { recordedDetails } }
    var coverURLs: [URL] { lock.withLock { recordedCovers } }
    /// How many held searches found their task cancelled when they were let go.
    var cancelledSearches: Int { lock.withLock { recordedCancelled } }

    // MARK: Saying what is found

    /// The source answers at once with these.
    func find(_ source: LookupSource, _ candidates: [LookupCandidate]) {
        search(source) { _ in candidates }
    }

    /// The source fails.
    func fail(_ source: LookupSource, _ error: LookupError) {
        search(source) { _ in throw error }
    }

    /// The source does not answer until `gate` is released.
    func hold(_ source: LookupSource, at gate: Gate, then candidates: [LookupCandidate] = []) {
        search(source) { [self] _ in
            await gate.wait()
            if Task.isCancelled { lock.withLock { recordedCancelled += 1 } }
            return candidates
        }
    }

    func search(_ source: LookupSource, _ search: @escaping Search) {
        lock.withLock { searches[source] = search }
    }

    func details(_ details: @escaping Details) {
        lock.withLock { detailing = details }
    }

    /// Every cover address answers with this image.
    func cover(_ data: Data, status: Int = 200) {
        cover { _ in (data, status) }
    }

    func cover(_ cover: @escaping Cover) {
        lock.withLock { covering = cover }
    }

    // MARK: The service

    /// What `AppModel` is given in place of `LookupService.standard(store:)`.
    func service(for store: AudibleStore) -> LookupService {
        lock.withLock { recordedStores.append(store) }
        return LookupService(
            providers: [
                Provider(source: .openLibrary, store: store, fake: self),
                Provider(source: .audible, store: store, fake: self),
            ],
            http: HTTP(fake: self))
    }

    private struct Provider: LookupProvider {
        let source: LookupSource
        let store: AudibleStore
        let fake: FakeLookup

        func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
            let search = fake.lock.withLock {
                fake.recordedAsked.append(Asked(source: source, store: store, query: query))
                return fake.searches[source]
            }
            return try await search?(query) ?? []
        }

        func details(for candidate: LookupCandidate) async throws -> LookupCandidate {
            let details = fake.lock.withLock {
                fake.recordedDetails.append(candidate.id)
                return fake.detailing
            }
            return try await details(candidate)
        }
    }

    private struct HTTP: HTTPFetching {
        let fake: FakeLookup

        func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int) {
            let cover = fake.lock.withLock {
                fake.recordedCovers.append(url)
                return fake.covering
            }
            return try await cover(url)
        }
    }
}

/// A found book, for the lookup tests.
func foundBook(
    _ source: LookupSource, _ key: String, title: String, authors: [String] = [], cover: Bool = false,
    moreDetails: Bool = false, _ change: (inout BookMetadata) -> Void = { _ in }
) -> LookupCandidate {
    var metadata = BookMetadata(title: title, authors: authors)
    change(&metadata)
    let host = source == .audible ? "m.media-amazon.com" : "covers.openlibrary.org"
    return LookupCandidate(
        id: "\(source.rawValue):\(key)", source: source, metadata: metadata,
        coverURL: cover ? URL(string: "https://\(host)/\(key).jpg") : nil,
        note: source.title, hasMoreDetails: moreDetails)
}

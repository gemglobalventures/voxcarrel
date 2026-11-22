import Foundation
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// Stands in for Open Library, Audible, the Library of Congress and the network behind
/// them: every `Harness` model looks things up here, so no test reaches the network.
/// Like the real service it has a provider only for a source that is on.
///
/// Each source finds nothing until a test says otherwise with `find`, `fail` or `hold`.
final class FakeLookup: @unchecked Sendable {
    typealias Search = @Sendable (LookupQuery) async throws -> [LookupCandidate]
    typealias Details = @Sendable (LookupCandidate) async throws -> LookupCandidate
    typealias Cover = @Sendable (URL) async throws -> (data: Data, status: Int)

    struct Asked: Equatable {
        var source: LookupSource
        /// The user's own Audible store, as the service that was asked had been built for it.
        var store: AudibleStore
        var query: LookupQuery
        /// Every Audible store that service had been built to search, the user's own first.
        var stores: [AudibleStore] = []
    }

    private let lock = NSLock()
    private var searches: [LookupSource: Search] = [:]
    private var detailing: Details = { $0 }
    private var covering: Cover = { _ in throw LookupError.notReachable }
    private var recordedAsked: [Asked] = []
    private var recordedStores: [AudibleStore] = []
    private var recordedConfigurations: [LookupConfiguration] = []
    private var narratorsNotFound: [LookupSource: String] = [:]
    private var recordedDetails: [String] = []
    private var recordedCovers: [URL] = []
    private var recordedCancelled = 0
    /// What stands in for the Audible stores' catalogues when a series is asked about.
    let catalogue = FakeCatalogue()

    /// Every search a source was asked to make, in order.
    var asked: [Asked] { lock.withLock { recordedAsked } }
    /// The user's own store of each service that was built, in order.
    var builtFor: [AudibleStore] { lock.withLock { recordedStores } }
    /// What each service was built from, in order.
    var built: [LookupConfiguration] { lock.withLock { recordedConfigurations } }
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

    /// The source says it found nothing read by this narrator and searched again
    /// without the name; nil for it to say nothing.
    func narratorNotFound(_ source: LookupSource, _ narrator: String?) {
        lock.withLock { narratorsNotFound[source] = narrator }
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

    /// What `AppModel` is given in place of `LookupService.standard(_:)`: a provider
    /// for each source that is on, and none for one that is off.
    func service(for configuration: LookupConfiguration) -> LookupService {
        let store = configuration.audibleStores.first ?? .us
        lock.withLock {
            recordedStores.append(store)
            recordedConfigurations.append(configuration)
        }
        return LookupService(
            providers: LookupSource.allCases.filter(configuration.sources.contains).map {
                Provider(source: $0, store: store, stores: configuration.audibleStores, fake: self)
            },
            http: HTTP(fake: self),
            // As the real service: the stores a series is asked of, none when Audible is off.
            audibleStores: configuration.sources.contains(.audible) ? configuration.audibleStores : [])
    }

    /// A service for Open Library and Audible in one store: the settings a model begins with, less the other stores.
    func service(store: AudibleStore) -> LookupService {
        service(for: LookupConfiguration(sources: [.openLibrary, .audible], audibleStores: [store]))
    }

    private struct Provider: LookupProvider {
        let source: LookupSource
        let store: AudibleStore
        let stores: [AudibleStore]
        let fake: FakeLookup

        func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
            let search = fake.lock.withLock {
                fake.recordedAsked.append(Asked(source: source, store: store, query: query, stores: stores))
                return fake.searches[source]
            }
            return try await search?(query) ?? []
        }

        func answer(to query: LookupQuery) async throws -> LookupAnswer {
            let candidates = try await search(query)
            return LookupAnswer(candidates: candidates, narratorNotFound: fake.lock.withLock { fake.narratorsNotFound[source] })
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

        func get(
            _ url: URL, headers: [String: String], maxBytes: Int, redirectHosts: Set<String>,
            insecure: Set<InsecureOrigin>
        ) async throws -> (data: Data, status: Int) {
            if url.path.hasPrefix(FakeCatalogue.path) { return try await fake.catalogue.answer(url) }
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
    thumbnail: Bool = false, moreDetails: Bool = false, _ change: (inout BookMetadata) -> Void = { _ in }
) -> LookupCandidate {
    var metadata = BookMetadata(title: title, authors: authors)
    change(&metadata)
    let host = source == .audible ? "m.media-amazon.com" : "covers.openlibrary.org"
    return LookupCandidate(
        id: "\(source.rawValue):\(key)", source: source, metadata: metadata,
        coverURL: cover ? URL(string: "https://\(host)/\(key).jpg") : nil,
        thumbnailURL: thumbnail ? URL(string: "https://\(host)/\(key)-small.jpg") : nil,
        note: source.title, hasMoreDetails: moreDetails)
}

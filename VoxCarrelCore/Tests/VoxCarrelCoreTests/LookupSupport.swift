import Foundation
@testable import VoxCarrelCore

/// A recorded response from `Fixtures/Lookup`, by file name without its extension.
func fixture(_ name: String, type: String = "json") -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: type, subdirectory: "Fixtures/Lookup"),
          let data = try? Data(contentsOf: url)
    else { fatalError("missing lookup fixture \(name).\(type)") }
    return data
}

/// The network seam for tests: answers from a closure and records everything asked for.
final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    struct Request: Equatable {
        var url: URL
        var headers: [String: String]
    }

    /// What each request allowed, in the order of `requests`.
    struct Limits: Equatable {
        var maxBytes: Int
        var redirectHosts: Set<String>
        /// The addresses the request was allowed to reach without encryption.
        var insecure: Set<InsecureOrigin> = []
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var recordedLimits: [Limits] = []
    private let answer: @Sendable (URL) throws -> (data: Data, status: Int)

    /// `answer` gives the response for a URL, or throws what the fetch should throw.
    init(_ answer: @escaping @Sendable (URL) throws -> (data: Data, status: Int)) {
        self.answer = answer
    }

    /// The same body and status for every URL.
    convenience init(data: Data, status: Int = 200) {
        self.init { _ in (data, status) }
    }

    /// Every request fails with `error`.
    convenience init(throwing error: any Error) {
        self.init { _ in throw error }
    }

    var requests: [Request] { lock.withLock { recorded } }
    var limits: [Limits] { lock.withLock { recordedLimits } }
    var urls: [URL] { requests.map(\.url) }

    func get(
        _ url: URL, headers: [String: String], maxBytes: Int, redirectHosts: Set<String>, insecure: Set<InsecureOrigin>
    ) async throws -> (data: Data, status: Int) {
        lock.withLock {
            recorded.append(Request(url: url, headers: headers))
            recordedLimits.append(Limits(maxBytes: maxBytes, redirectHosts: redirectHosts, insecure: insecure))
        }
        return try answer(url)
    }
}

/// The query items of `url` as a dictionary (decoded), for order-free comparison.
func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

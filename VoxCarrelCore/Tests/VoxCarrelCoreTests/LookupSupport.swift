import Foundation
@testable import VoxCarrelCore

/// A recorded response from `Fixtures/Lookup`, by file name without ".json".
func fixture(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Lookup"),
          let data = try? Data(contentsOf: url)
    else { fatalError("missing lookup fixture \(name).json") }
    return data
}

/// The network seam for tests: answers from a closure and records everything asked for.
final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    struct Request: Equatable {
        var url: URL
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
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
    var urls: [URL] { requests.map(\.url) }

    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int) {
        lock.withLock { recorded.append(Request(url: url, headers: headers)) }
        return try answer(url)
    }
}

/// The query items of `url` as a dictionary (decoded), for order-free comparison.
func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

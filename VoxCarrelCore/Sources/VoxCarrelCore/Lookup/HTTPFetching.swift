import Foundation

/// The one way the lookup code reaches the network, so tests can stand in for it.
public protocol HTTPFetching: Sendable {
    /// The body and HTTP status of a GET. An error status is returned, not thrown.
    /// Throws `LookupError.notReachable` when there was no answer.
    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int)
}

/// `HTTPFetching` over `URLSession`: no cookies, no stored credentials, nothing kept on disk.
public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        self.init(timeout: timeout, protocolClasses: nil)
    }

    /// `protocolClasses` lets tests answer requests inside the process.
    init(timeout: TimeInterval, protocolClasses: [AnyClass]?) {
        let configuration = Self.configuration(timeout: timeout)
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        return configuration
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            // Redirects are followed: the session's default.
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LookupError.unreadable }
            return (data, http.statusCode)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// What `get` throws for an error from the session: never a raw `URLError`.
    static func mapped(_ error: any Error) -> any Error {
        if let known = error as? LookupError { return known }
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return LookupError.notReachable
    }
}

/// What every lookup request has in common.
enum LookupRequest {
    /// The lookup client's version, sent in the User-Agent.
    static let version = "0.1"
    /// Names the app and nothing about the user or the machine.
    static let userAgent = "VoxCarrel/\(version) (https://voxcarrel.app)"
    static let headers = ["User-Agent": userAgent, "Accept": "application/json"]

    /// Characters left as they are in a query value. Everything else is percent-encoded,
    /// so `&`, `+`, `#`, `=` and spaces in a title cannot change the request's shape.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")

    /// An `https` URL. `path` must already be safe to use as it is.
    static func url(host: String, path: String, query: [(name: String, value: String)]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(encoded($0.name))=\(encoded($0.value))" }
                .joined(separator: "&")
        }
        return components.url
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The JSON object at `url`. Throws `.refused` for any status but 200 and `.unreadable`
    /// when the body is not a JSON object.
    static func object(at url: URL, http: any HTTPFetching) async throws -> [String: Any] {
        let answer = try await http.get(url, headers: headers)
        guard answer.status == 200 else { throw LookupError.refused(status: answer.status) }
        guard let object = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any] else {
            throw LookupError.unreadable
        }
        return object
    }
}

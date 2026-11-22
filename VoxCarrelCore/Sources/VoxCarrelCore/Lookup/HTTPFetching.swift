import Foundation

/// The one way the lookup code reaches the network, so tests can stand in for it.
public protocol HTTPFetching: Sendable {
    /// The body and HTTP status of a GET. An error status is returned, not thrown.
    ///
    /// - Parameters:
    ///   - maxBytes: The most the body may be. A longer one is not read to its end:
    ///     `LookupError.unreadable` is thrown.
    ///   - redirectHosts: Where a redirect may lead: to `https` on one of these hosts
    ///     or a subdomain of one. Any other redirect is not followed, and
    ///     `LookupError.refused` is thrown with the redirect's status.
    ///
    /// Throws `LookupError.notReachable` when there was no answer.
    func get(_ url: URL, headers: [String: String], maxBytes: Int, redirectHosts: Set<String>) async throws
        -> (data: Data, status: Int)
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

    /// Whether a redirect to `url` may be followed: `https`, to one of `hosts` or a subdomain of one.
    static func mayRedirect(to url: URL?, hosts: Set<String>) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        return hosts.contains { allowed in
            let allowed = allowed.lowercased()
            return !allowed.isEmpty && (host == allowed || host.hasSuffix("." + allowed))
        }
    }

    /// Decides each redirect of one request, and remembers one it refused.
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let hosts: Set<String>
        private let lock = NSLock()
        private var status: Int?

        init(hosts: Set<String>) {
            self.hosts = hosts
        }

        /// The status of a redirect that was not followed; nil when none was refused.
        var refusedStatus: Int? { lock.withLock { status } }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            if URLSessionFetcher.mayRedirect(to: request.url, hosts: hosts) {
                completionHandler(request)
            } else {
                lock.withLock { status = response.statusCode }
                completionHandler(nil)
                // Nothing more is wanted from this request.
                task.cancel()
            }
        }
    }

    public func get(_ url: URL, headers: [String: String], maxBytes: Int, redirectHosts: Set<String>) async throws
        -> (data: Data, status: Int)
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let redirects = Redirects(hosts: redirectHosts)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            if let status = redirects.refusedStatus {
                bytes.task.cancel()
                throw LookupError.refused(status: status)
            }
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw LookupError.unreadable
            }
            // Said to be too long: not read at all.
            guard response.expectedContentLength <= Int64(maxBytes) else {
                bytes.task.cancel()
                throw LookupError.unreadable
            }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maxBytes else {
                    // Longer than it said, or than is wanted: the rest is not read.
                    bytes.task.cancel()
                    throw LookupError.unreadable
                }
                data.append(byte)
            }
            return (data, http.statusCode)
        } catch {
            if let status = redirects.refusedStatus { throw LookupError.refused(status: status) }
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

    /// The most a source's answer to a search may be.
    static let jsonByteLimit = 5 * 1024 * 1024

    /// The JSON object at `url`. Throws `.refused` for any status but 200 (a redirect to
    /// another host included: it is not followed) and `.unreadable` when the body is not
    /// a JSON object or is longer than `jsonByteLimit`.
    static func object(at url: URL, http: any HTTPFetching) async throws -> [String: Any] {
        let answer = try await http.get(
            url, headers: headers, maxBytes: jsonByteLimit, redirectHosts: url.host.map { [$0] } ?? [])
        guard answer.status == 200 else { throw LookupError.refused(status: answer.status) }
        guard answer.data.count <= jsonByteLimit else { throw LookupError.unreadable }
        guard let object = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any] else {
            throw LookupError.unreadable
        }
        return object
    }
}

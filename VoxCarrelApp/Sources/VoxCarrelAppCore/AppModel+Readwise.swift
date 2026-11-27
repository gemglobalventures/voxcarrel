import Foundation
import VoxCarrelCore

extension AppModel {
    /// Makes one request of Readwise's own API with the owner's token, for an extension
    /// that has something to ask of Readwise or to give it. The token is put on the
    /// request here and is never handed out.
    ///
    /// - Parameters:
    ///   - path: The path under `https://readwise.io`, as in "/api/v2/highlights/".
    ///   - body: JSON to send; nil for a request with none.
    /// - Returns: The answer's body and HTTP status; nil when no token is kept, or the
    ///   path is not one of Readwise's API. Nothing is sent then.
    public func askReadwise(path: String, method: String = "GET", body: Data? = nil) async throws
        -> (data: Data, status: Int)?
    {
        guard let token = readwiseTokens.load()?.trimmedOrNil, path.hasPrefix("/api/"),
              let url = URL(string: "https://readwise.io" + path), url.host == "readwise.io"
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await audibleTransport.send(request)
    }
}

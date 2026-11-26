import Foundation
import Security

/// The keys of a device registered with an Audible account: what lets the app read
/// that account's library as the Audible app on a phone can. They are not the
/// account's password, and are kept only on this Mac.
public struct AudibleAccount: Codable, Equatable, Sendable {
    public var store: AudibleStore
    /// The serial number made up for the device when it was registered.
    public var serial: String
    public var adpToken: String
    /// The device's RSA private key: PEM, or the bare base64 of its PKCS#1 form.
    public var devicePrivateKey: String
    public var accessToken: String
    public var refreshToken: String
    /// What Amazon calls the device, for telling the owner which one to remove.
    public var deviceName: String?

    public init(
        store: AudibleStore, serial: String, adpToken: String, devicePrivateKey: String, accessToken: String,
        refreshToken: String, deviceName: String?
    ) {
        self.store = store
        self.serial = serial
        self.adpToken = adpToken
        self.devicePrivateKey = devicePrivateKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceName = deviceName
    }
}

public enum AudibleAccountError: Error, Equatable {
    /// The device's key is not one a signature can be made with.
    case unusableKey
    /// Amazon did not register the device; its own word for why, when it gave one.
    case notRegistered(String?)
    /// The address given holds no sign-in code, or is not Amazon's.
    case noSignInCode
    /// Audible refused the keys: the device was removed, or the keys have run out.
    case refused(Int)
    /// There was no answer: no network, or the address could not be reached.
    case notReachable
    /// Amazon answered that it cannot serve the request for now (too many at once, or
    /// a fault of its own). Nothing is wrong with the link; a later try may do.
    case busy(Int)
    /// Amazon answered, but not with what was asked for: in a form this code does not know.
    case unreadable
}

extension AudibleAccountError {
    /// True for an HTTP status that says "not now": too many requests, or a fault at
    /// the far end.
    static func saysNotNow(_ status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }
}

/// What a request to Audible must carry to be believed.
public enum AudibleSigner {
    /// The headers that sign one request with the account's device key.
    ///
    /// - Parameters:
    ///   - path: The address's path with its query, as it is sent.
    ///   - date: When the request is made; part of what is signed.
    public static func headers(
        method: String, path: String, body: Data = Data(), account: AudibleAccount, date: Date = Date()
    ) throws -> [String: String] {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // As the phone app writes it: no zone name but a final Z.
        let stamp = format.string(from: date)
        let text = "\(method)\n\(path)\n\(stamp)\n\(String(decoding: body, as: UTF8.self))\n\(account.adpToken)"
        let signature = try sign(Data(text.utf8), key: account.devicePrivateKey)
        return [
            "x-adp-token": account.adpToken,
            "x-adp-alg": "SHA256withRSA:1.0",
            "x-adp-signature": "\(signature.base64EncodedString()):\(stamp)",
        ]
    }

    /// The bytes of a key given as PEM or as bare base64.
    static func keyData(_ key: String) -> Data? {
        let lines = key.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }
        return Data(base64Encoded: lines.joined(), options: [.ignoreUnknownCharacters])
    }

    static func sign(_ data: Data, key: String) throws -> Data {
        guard let bytes = keyData(key) else { throw AudibleAccountError.unusableKey }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let secKey = SecKeyCreateWithData(bytes as CFData, attributes as CFDictionary, nil),
              let signature = SecKeyCreateSignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil)
        else { throw AudibleAccountError.unusableKey }
        return signature as Data
    }
}

/// How the app reaches Amazon and Audible for an account: a signed GET, and the POSTs
/// that register a device and remove it.
public protocol AudibleTransport: Sendable {
    /// The body and the HTTP status. Throws `AudibleAccountError.notReachable` when
    /// there was no answer.
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

/// The transport that really goes out: no cookies kept, nothing cached, and no
/// redirect followed to anywhere.
public struct AudibleNetwork: AudibleTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw AudibleAccountError.notReachable
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}

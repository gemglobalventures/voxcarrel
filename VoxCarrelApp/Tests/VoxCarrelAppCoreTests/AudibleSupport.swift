import Foundation
import Security
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// Amazon and Audible as a test has them answer: by the path of the address asked.
/// Nothing goes out, and what was asked is kept.
final class FakeAudibleTransport: AudibleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAnswers: [String: (Data, Int)] = [:]
    private var storedAsked: [URLRequest] = []
    private var storedFails = false
    private var storedGate: Gate?

    /// The requests made, in order.
    var asked: [URLRequest] { lock.withLock { storedAsked } }

    /// True has every request fail as if there were no network.
    var fails: Bool {
        get { lock.withLock { storedFails } }
        set { lock.withLock { storedFails = newValue } }
    }

    /// Every request waits here before it is answered, when there is one.
    var gate: Gate? {
        get { lock.withLock { storedGate } }
        set { lock.withLock { storedGate = newValue } }
    }

    func answer(_ path: String, with object: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        lock.withLock { storedAnswers[path] = (data, status) }
    }

    /// An answer for one address of a path that many are asked by: the path with this query.
    func answer(_ path: String, query: String, with object: Any, status: Int = 200) {
        answer(path + "?" + query, with: object, status: status)
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        lock.withLock { storedAsked.append(request) }
        await gate?.wait()
        if fails { throw AudibleAccountError.notReachable }
        let path = request.url?.path ?? ""
        let whole = path + "?" + (request.url?.query ?? "")
        let answer = lock.withLock { storedAnswers[whole] ?? storedAnswers[path] } ?? (Data("{}".utf8), 404)
        return (answer.0, answer.1)
    }

    // MARK: Answers

    /// Amazon registers the device under this name.
    func registers(as name: String = "Ann's 2nd Audible for iPhone") {
        answer("/auth/register", with: ["response": ["success": [
            "tokens": [
                "bearer": ["access_token": "ACCESS", "refresh_token": "REFRESH", "expires_in": "3600"],
                "mac_dms": ["adp_token": "{adp}", "device_private_key": AudibleSamples.testKey],
            ],
            "extensions": ["device_info": ["device_name": name]],
        ]]])
    }

    /// The account's library holds these items. Fewer than a page of them.
    func holds(_ items: [[String: Any]]) {
        answer("/1.0/library", with: ["items": items])
    }
}

enum AudibleSamples {
    /// A key of the tests' own, made here: never anybody's real one.
    static let testKey: String = {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        return (SecKeyCopyExternalRepresentation(key, nil)! as Data).base64EncodedString()
    }()

    static func account(_ store: AudibleStore = .us, name: String? = "Ann's 2nd Audible for iPhone") -> AudibleAccount {
        AudibleAccount(
            store: store, serial: "SERIAL", adpToken: "{adp-token}", devicePrivateKey: testKey,
            accessToken: "access", refreshToken: "refresh", deviceName: name)
    }

    /// One item of a library, as Audible answers.
    static func item(
        _ asin: String, _ title: String, author: String = "Ann Author", finished: Bool = false, percent: Double = 0,
        cover: String? = "https://m.media-amazon.com/images/I/x._SL500_.jpg"
    ) -> [String: Any] {
        var item: [String: Any] = [
            "asin": asin, "title": title, "authors": [["asin": "A1", "name": author]],
            "narrators": [["name": "Nell Narrator"]], "runtime_length_min": 600, "is_finished": finished,
            "percent_complete": percent, "purchase_date": "2021-03-04T05:06:07.890Z", "release_date": "2019-05-01",
            "publisher_name": "A Press", "language": "english", "content_delivery_type": "SinglePartBook",
        ]
        if let cover { item["product_images"] = ["500": cover] }
        return item
    }

    /// The address Amazon sends the browser to after a sign-in, with its one-time code.
    static func landing(_ store: AudibleStore = .us, code: String = "CODE123") -> String {
        "https://www.amazon.\(store.amazonDomain)/ap/maplanding?openid.assoc_handle=amzn_audible_ios_\(store.rawValue)"
            + "&openid.oa2.authorization_code=\(code)&openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0"
    }

    /// The smallest thing that is taken for a JPEG.
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
}

/// What stands in for the clipboard: it holds what a test puts in it.
@MainActor
final class FakeClipboard {
    var text: String?
    /// How many times it was read.
    private(set) var readCount = 0

    func read() -> String? {
        readCount += 1
        return text
    }
}

/// What stands in for the download of covers: it answers from what a test gave it,
/// and keeps the addresses asked.
final class FakeCoverFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAsked: [URL] = []
    private var storedAnswers: [URL: Data] = [:]
    private var storedDefault: Data? = AudibleSamples.jpeg

    var asked: [URL] { lock.withLock { storedAsked } }

    /// What an address with no answer of its own gives; nil for nothing.
    var everything: Data? {
        get { lock.withLock { storedDefault } }
        set { lock.withLock { storedDefault = newValue } }
    }

    func give(_ data: Data, for address: String) {
        lock.withLock { storedAnswers[URL(string: address)!] = data }
    }

    func fetch(_ url: URL) async -> Data? {
        lock.withLock {
            storedAsked.append(url)
            return storedAnswers[url] ?? storedDefault
        }
    }
}

extension Harness {
    /// Links the model to an account, as if it had been linked before.
    func link(_ account: AudibleAccount = AudibleSamples.account()) throws {
        try audibleKeys.save(account)
        model.readAudibleKeys()
    }

    /// Opens the import sheet and waits for it to have read the library.
    func audibleImportRead() async throws -> AudibleImportSession {
        model.beginAudibleImport()
        let session = try #require(model.audibleImport)
        await session.reading?.value
        return session
    }
}

import CryptoKit
import Foundation

/// Linking the app to an Audible account. The owner signs in on Amazon's own page, in
/// their browser; the app never has the password. What comes back to the app is a
/// one-time code in the address Amazon sends the browser to, which the app exchanges
/// for the keys of a device registered with the account.
public enum AudibleLink {
    /// What the Audible app for iPhone says it is: Amazon registers devices by these.
    static let deviceType = "A2CZJZGLK2JJVM"
    static let appVersion = "4.60"
    static let osVersion = "26.2"
    static let softwareVersion = "46000856"

    /// One attempt to link: what is made up for it, and where the owner signs in.
    public struct Attempt: Equatable, Sendable {
        public var store: AudibleStore
        public var serial: String
        /// Kept by the app; only a digest of it goes into the address.
        public var verifier: String
        /// Amazon's sign-in page, to be opened in the owner's browser.
        public var signInURL: URL

        var clientId: String { clientId(serial: serial) }

        func clientId(serial: String) -> String {
            Data((serial + "#" + AudibleLink.deviceType).utf8).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Begins an attempt. `random` is for tests; the system's generator otherwise.
    public static func begin(
        store: AudibleStore, random: () -> UInt8 = { UInt8.random(in: .min ... .max) }
    ) -> Attempt? {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let serial = String((0..<40).map { _ in letters[Int(random()) % letters.count] })
        let verifier = base64URL(Data((0..<32).map { _ in random() }))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var attempt = Attempt(store: store, serial: serial, verifier: verifier, signInURL: URL(fileURLWithPath: "/"))
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.amazon.\(store.amazonDomain)"
        parts.path = "/ap/signin"
        let query: [(String, String)] = [
            ("openid.oa2.response_type", "code"),
            ("openid.oa2.code_challenge_method", "S256"),
            ("openid.oa2.code_challenge", challenge),
            ("openid.return_to", "https://www.amazon.\(store.amazonDomain)/ap/maplanding"),
            ("openid.assoc_handle", "amzn_audible_ios_\(store.rawValue)"),
            ("openid.identity", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("pageId", "amzn_audible_ios"),
            ("accountStatusPolicy", "P1"),
            ("openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("openid.mode", "checkid_setup"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"),
            ("openid.oa2.client_id", "device:\(attempt.clientId)"),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"),
            ("marketPlaceId", store.marketplaceId),
            ("openid.oa2.scope", "device_auth_access"),
            ("forceMobileLayout", "true"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"),
            ("openid.pape.max_auth_age", "0"),
        ]
        parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { return nil }
        attempt.signInURL = url
        return attempt
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The one-time code in the address Amazon sent the browser to after sign-in; nil
    /// for any text that is not such an address on Amazon's own site for this store.
    public static func signInCode(in text: String, for attempt: Attempt) -> String? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.host == "www.amazon.\(attempt.store.amazonDomain)",
              let code = parts.queryItems?.first(where: { $0.name == "openid.oa2.authorization_code" })?.value,
              !code.isEmpty
        else { return nil }
        return code
    }

    /// Registers the device with the account the owner signed in to, and gives its keys.
    public static func register(
        code: String, attempt: Attempt, transport: any AudibleTransport
    ) async throws -> AudibleAccount {
        let domain = attempt.store.amazonDomain
        let body: [String: Any] = [
            "requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
            "cookies": ["website_cookies": [Any](), "domain": ".amazon.\(domain)"],
            "registration_data": [
                "domain": "Device", "app_version": appVersion, "device_serial": attempt.serial,
                "device_type": deviceType,
                "device_name": "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone",
                "os_version": osVersion, "software_version": softwareVersion, "device_model": "iPhone",
                "app_name": "Audible",
            ],
            "auth_data": [
                "client_id": attempt.clientId, "authorization_code": code, "code_verifier": attempt.verifier,
                "code_algorithm": "SHA-256", "client_domain": "DeviceLegacy",
            ],
            "requested_extensions": ["device_info", "customer_info"],
        ]
        guard let url = URL(string: "https://api.amazon.\(domain)/auth/register") else { throw AudibleAccountError.unreadable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport.send(request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let response = answer?["response"] as? [String: Any]
        guard status == 200, let success = response?["success"] as? [String: Any],
              let tokens = success["tokens"] as? [String: Any],
              let bearer = tokens["bearer"] as? [String: Any], let device = tokens["mac_dms"] as? [String: Any],
              let access = bearer["access_token"] as? String, let refresh = bearer["refresh_token"] as? String,
              let adp = device["adp_token"] as? String, let key = device["device_private_key"] as? String
        else {
            // Amazon's word for why, which names nobody.
            throw AudibleAccountError.notRegistered((response?["error"] as? [String: Any])?["code"] as? String)
        }
        let info = (success["extensions"] as? [String: Any])?["device_info"] as? [String: Any]
        return AudibleAccount(
            store: attempt.store, serial: attempt.serial, adpToken: adp, devicePrivateKey: key, accessToken: access,
            refreshToken: refresh, deviceName: info?["device_name"] as? String)
    }

    /// Asks Amazon to remove the device. True when Amazon confirmed; false when it did
    /// not (the keys may have run out), and the owner removes it in their account.
    public static func unregister(_ account: AudibleAccount, transport: any AudibleTransport) async throws -> Bool {
        guard let url = URL(string: "https://api.amazon.\(account.store.amazonDomain)/auth/deregister") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deregister_all_existing_accounts": false])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        return try await transport.send(request).status == 200
    }
}

extension AudibleStore {
    /// The ending of Amazon's own address for this store: "com", "co.uk".
    public var amazonDomain: String {
        switch self {
        case .us: "com"
        case .uk: "co.uk"
        case .au: "com.au"
        case .ca: "ca"
        case .de: "de"
        case .fr: "fr"
        case .it: "it"
        case .es: "es"
        case .jp: "co.jp"
        case .in: "in"
        case .br: "com.br"
        }
    }

    /// Amazon's own name for the store, which its sign-in page asks for.
    public var marketplaceId: String {
        switch self {
        case .us: "AF2M0KC94RCEA"
        case .uk: "A2I9A3Q2GNFNGQ"
        case .au: "AN7EY7DTAW63G"
        case .ca: "A2CQZ5RBY40XE"
        case .de: "AN7V1F1VY261K"
        case .fr: "A2728XDNODOQ8T"
        case .it: "A2N7FU2W2BU2ZC"
        case .es: "ALMIKO4SZCSAR"
        case .jp: "A1QAP3MOU4173J"
        case .in: "AJO3FBRUE6J4S"
        case .br: "A10J1VAYUDTYRN"
        }
    }
}

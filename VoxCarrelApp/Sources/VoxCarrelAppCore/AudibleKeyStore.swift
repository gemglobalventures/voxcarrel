import Foundation
import Security
import VoxCarrelCore

/// Where the keys of the linked Audible account are kept. The app's own is the Mac's
/// Keychain, or a private file for a build no developer signed (`AudibleKeyStores`);
/// tests use one that only remembers.
///
/// The keys are never written anywhere else: not to the preferences, not to a log.
public protocol AudibleKeyStore: Sendable {
    /// The account that is linked; nil when none is.
    func load() -> AudibleAccount?
    /// Keeps the account, in place of any kept before.
    func save(_ account: AudibleAccount) throws
    func remove()
}

/// The keys could not be put in the Keychain.
public struct AudibleKeyStoreError: Error, Equatable {
    /// The Keychain's own number for why.
    public var status: Int32
}

/// The keys as one item of the Mac's Keychain: readable only while the Mac is unlocked,
/// kept on this Mac alone, and never synchronised to iCloud.
public struct KeychainAudibleKeyStore: AudibleKeyStore {
    public init() {}

    /// What the item is found by.
    static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.voxcarrel.VoxCarrel.audible",
            kSecAttrAccount as String: "device",
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// When the item can be read.
    static var whenReadable: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    public func load() -> AudibleAccount? {
        var query = Self.item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data
        else { return nil }
        return try? JSONDecoder().decode(AudibleAccount.self, from: data)
    }

    public func save(_ account: AudibleAccount) throws {
        let data = try JSONEncoder().encode(account)
        remove()
        var adding = Self.item
        adding[kSecValueData as String] = data
        adding[kSecAttrLabel as String] = "VoxCarrel Audible link"
        adding[kSecAttrAccessible as String] = Self.whenReadable
        var status = SecItemAdd(adding as CFDictionary, nil)
        if status == errSecParam {
            // A keychain that does not take that attribute keeps its items on this Mac anyway.
            adding[kSecAttrAccessible as String] = nil
            status = SecItemAdd(adding as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AudibleKeyStoreError(status: status) }
    }

    public func remove() {
        SecItemDelete(Self.item as CFDictionary)
    }
}

/// The keys as one file that only the owner's account on this Mac can read.
///
/// For a build of the app that no developer's certificate has signed: the Keychain
/// lets an item be read only by the very build that made it, and would ask for the
/// login password again after every rebuild.
public struct FileAudibleKeyStore: AudibleKeyStore {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/VoxCarrel/audible-account.json` in the owner's Library.
    public static var standardURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("VoxCarrel", isDirectory: true).appendingPathComponent("audible-account.json")
    }

    public func load() -> AudibleAccount? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AudibleAccount.self, from: data)
    }

    public func save(_ account: AudibleAccount) throws {
        let data = try JSONEncoder().encode(account)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Made private before anything is in it, then filled.
        remove()
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw AudibleKeyStoreError(status: -1) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum AudibleKeyStores {
    /// Where this build of the app keeps the keys: the Keychain when a developer's
    /// certificate signed it, a private file when none did.
    public static func standard() -> any AudibleKeyStore {
        isSignedByADeveloper ? KeychainAudibleKeyStore() : FileAudibleKeyStore(url: FileAudibleKeyStore.standardURL)
    }

    /// True when the running app carries a team's signature.
    static var isSignedByADeveloper: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any]
        else { return false }
        return (details[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }
}

/// Keys that are only remembered while the process runs: for tests.
public final class InMemoryAudibleKeyStore: AudibleKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var account: AudibleAccount?

    public init() {}

    public func load() -> AudibleAccount? {
        lock.withLock { account }
    }

    public func save(_ account: AudibleAccount) throws {
        lock.withLock { self.account = account }
    }

    public func remove() {
        lock.withLock { account = nil }
    }
}

/// A link made earlier on this Mac and kept in a file: the same keys, under the names
/// the file gives them.
enum AudibleLinkFile {
    /// Where such a file is, in the owner's home folder.
    static var standard: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voxcarrel/audible.json", isDirectory: false)
    }

    private struct Stored: Decodable {
        var country: String
        var serial: String
        var adp_token: String
        var device_private_key: String
        var access_token: String
        var refresh_token: String
        var device_name: String?
    }

    /// The account the file holds; nil when there is no such file, or it is not one.
    /// The file is only read.
    static func account(at url: URL) -> AudibleAccount? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size < 1_000_000,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let store = AudibleStore(rawValue: stored.country.lowercased()),
              !stored.adp_token.isEmpty, !stored.device_private_key.isEmpty
        else { return nil }
        return AudibleAccount(
            store: store, serial: stored.serial, adpToken: stored.adp_token,
            devicePrivateKey: stored.device_private_key, accessToken: stored.access_token,
            refreshToken: stored.refresh_token, deviceName: stored.device_name)
    }
}

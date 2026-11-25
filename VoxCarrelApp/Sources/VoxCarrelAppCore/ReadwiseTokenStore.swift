import Foundation
import Security

/// Where the owner's Readwise token is kept. The app's own is the Mac's Keychain, or a
/// private file for a build no developer signed (`ReadwiseTokenStores`); tests use one
/// that only remembers.
///
/// The token is never written anywhere else: not to the preferences, not to a log.
public protocol ReadwiseTokenStore: Sendable {
    /// The token that is saved; nil when none is.
    func load() -> String?
    /// Keeps the token, in place of any kept before.
    func save(_ token: String) throws
    func remove()
}

/// The token could not be kept.
public struct ReadwiseTokenStoreError: Error, Equatable {
    /// The Keychain's own number for why; -1 for a file that could not be made.
    public var status: Int32
}

/// The token as one item of the Mac's Keychain: readable only while the Mac is unlocked,
/// kept on this Mac alone, and never synchronised to iCloud.
public struct KeychainReadwiseTokenStore: ReadwiseTokenStore {
    public init() {}

    /// What the item is found by.
    static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.voxcarrel.VoxCarrel.readwise",
            kSecAttrAccount as String: "token",
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func load() -> String? {
        var query = Self.item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)?.trimmedOrNil
    }

    public func save(_ token: String) throws {
        remove()
        var adding = Self.item
        adding[kSecValueData as String] = Data(token.utf8)
        adding[kSecAttrLabel as String] = "VoxCarrel Readwise token"
        adding[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(adding as CFDictionary, nil)
        if status == errSecParam {
            // A keychain that does not take that attribute keeps its items on this Mac anyway.
            adding[kSecAttrAccessible as String] = nil
            status = SecItemAdd(adding as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ReadwiseTokenStoreError(status: status) }
    }

    public func remove() {
        SecItemDelete(Self.item as CFDictionary)
    }
}

/// The token as one file that only the owner's account on this Mac can read: for a
/// build of the app that no developer's certificate has signed (see `FileAudibleKeyStore`).
public struct FileReadwiseTokenStore: ReadwiseTokenStore {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/VoxCarrel/readwise-token` in the owner's Library.
    public static var standardURL: URL {
        FileAudibleKeyStore.standardURL.deletingLastPathComponent().appendingPathComponent("readwise-token")
    }

    public func load() -> String? {
        ReadwiseTokenFile.token(at: url)
    }

    public func save(_ token: String) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Made private before anything is in it, then filled.
        remove()
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw ReadwiseTokenStoreError(status: -1) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(token.utf8))
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum ReadwiseTokenStores {
    /// Where this build of the app keeps the token: the Keychain when a developer's
    /// certificate signed it, a private file when none did.
    public static func standard() -> any ReadwiseTokenStore {
        AudibleKeyStores.isSignedByADeveloper
            ? KeychainReadwiseTokenStore() : FileReadwiseTokenStore(url: FileReadwiseTokenStore.standardURL)
    }
}

/// A token that is only remembered while the process runs: for tests.
public final class InMemoryReadwiseTokenStore: ReadwiseTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init() {}

    public func load() -> String? {
        lock.withLock { token }
    }

    public func save(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    public func remove() {
        lock.withLock { token = nil }
    }
}

/// A token kept in a file: the app's own private one, or one put on this Mac earlier.
enum ReadwiseTokenFile {
    /// Where a token put on this Mac earlier is, in the owner's home folder.
    static var standard: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voxcarrel/readwise-token", isDirectory: false)
    }

    /// The token the file holds; nil when there is no such file, or it holds nothing
    /// that could be one. The file is only read.
    static func token(at url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size < 10_000,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)?.trimmed,
              isPlausible(text)
        else { return nil }
        return text
    }

    /// Whether the text could be a token: something, all of it plain letters, digits
    /// and marks, with no space in it.
    static func isPlausible(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 500 && text.allSatisfy { $0.isASCII && !$0.isWhitespace && !$0.isNewline }
    }
}

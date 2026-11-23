import CryptoKit
import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// A `SleepGuarding` that keeps nothing awake and counts what it was asked.
@MainActor
final class FakeSleepGuard: SleepGuarding {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var reasons: [String] = []
    /// Whether the Mac would be kept awake now.
    private(set) var isActive = false

    func begin(reason: String) {
        begins += 1
        reasons.append(reason)
        isActive = true
    }

    func end() {
        ends += 1
        isActive = false
    }
}

/// A `LocalNetworkReading` that reads nothing: a test says which network the Mac is on.
@MainActor
final class FakeNetwork: LocalNetworkReading {
    var localAddresses = ["192.168.1.20"]
    var network: NetworkIdentity? = NetworkIdentity(router: "192.168.1.1", name: "Home")

    func addresses() -> [String] { localAddresses }
    func identity() -> NetworkIdentity? { network }
}

/// What a folder holds, to tell whether anything in it was changed: each file's path,
/// the hash of its bytes and when it was last modified. The catalogue's own files are
/// left out.
func libraryState(_ root: URL) throws -> [String: String] {
    var state: [String: String] = [:]
    for path in layoutTree(root) {
        let url = root.appendingPathComponent(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            state[path] = "folder"
            continue
        }
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        state[path] = "\(hash) \(modified?.timeIntervalSinceReferenceDate ?? 0)"
    }
    return state
}

extension Harness {
    /// The temporary folders of sends that are in the model's own temporary folder now.
    var sendFolders: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: sendTemp, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("VoxCarrelSend-") }
    }

    /// Selects the book and opens Send to Phone on it.
    @discardableResult
    func beginSend(_ title: String) async throws -> Int64 {
        let id = try await select(title)
        await model.beginSendToPhone()
        return id
    }

    /// Every recorded sending of the book, newest first.
    func sent(_ id: Int64) throws -> [SentRecord] {
        try LibraryService(store: try store()).sentRecords(for: id)
    }
}

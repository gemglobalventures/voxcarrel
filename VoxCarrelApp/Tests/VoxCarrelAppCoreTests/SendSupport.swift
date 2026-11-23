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
    var network: NetworkIdentity? = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Home")

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
    /// The one folder, in the model's own temporary folder, that every send's package goes under.
    var sendParent: URL {
        sendTemp.appendingPathComponent("VoxCarrelSend", isDirectory: true)
    }

    /// The temporary folders of sends that are there now: one for each attempt.
    var sendFolders: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: sendParent, includingPropertiesForKeys: nil)) ?? []
    }

    /// Whether `folder` is the folder of one attempt of this process: named by its id
    /// and a UUID, directly in `sendParent`.
    func isSendFolder(_ folder: URL) -> Bool {
        let prefix = "\(ProcessInfo.processInfo.processIdentifier)-"
        let name = folder.lastPathComponent
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            && folder.deletingLastPathComponent().resolvingSymlinksInPath() == sendParent.resolvingSymlinksInPath()
    }

    /// The name of a send folder as a copy of the app whose process has ended made it.
    func endedSendFolderName() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return "\(process.processIdentifier)-\(UUID().uuidString)"
    }

    /// Waits for the clean-up that `start()` leaves running behind it.
    func sendCleanupDone() async {
        await model.sendCleanup?.value
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

extension AppModel {
    /// The system's sharing reports on what it was last handed, as it does when nothing
    /// else has been shared since.
    func shareFinished(completed: Bool) async {
        await shareFinished(completed: completed, items: sendSession?.sharing.map { [$0.file] } ?? [])
    }
}

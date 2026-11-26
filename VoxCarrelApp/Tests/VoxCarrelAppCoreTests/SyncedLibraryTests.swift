import Foundation
import Testing
@testable import VoxCarrelAppCore

/// SL1–SL3: a library folder that a cloud service keeps in step is noticed, warned of
/// once when it is chosen, and marked in Settings.
@MainActor @Suite struct SyncedLibraryTests {
    private func place(_ path: String, inICloud: Bool = false) -> SyncedPlace? {
        SyncedPlace.of(URL(fileURLWithPath: path, isDirectory: true), isInICloud: { _ in inICloud })
    }

    // SL1: where a folder lies says which service keeps it.
    @Test func SL1_theServiceIsToldFromWhereTheFolderLies() {
        #expect(place("/Users/ann/Library/Mobile Documents/com~apple~CloudDocs/Books")?.name == "iCloud Drive")
        #expect(place("/Users/ann/Library/CloudStorage/Dropbox/Books")?.name == "Dropbox")
        #expect(place("/Users/ann/Library/CloudStorage/OneDrive-Personal/Books")?.name == "OneDrive")
        #expect(place("/Users/ann/Library/CloudStorage/GoogleDrive-ann@example.com/My Drive/Books")?.name == "Google Drive")
        #expect(place("/Users/ann/Library/CloudStorage/Something-New/Books")?.name == "a cloud service")
        // Documents kept in iCloud: only the system can say.
        #expect(place("/Users/ann/Documents/Books", inICloud: true)?.name == "iCloud Drive")
        #expect(place("/Users/ann/Documents/Books") == nil)
        #expect(place("/Users/ann/Books") == nil && place("/Volumes/Shelf/Books") == nil)
        // A folder that only has such a name in it is not one.
        #expect(place("/Users/ann/Mobile Documents/Books") == nil && place("/Users/ann/Library/Books") == nil)
    }

    // SL2: choosing such a folder opens it and says the risks once; Settings goes on
    // saying it. A folder that is not synced says nothing.
    @Test func SL2_choosingASyncedFolderWarnsAndSettingsSaysSo() async throws {
        let h = try await Harness.demo()
        #expect(h.model.librarySyncNote == nil)
        let synced = h.root.deletingLastPathComponent().appendingPathComponent("synced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: synced) }
        h.model.syncedPlaceOf = { $0.path == synced.path ? SyncedPlace(name: "iCloud Drive") : nil }

        await h.model.chooseLibrary(synced)
        #expect(h.model.status == .available(synced))
        #expect(h.model.alert == SyncedPlace(name: "iCloud Drive").warning)
        #expect(h.model.alert?.contains("iCloud Drive") == true && h.model.alert?.contains("two Macs") == true)
        #expect(h.model.librarySyncNote == SyncedPlace(name: "iCloud Drive").note)

        // Back to the one that is not synced: nothing is said.
        h.model.alert = nil
        await h.model.chooseLibrary(h.root)
        #expect(h.model.alert == nil && h.model.librarySyncNote == nil)
    }

    // SL3: the demo library is never marked, wherever the temporary folder lies.
    @Test func SL3_theDemoLibraryIsNotMarked() async throws {
        let h = try await Harness.demo()
        h.model.syncedPlaceOf = { _ in SyncedPlace(name: "iCloud Drive") }
        #expect(h.model.librarySyncNote != nil)
        h.model.demoRoot = h.root.deletingLastPathComponent().appendingPathComponent("demos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: h.model.demoRoot) }
        h.model.demoMaker = { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        await h.model.openDemoLibrary()
        #expect(h.model.isShowingDemoLibrary && h.model.librarySyncNote == nil)
        #expect(h.model.alert == DemoLibraryText.whatItIs)
    }
}

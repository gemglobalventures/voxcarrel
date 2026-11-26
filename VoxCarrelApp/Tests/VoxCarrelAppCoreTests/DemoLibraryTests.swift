import DemoContent
import Foundation
import Testing
@testable import VoxCarrelAppCore

/// DL1–DL4: Open Demo Library, in one step, without touching the library that is remembered.
@MainActor @Suite struct DemoLibraryTests {
    // DL1: the demo is made in a new folder under the temporary place and shown; the
    // remembered library is as it was, and is what opens at the next launch.
    @Test func DL1_theDemoIsShownAndTheRememberedLibraryIsLeftAlone() async throws {
        let h = try await Harness.demo()
        let own = h.root
        let ownBooks = h.model.rows.count
        let demos = h.root.deletingLastPathComponent().appendingPathComponent("demos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: demos) }
        h.model.demoRoot = demos
        // A small demo of its own, to tell it from the library the harness opened.
        h.model.demoMaker = { try DemoContent.makeLibrary(at: $0, audible: false) }
        #expect(h.model.canOpenDemoLibrary && !h.model.isShowingDemoLibrary)

        await h.model.openDemoLibrary()

        #expect(h.model.isShowingDemoLibrary && !h.model.canOpenDemoLibrary)
        guard case .available(let shown) = h.model.status else {
            Issue.record("no library is shown")
            return
        }
        #expect(shown.path.hasPrefix(demos.path) && shown.lastPathComponent == "Demo Library")
        #expect(h.model.rowsLoaded && !h.model.rows.isEmpty && h.model.busyLabel == nil)
        #expect(h.model.alert == DemoLibraryText.whatItIs)
        #expect(h.model.statusBar?.library.hasPrefix("Demo library · ") == true)
        // What is remembered is the owner's own library, untouched.
        #expect(h.defaults.string(forKey: LibraryLocation.defaultsKey) == own.path)
        let again = h.relaunched()
        await again.start()
        #expect(again.status == .available(own) && !again.isShowingDemoLibrary && again.rows.count == ownBooks)
    }

    // DL2: choosing a library ends the demo.
    @Test func DL2_choosingALibraryEndsTheDemo() async throws {
        let h = try await Harness.demo()
        let demos = h.root.deletingLastPathComponent().appendingPathComponent("demos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: demos) }
        h.model.demoRoot = demos
        h.model.demoMaker = { try DemoContent.makeLibrary(at: $0, audible: false) }
        await h.model.openDemoLibrary()
        h.model.alert = nil
        await h.model.chooseLibrary(h.root)
        #expect(!h.model.isShowingDemoLibrary && h.model.status == .available(h.root))
        #expect(h.model.statusBar?.library.hasPrefix("Library: ") == true)
    }

    // DL3: a demo that cannot be made is said, and the library shown stays shown.
    @Test func DL3_aFailureIsSaidAndNothingChanges() async throws {
        let h = try await Harness.demo()
        let rows = h.model.rows.count
        struct NoRoom: Error, CustomStringConvertible { var description: String { "The disk is full." } }
        h.model.demoRoot = h.root.deletingLastPathComponent().appendingPathComponent("demos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: h.model.demoRoot) }
        h.model.demoMaker = { _ in throw NoRoom() }
        await h.model.openDemoLibrary()
        #expect(h.model.alert == "The demo library could not be made. The disk is full.")
        #expect(!h.model.isShowingDemoLibrary && h.model.status == .available(h.root) && h.model.rows.count == rows)
        #expect(h.model.busyLabel == nil)
    }

    // DL4: with edits not yet saved, it asks for those to be dealt with first.
    @Test func DL4_itWaitsForWhatIsOpen() async throws {
        let h = try await Harness.demo()
        let title = try #require(h.model.rows.first { $0.hasFiles }?.book.title)
        _ = try await h.select(title)
        h.model.updateDraft { $0.title = "Changed" }
        #expect(h.model.hasUnsavedChanges)
        h.model.demoMaker = { _ in Issue.record("the demo was made") }
        await h.model.openDemoLibrary()
        #expect(h.model.alert == DemoLibraryText.finishFirst && !h.model.isShowingDemoLibrary)
    }
}

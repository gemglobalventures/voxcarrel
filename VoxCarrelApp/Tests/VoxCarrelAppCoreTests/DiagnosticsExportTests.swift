import Foundation
import Testing
import VoxCarrelCore
import ZIPFoundation
@testable import VoxCarrelAppCore

/// XD1–XD5: Export Diagnostics, a zip the owner saves and sends themselves.
@MainActor @Suite struct DiagnosticsExportTests {
    /// Says what it is given, and asks the system nothing.
    struct FakeSource: DiagnosticsSource {
        var settingsNow: [String: Any] = [:]
        var log: [DiagnosticLogLine] = []
        func about() -> [String] { ["VoxCarrel 9.9 (99)", "macOS Version 99"] }
        func settings() -> [String: Any] { settingsNow }
        func recentLog() -> [DiagnosticLogLine] { log }
    }

    private func texts(in url: URL) throws -> [String: String] {
        let archive = try Archive(url: url, accessMode: .read)
        var read: [String: String] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            read[entry.path] = String(decoding: data, as: UTF8.self)
        }
        return read
    }

    private let line = DiagnosticLogLine(
        date: Date(timeIntervalSince1970: 1_700_000_000), level: "error", category: "VoxCarrelCore/layout",
        message: "could not read Salt Road")

    // XD1: the zip holds the six files, and without leave names no book, file or folder.
    @Test func XD1_theZipNamesNothingUnlessAsked() async throws {
        let h = try await Harness.demo()
        var source = FakeSource()
        source.settingsNow = ["kindleAddress": "someone@example.com", "showsInbox": true, "NSWindow Frame Salt Road": "1 2 3 4"]
        source.log = [line]
        h.model.diagnosticsSource = source
        let url = h.root.deletingLastPathComponent().appendingPathComponent("diagnostics-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await h.model.exportDiagnostics(to: url, includingTitles: false))
        let read = try texts(in: url)
        #expect(Set(read.keys) == ["README.txt", "about.txt", "settings.txt", "library.txt", "launch-check.txt", "log.txt"])
        #expect(read["about.txt"] == "VoxCarrel 9.9 (99)\nmacOS Version 99\n")
        #expect(read["settings.txt"] == "kindleAddress: text (19 characters)\nshowsInbox: on\n(1 more, whose names are not shown)\n")
        #expect(read["library.txt"]?.hasPrefix("Books: ") == true)
        #expect(read["launch-check.txt"] == DiagnosticsText.nothingFound)
        #expect(read["log.txt"] == "2023-11-14T22:13:20Z error VoxCarrelCore/layout\n")
        #expect(read["README.txt"]?.hasSuffix(DiagnosticsText.withoutTitles) == true)

        // Nothing in any of it names a book of the library, its folder or this Mac's owner.
        let all = read.values.joined(separator: "\n")
        let worker = try #require(h.model.worker)
        let names: [String] = try await worker.withService { service in
            try service.store.books().flatMap { [$0.title] + $0.authors }
        }
        #expect(!names.isEmpty)
        for name in names + [h.root.path, NSHomeDirectory(), NSUserName(), "someone@example.com", "Salt Road"] {
            #expect(!all.contains(name), "the report says \(name)")
        }
    }

    // XD2: with leave, the log says what it said and the README says titles are in it.
    @Test func XD2_withLeaveTheLogIsWhole() async throws {
        let h = try await Harness.demo()
        var source = FakeSource()
        source.log = [line]
        h.model.diagnosticsSource = source
        let url = h.root.deletingLastPathComponent().appendingPathComponent("diagnostics-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await h.model.exportDiagnostics(to: url, includingTitles: true))
        let read = try texts(in: url)
        #expect(read["log.txt"] == "2023-11-14T22:13:20Z error VoxCarrelCore/layout: could not read Salt Road\n")
        #expect(read["README.txt"]?.hasSuffix(DiagnosticsText.withTitles) == true)
        #expect(read["settings.txt"] == "No settings are set.\n")
    }

    // XD3: a place that cannot be written to is said, and nothing is claimed.
    @Test func XD3_aFailureIsSaid() async throws {
        let h = try await Harness.demo()
        h.model.diagnosticsSource = FakeSource()
        let nowhere = h.root.appendingPathComponent("no such folder/\(UUID().uuidString)/report.zip")
        #expect(await !h.model.exportDiagnostics(to: nowhere, includingTitles: false))
        #expect(h.model.alert != nil)
    }

    // XD6: Report a Problem opens the project's issues in the browser, and nothing else.
    @Test func XD6_reportAProblemOpensTheIssuesPage() async throws {
        let h = try await Harness.demo(start: false)
        h.model.reportAProblem()
        #expect(h.opener.openedWeb == [URL(string: "https://github.com/gemglobalventures/voxcarrel/issues")!])
        #expect(ProblemReport.commandTitle == "Report a Problem…")
    }

    // XD4: how each kind of setting is shown.
    @Test func XD4_settingsAreShownByKind() {
        #expect(DiagnosticsText.shown(true) == "on" && DiagnosticsText.shown(false) == "off")
        #expect(DiagnosticsText.shown(3) == "3" && DiagnosticsText.shown(2.5) == "2.5")
        #expect(DiagnosticsText.shown("/Users/someone/Books") == "text (20 characters)")
        #expect(DiagnosticsText.shown(Data([1, 2, 3])) == "data (3 bytes)")
        #expect(DiagnosticsText.shown(["a", "b"]) == "list (2 items)")
        #expect(DiagnosticsText.shown(["a": 1]) == "table (1 entries)")
        #expect(DiagnosticsText.shown(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }

    // XD5: the name the zip is offered under.
    @Test func XD5_theFileIsNamedForTheDay() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DiagnosticsText.fileName(on: Date(timeIntervalSince1970: 1_795_651_200), timeZone: utc)
            == "VoxCarrel Diagnostics 2026-11-26.zip")
        #expect(DiagnosticsText.check(nil, includingTitles: false) == DiagnosticsText.nothingFound)
        var report = ReconcileReport(booksWithMissingFiles: [1, 2], untrackedFiles: [URL(fileURLWithPath: "/x/Salt Road.m4b")])
        report.layoutChangeProblem = "Salt Road is in the way"
        let plain = DiagnosticsText.check(report, includingTitles: false)
        #expect(plain.contains("Books with files missing: 2") && plain.contains("Book files no book uses: 1 (m4b 1)"))
        #expect(plain.contains("could not be put right: yes") && !plain.contains("Salt Road"))
        #expect(DiagnosticsText.check(report, includingTitles: true).contains("  Layout: Salt Road is in the way"))
    }
}

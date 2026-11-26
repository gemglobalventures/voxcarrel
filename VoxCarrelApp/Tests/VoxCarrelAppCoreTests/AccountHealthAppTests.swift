import Foundation
import Testing
import VoxCarrelCore
@testable import VoxCarrelAppCore

/// HA1–HA6: what the app says when Audible or Amazon does not answer as it should, the
/// day each library was last read, and Check Connection.
@MainActor @Suite struct AccountHealthAppTests {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    /// Everything about the library that a failed reading must leave alone.
    private func state(_ h: Harness) throws -> [Book] {
        try h.store().books().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    // HA1: each way a reading of the Audible library can fail is said in words that
    // say what to do, and the library is exactly as it was.
    @Test func HA1_everyAudibleFailureIsSaidAndChangesNothing() async throws {
        let h = try await Harness.demo()
        try h.link()
        let before = try state(h)
        let cases: [(status: Int, body: Any, says: String)] = [
            (503, [:] as [String: Any], "Audible is not answering properly at the moment. Nothing was changed. Try again in a while."),
            (429, [:] as [String: Any], "Audible is not answering properly at the moment. Nothing was changed. Try again in a while."),
            (401, [:] as [String: Any], "Audible no longer accepts this link. Unlink the account in Settings and link it again."),
            (200, ["books": []], "Audible answered in a way VoxCarrel does not understand. Nothing was changed. "
                + "If this goes on, look for a newer version of VoxCarrel."),
        ]
        for one in cases {
            h.audible.answer("/1.0/library", with: one.body, status: one.status)
            let session = try await h.audibleImportRead()
            #expect(session.problem == one.says && session.phase == .failed && !session.canImport)
            session.cancel()
            #expect(try state(h) == before)
        }
        h.audible.fails = true
        let offline = try await h.audibleImportRead()
        #expect(offline.problem == "Audible could not be reached. Check your internet connection.")
        offline.cancel()
        #expect(try state(h) == before)
        // No reading was good, so none is remembered.
        #expect(h.model.lastGoodReading(of: .audible) == nil)
    }

    // HA2: the same for Kindle.
    @Test func HA2_everyKindleFailureIsSaidAndChangesNothing() async throws {
        let h = try await Harness.demo()
        try h.link()
        let before = try state(h)
        h.audible.holdsOnKindle([])
        for status in [500, 429] {
            h.audible.answer("/kindle-library/search", with: [:] as [String: Any], status: status)
            let session = try await h.kindleImportRead()
            #expect(session.problem == "Amazon is not answering properly at the moment. Nothing was changed. Try again in a while.")
            #expect(session.phase == .failed)
            session.cancel()
        }
        h.audible.answer("/kindle-library/search", with: ["items": []])
        let odd = try await h.kindleImportRead()
        #expect(odd.problem == "Amazon answered in a way VoxCarrel does not understand. Nothing was changed. "
            + "If this goes on, look for a newer version of VoxCarrel.")
        odd.cancel()
        #expect(try state(h) == before && h.model.lastGoodReading(of: .kindle) == nil)
    }

    // HA3: a good reading is remembered by its day, for each library, across launches;
    // unlinking forgets both.
    @Test func HA3_theDayOfTheLastGoodReadingIsKept() async throws {
        let h = try await Harness.demo()
        #expect(h.model.lastReadLines().isEmpty)
        try h.link()
        #expect(h.model.lastReadLines(locale: gb, timeZone: utc) == ["Audible library not read yet.", "Kindle library not read yet."])

        h.model.accountNow = { Date(timeIntervalSince1970: 1_795_651_200) }
        h.audible.holds([])
        let audible = try await h.audibleImportRead()
        #expect(audible.phase == .review)
        audible.cancel()
        #expect(h.model.lastReadLines(locale: gb, timeZone: utc) == ["Audible library last read 26 Nov 2026.", "Kindle library not read yet."])

        h.model.accountNow = { Date(timeIntervalSince1970: 1_795_651_200 + 86_400) }
        h.audible.holdsOnKindle([])
        let kindle = try await h.kindleImportRead()
        kindle.cancel()
        #expect(h.model.lastReadLines(locale: gb, timeZone: utc)[1] == "Kindle library last read 27 Nov 2026.")

        // A reading that fails afterwards does not move the day.
        h.audible.answer("/1.0/library", with: [:] as [String: Any], status: 503)
        let failed = try await h.audibleImportRead()
        failed.cancel()
        #expect(h.model.lastReadLines(locale: gb, timeZone: utc)[0] == "Audible library last read 26 Nov 2026.")

        // The next launch knows it too.
        let again = h.relaunched()
        await again.start()
        #expect(again.lastReadLines(locale: gb, timeZone: utc)[0] == "Audible library last read 26 Nov 2026.")

        h.audible.answer("/auth/deregister", with: ["response": ["success": [:] as [String: Any]]])
        h.model.unlinkAudible()
        await h.model.confirmUnlinkAudible()
        #expect(!h.model.isAudibleLinked && h.model.lastGoodReading(of: .audible) == nil && h.model.lastGoodReading(of: .kindle) == nil)
    }

    // HA4: Check Connection says, for each library, that it is connected or why not,
    // asks one small thing of each, and changes nothing.
    @Test func HA4_checkConnectionSaysHowEachLibraryStands() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canCheckConnection)
        try h.link()
        let before = try state(h)
        #expect(h.model.canCheckConnection && h.model.accountHealth == nil)
        #expect(h.model.checkConnectionTitle == "Check Connection")

        h.audible.holds([])
        h.audible.holdsOnKindle([])
        await h.model.checkConnection()
        #expect(h.model.accountHealth == [
            AccountHealthLine(service: .audible, isWorking: true, text: "Audible: connected."),
            AccountHealthLine(service: .kindle, isWorking: true, text: "Kindle: connected."),
        ])
        #expect(!h.model.isCheckingConnection && h.model.canCheckConnection)
        // One request to Audible, two to Amazon for Kindle; each of one book at most.
        let asked = h.audible.asked.map { ($0.url?.path ?? "") + "?" + ($0.url?.query ?? "") }
        #expect(asked.count == 3)
        #expect(asked.contains("/1.0/library?num_results=1&page=1"))
        #expect(asked.contains { $0.hasPrefix("/kindle-library/search?") && $0.hasSuffix("querySize=1") })
        // A check is not a reading, and the library is as it was.
        #expect(h.model.lastGoodReading(of: .audible) == nil && h.model.lastGoodReading(of: .kindle) == nil)
        #expect(try state(h) == before)

        // One works and the other does not.
        h.audible.answer("/ap/exchangetoken/cookies", with: [:] as [String: Any], status: 401)
        await h.model.checkConnection()
        #expect(h.model.accountHealth?[0].isWorking == true)
        #expect(h.model.accountHealth?[1] == AccountHealthLine(
            service: .kindle, isWorking: false,
            text: "Kindle: Amazon no longer accepts this link. Unlink the Audible account in Settings and link it again."))

        // No network.
        h.audible.fails = true
        await h.model.checkConnection()
        #expect(h.model.accountHealth?.map(\.isWorking) == [false, false])
        #expect(h.model.accountHealth?[0].text == "Audible: Audible could not be reached. Check your internet connection.")
    }

    // HA5: while a check runs the button says so and cannot start another; unlinking
    // meanwhile drops what comes back.
    @Test func HA5_aCheckRunsOnceAndUnlinkingDropsIt() async throws {
        let h = try await Harness.demo()
        try h.link()
        h.audible.holds([])
        h.audible.holdsOnKindle([])
        let gate = Gate()
        h.audible.gate = gate
        let running = Task { await h.model.checkConnection() }
        for _ in 0..<200 where !h.model.isCheckingConnection { await Task.yield() }
        #expect(h.model.isCheckingConnection && !h.model.canCheckConnection)
        #expect(h.model.checkConnectionTitle == "Checking…")
        h.model.forgetAccountHealth()
        await gate.release()
        await running.value
        #expect(h.model.accountHealth == nil && !h.model.isCheckingConnection)
    }

    // HA6: the sentences.
    @Test func HA6_whatIsSaid() {
        #expect(AccountHealthText.lastRead(.kindle, nil) == "Kindle library not read yet.")
        #expect(AccountHealthText.problem(.audible, AudibleAccountError.busy(503))
            == "Audible: Audible is not answering properly at the moment. Nothing was changed. Try again in a while.")
        #expect(UserMessage.kindleLibraryProblem(AudibleAccountError.unusableKey) == "Your Kindle library could not be read.")
    }
}

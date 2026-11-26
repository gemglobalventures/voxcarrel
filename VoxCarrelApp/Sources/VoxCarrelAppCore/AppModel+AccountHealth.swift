import Foundation
import VoxCarrelCore

// Whether the link to Audible and Kindle still works, and when each library was last
// read. Asking changes nothing here or at Amazon.

/// One of the two libraries read through the linked account.
public enum AccountService: String, CaseIterable, Sendable {
    case audible, kindle

    public var title: String {
        switch self {
        case .audible: "Audible"
        case .kindle: "Kindle"
        }
    }

    /// The setting the day of the last good reading is kept under.
    var lastReadKey: String { "accountLastRead.\(rawValue)" }
}

/// What Check Connection found for one library.
public struct AccountHealthLine: Equatable, Identifiable, Sendable {
    public var service: AccountService
    public var isWorking: Bool
    /// "Audible: connected." or why not, with what to do.
    public var text: String

    public var id: String { service.rawValue }
}

/// Every sentence said about the link's health.
public enum AccountHealthText {
    public static let checkTitle = "Check Connection"
    public static let checking = "Checking…"

    static func busy(_ who: String) -> String {
        "\(who) is not answering properly at the moment. Nothing was changed. Try again in a while."
    }

    static func notUnderstood(_ who: String) -> String {
        "\(who) answered in a way VoxCarrel does not understand. Nothing was changed. "
            + "If this goes on, look for a newer version of VoxCarrel."
    }

    static func connected(_ service: AccountService) -> String {
        "\(service.title): connected."
    }

    /// Why a library cannot be read now, after its name.
    static func problem(_ service: AccountService, _ error: Error) -> String {
        let why = service == .audible ? UserMessage.audibleLibraryProblem(error) : UserMessage.kindleLibraryProblem(error)
        return "\(service.title): \(why)"
    }

    /// "Audible library last read 26 Nov 2026."; nil when no day is known. Nothing is
    /// said then: a library brought in before the day was kept has been read, and
    /// "not read yet" would be untrue of it.
    static func lastRead(
        _ service: AccountService, _ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        guard let date else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        return "\(service.title) library last read \(date.formatted(style))."
    }
}

extension AppModel {
    /// When each library was last read in full from Amazon on this Mac; nil for one
    /// that has not been. Kept with the app's settings, and forgotten on unlinking.
    public func lastGoodReading(of service: AccountService) -> Date? {
        _ = accountReadingsChanged
        return defaults.object(forKey: service.lastReadKey) as? Date
    }

    /// Notes that a library was read in full just now.
    func noteGoodReading(of service: AccountService) {
        defaults.set(accountNow(), forKey: service.lastReadKey)
        accountReadingsChanged += 1
    }

    /// Forgets everything known of the link's health: the account is no longer linked.
    func forgetAccountHealth() {
        for service in AccountService.allCases { defaults.removeObject(forKey: service.lastReadKey) }
        accountReadingsChanged += 1
        accountHealth = nil
        accountCheck?.cancel()
        isCheckingConnection = false
    }

    /// "Audible library last read 26 Nov 2026." for each library whose day is known;
    /// empty when no account is linked, or neither has been read since the day was kept.
    public func lastReadLines(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        guard isAudibleLinked else { return [] }
        return AccountService.allCases.compactMap {
            AccountHealthText.lastRead($0, lastGoodReading(of: $0), locale: locale, timeZone: timeZone)
        }
    }

    /// Whether the link can be checked now: an account is linked and no check is running.
    public var canCheckConnection: Bool {
        isAudibleLinked && !isCheckingConnection
    }

    public var checkConnectionTitle: String {
        isCheckingConnection ? AccountHealthText.checking : AccountHealthText.checkTitle
    }

    /// Asks Audible and Amazon one small thing each, to see whether the link still
    /// works, and says what came back for each in `accountHealth`. Nothing is read
    /// into the library, and nothing is changed here or there. It needs no library.
    public func checkConnection() async {
        guard canCheckConnection, let account = audibleAccount else { return }
        let transport = audibleTransport
        isCheckingConnection = true
        accountHealth = nil
        let check = Task { () -> [AccountHealthLine] in
            async let audible: Error? = {
                do { try await AudibleLibraryReader.check(account, transport: transport); return nil } catch { return error }
            }()
            async let kindle: Error? = {
                do { try await KindleLibraryReader.check(account, transport: transport); return nil } catch { return error }
            }()
            let found = await [(AccountService.audible, audible), (.kindle, kindle)]
            return found.map { service, error in
                AccountHealthLine(
                    service: service, isWorking: error == nil,
                    text: error.map { AccountHealthText.problem(service, $0) } ?? AccountHealthText.connected(service))
            }
        }
        accountCheck = Task { _ = await check.value }
        let lines = await check.value
        // Unlinked meanwhile, or another account linked: what came back is not about it.
        guard isCheckingConnection, audibleAccount == account else { return }
        accountHealth = lines
        isCheckingConnection = false
    }
}

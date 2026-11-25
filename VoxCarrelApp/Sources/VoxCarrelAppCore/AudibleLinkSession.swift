import Foundation
import Observation
import VoxCarrelCore

/// The state of Link Audible Account. It decides everything the sheet shows.
///
/// The owner signs in on Amazon's own page, in their browser. Amazon then sends the
/// browser to a page whose address holds a one-time code; the owner copies that
/// address, and it is read from the clipboard and exchanged for the keys of a device
/// registered with the account. The password never comes near the app.
@MainActor @Observable
public final class AudibleLinkSession {
    public enum Phase: Equatable, Sendable {
        /// Nothing has been opened yet.
        case start
        /// The browser was sent to Amazon's sign-in page; the address is waited for.
        case waitingForAddress
        /// Amazon is being asked to register the device.
        case registering
        /// Linked: what Amazon calls the device.
        case done(String)
    }

    @ObservationIgnored private unowned let model: AppModel
    /// The link made earlier on this Mac, when there is one to offer.
    @ObservationIgnored private let existing: AudibleAccount?
    /// The attempt the browser was sent to sign in for.
    @ObservationIgnored private var attempt: AudibleLink.Attempt?

    init(model: AppModel) {
        self.model = model
        storedStore = model.audibleStore
        existing = AudibleLinkFile.account(at: model.audibleLinkFile)
    }

    public let title = "Link Audible Account"
    public let storeTitle = "Your Audible store"
    public let openSignInTitle = "Open Amazon Sign-In"
    public let openAgainTitle = "Open Amazon Sign-In Again"
    public let copiedTitle = "I've Copied the Address"
    public let existingLinkTitle = "Use the link already on this Mac"
    public let registeringText = "Linking…"

    /// What linking does, as sentences for the sheet.
    public let explanation = [
        "You sign in on Amazon's own page, in your browser. VoxCarrel never sees your password.",
        "A device named like \"Your name's Audible for iPhone\" is added to your Amazon account. You can remove "
            + "it there, under Content & Devices, or here with Unlink.",
        "The device's keys are kept in this Mac's Keychain. They let VoxCarrel read your Audible library, as the "
            + "Audible app on a phone can.",
        "Nothing is bought, changed or removed at Audible.",
        "This is not an official Amazon interface, and it may stop working if Amazon changes it.",
    ]

    /// What to do once the browser is at Amazon's page, in order.
    public var steps: [String] {
        [
            "Sign in to Amazon in the browser window that opened.",
            "A page that looks broken appears (\"Looking for something?\"). That is expected.",
            "Click the browser's address bar, select all of the address, and copy it.",
            "Come back here and press \(copiedTitle).",
        ]
    }

    public private(set) var phase = Phase.start
    /// Why the last thing tried did not work, as a sentence; nil when it did.
    public private(set) var problem: String?

    // MARK: The store

    private var storedStore: AudibleStore

    /// The store the account is with. It can be changed only before the browser is
    /// sent to sign in: after that it is the attempt's.
    public var store: AudibleStore {
        get { storedStore }
        set {
            guard phase == .start else { return }
            storedStore = newValue
        }
    }

    /// The stores to choose from, by country name.
    public var storeChoices: [AudibleStoreChoice] {
        AppModel.audibleStoreChoices
    }

    public var canChooseStore: Bool {
        phase == .start
    }

    // MARK: Signing in

    public var canOpenSignIn: Bool {
        phase == .start || phase == .waitingForAddress
    }

    /// Sends the browser to Amazon's sign-in page for the store chosen. Done again, it
    /// begins a new attempt: the address of an earlier one is of no use to it.
    public func openSignIn() {
        guard canOpenSignIn, let attempt = AudibleLink.begin(store: storedStore) else { return }
        self.attempt = attempt
        problem = nil
        model.opener.openWeb(attempt.signInURL)
        phase = .waitingForAddress
    }

    public var canReadCopiedAddress: Bool {
        phase == .waitingForAddress
    }

    /// Reads the address the owner copied from the clipboard, has Amazon register the
    /// device with the code in it, and keeps the keys. What is on the clipboard is
    /// used for nothing else, and kept nowhere.
    public func readCopiedAddress() async {
        guard canReadCopiedAddress, let attempt else { return }
        guard let code = AudibleLink.signInCode(in: model.audibleClipboard() ?? "", for: attempt) else {
            problem = UserMessage.audibleNotTheAddress
            return
        }
        problem = nil
        phase = .registering
        let transport = model.audibleTransport
        do {
            let account = try await AudibleLink.register(code: code, attempt: attempt, transport: transport)
            guard model.audibleLink === self else {
                // The sheet has gone: the device is not left registered with nothing to show for it.
                _ = try? await AudibleLink.unregister(account, transport: transport)
                return
            }
            do {
                try model.keepAudibleAccount(account)
            } catch {
                _ = try? await AudibleLink.unregister(account, transport: transport)
                self.attempt = nil
                problem = UserMessage.audibleKeysNotKept
                phase = .start
                return
            }
            phase = .done(Self.name(of: account))
        } catch AudibleAccountError.notReachable {
            // The code was not used: the same address can be tried again.
            problem = UserMessage.audibleLinkProblem(AudibleAccountError.notReachable)
            phase = .waitingForAddress
        } catch {
            // A code is good once: the sign-in has to be done again.
            self.attempt = nil
            problem = UserMessage.audibleLinkProblem(error)
            phase = .start
        }
    }

    // MARK: A link made earlier

    /// Whether there is a link made earlier on this Mac to use instead of signing in.
    public var offersExistingLink: Bool {
        existing != nil && phase == .start
    }

    /// Keeps the link made earlier as this app's own. Its file is left as it is.
    public func useExistingLink() {
        guard offersExistingLink, let existing else { return }
        do {
            try model.keepAudibleAccount(existing)
            problem = nil
            phase = .done(Self.name(of: existing))
        } catch {
            problem = UserMessage.audibleKeysNotKept
        }
    }

    // MARK: Closing

    /// "Linked as Ann's 2nd Audible for iPhone."; nil until the account is linked.
    public var doneText: String? {
        guard case .done(let name) = phase else { return nil }
        return "Linked as \(name)."
    }

    /// What to say under it: where the library is brought in from.
    public let doneNote = "To bring in your books, choose Import Audible Library from the Library menu."

    /// "Done" once linked, "Cancel" until then.
    public var closeTitle: String {
        if case .done = phase { "Done" } else { "Cancel" }
    }

    /// The sheet cannot be closed while Amazon is being asked to register the device.
    public var canCancel: Bool {
        phase != .registering
    }

    /// Closes the sheet. An account that was linked stays linked.
    public func cancel() {
        guard canCancel else { return }
        model.closeAudibleLink()
    }

    private static func name(of account: AudibleAccount) -> String {
        account.deviceName?.trimmedOrNil ?? "an Audible device"
    }
}

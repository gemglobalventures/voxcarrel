import AppKit
import Foundation

/// Hands a book to what sends it to the owner's Kindle: Amazon's own Send to Kindle
/// app, or the owner's mail program. VoxCarrel sends nothing itself and never signs in
/// to Amazon. Tests give one that only records what it was asked.
@MainActor public protocol KindleSender {
    /// Whether Amazon's Send to Kindle app is on this Mac.
    var isAppInstalled: Bool { get }
    /// Opens the file with Amazon's app, which shows its own window with the owner's
    /// devices and a Send button. False when the app would not open it.
    func sendWithApp(_ file: URL) -> Bool
    /// Opens a new message in the owner's mail program, to this address, with the file
    /// attached: the owner presses Send. False when no mail program can do it.
    func composeEmail(to address: String, subject: String, attaching file: URL) -> Bool
}

/// The real thing: the workspace finds and opens Amazon's app, and the system's
/// sharing service writes the message.
public struct SystemKindleSender: KindleSender {
    /// What Amazon's Send to Kindle app is known to the system by.
    public static let appIdentifier = "com.amazon.SendToKindle"

    public nonisolated init() {}

    /// Where Amazon's app is; nil when it is not installed.
    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appIdentifier)
    }

    public var isAppInstalled: Bool {
        appURL != nil
    }

    public func sendWithApp(_ file: URL) -> Bool {
        guard let appURL else { return false }
        // The app takes any file opened with it. Whether it opened is reported later,
        // and by then its own window, or the system's own message, has said so.
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    public func composeEmail(to address: String, subject: String, attaching file: URL) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = [address]
        service.subject = subject
        guard service.canPerform(withItems: [file]) else { return false }
        service.perform(withItems: [file])
        return true
    }
}

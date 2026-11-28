import DemoContent
import Foundation

/// Every sentence Open Demo Library shows.
public enum DemoLibraryText {
    /// The command, in the Help menu.
    public static let commandTitle = "Open Demo Library"
    /// The same on the welcome screen, where there is no library yet.
    public static let welcomeTitle = "Try a Demo Library"
    public static let busy = "Making the demo library…"
    /// Said before the library's totals in the status bar while the demo is shown.
    public static let mark = "Demo library"
    static let finishFirst = "Finish what is open in the VoxCarrel window first, then open the demo library again."
    static let whatItIs =
        "This is a demo library of made-up books, kept in a temporary folder. Try anything: nothing here touches "
        + "your own books. Your own library opens again the next time you start VoxCarrel, or when you choose it "
        + "in Settings."
    /// The same for someone who has not chosen a library yet: there is none to go back to.
    static let whatItIsAtFirst =
        "This is a demo library of made-up books, kept in a temporary folder. Try anything: nothing here touches "
        + "your own books. When you are ready for a library of your own, choose its folder in Settings ▸ General, "
        + "or quit and open VoxCarrel again."

    static func failed(_ reason: String) -> String {
        "The demo library could not be made. \(reason)"
    }
}

extension AppModel {
    /// True while the library shown is the demo.
    public var isShowingDemoLibrary: Bool { location.isShownForNow }

    /// Whether Open Demo Library is offered: not while the demo is already shown.
    public var canOpenDemoLibrary: Bool { !isShowingDemoLibrary && busyLabel == nil }

    /// Makes a library of sample books in a temporary folder and shows it, in one
    /// step. The library that is remembered is not changed: it opens again at the next
    /// launch, or when it is chosen in Settings. Nothing is asked of the network, and
    /// no account is involved.
    public func openDemoLibrary() async {
        guard canOpenDemoLibrary else { return }
        guard storedPrompt == nil, layoutPreview == nil, mergeSession == nil, sendSession == nil, !hasUnsavedChanges
        else {
            alert = DemoLibraryText.finishFirst
            return
        }
        // A new folder each time, so that nothing is ever cleared away to make room.
        let folder = demoRoot
            .appendingPathComponent("VoxCarrel Demo \(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("Demo Library", isDirectory: true)
        let make = demoMaker
        busyLabel = DemoLibraryText.busy
        let failure: String? = await Task.detached {
            do {
                try FileManager.default.createDirectory(
                    at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try make(folder)
                return nil
            } catch {
                return "\(error)"
            }
        }.value
        busyLabel = nil
        if let failure {
            alert = DemoLibraryText.failed(failure)
            return
        }
        await showForNow(folder)
        if openFailure == nil {
            alert = location.hasRemembered ? DemoLibraryText.whatItIs : DemoLibraryText.whatItIsAtFirst
        }
    }
}

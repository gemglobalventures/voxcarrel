import AppKit
import SwiftUI
import VoxCarrelAppCore

/// The system's sharing, for Send to Phone: AirDrop on its own, and the share picker.
///
/// Glue only. What is shared is whatever the model's `shareItems()` gives, and how it
/// went is told to the model's `shareFinished(completed:)`; nothing is decided here.
@MainActor
enum ShareService {
    /// The sharing that is under way. Kept so that its delegate lives until it reports.
    private static var current: Sharing?

    /// Sends the model's items by AirDrop: the system's AirDrop window, with no picker first.
    static func airDrop(for model: AppModel, from anchor: ShareAnchor) {
        Task {
            let items = await model.shareItems()
            guard !items.isEmpty else { return }
            let sharing = Sharing(model: model, window: anchor.view?.window)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items) else {
                await model.shareUnavailable(.airDrop)
                return
            }
            current = sharing
            service.delegate = sharing
            service.perform(withItems: items)
        }
    }

    /// Shows the system's share picker for the model's items, beside the button.
    static func share(for model: AppModel, from anchor: ShareAnchor) {
        Task {
            let items = await model.shareItems()
            guard !items.isEmpty else { return }
            guard let view = anchor.view, view.window != nil else {
                await model.shareFinished(completed: false)
                return
            }
            let sharing = Sharing(model: model, window: view.window)
            current = sharing
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = sharing
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    fileprivate static func ended(_ sharing: Sharing) {
        if current === sharing { current = nil }
    }
}

/// Hears how a share went and tells the model, once.
@MainActor
private final class Sharing: NSObject, NSSharingServiceDelegate, @preconcurrency NSSharingServicePickerDelegate {
    private let model: AppModel
    private weak var window: NSWindow?
    private var reported = false

    init(model: AppModel, window: NSWindow?) {
        self.model = model
        self.window = window
    }

    private func report(_ completed: Bool) {
        guard !reported else { return }
        reported = true
        let model = model
        Task { await model.shareFinished(completed: completed) }
        ShareService.ended(self)
    }

    // MARK: The picker

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService
    ) -> NSSharingServiceDelegate? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Closed without a choice: nothing was shared.
        if service == nil { report(false) }
    }

    // MARK: The service

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        report(true)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        report(false)
    }

    func sharingService(
        _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        window
    }
}

/// Where on the screen a share was asked for: the view behind a button, for the picker
/// to open beside.
@MainActor
final class ShareAnchor {
    fileprivate(set) weak var view: NSView?

    nonisolated init() {}
}

/// Puts an invisible view behind a control and notes it in the anchor.
struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

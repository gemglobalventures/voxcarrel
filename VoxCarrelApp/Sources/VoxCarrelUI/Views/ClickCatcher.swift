import AppKit
import SwiftUI

/// Lies over (or behind) a view and reports mouse clicks on it as they happen: at the
/// press, with the keys held and the click count, so that a click selects at once and is
/// not held back to see whether a second click follows.
///
/// A click for a context menu (the secondary button, or a click with Control held) is
/// reported through `onContextClick` and then passed on, so that the menu of the view it
/// lies over opens as usual.
struct ClickCatcher: NSViewRepresentable {
    /// Shown when the pointer rests here.
    var toolTip: String?
    var onContextClick: (() -> Void)?
    var onClick: (_ modifiers: NSEvent.ModifierFlags, _ clickCount: Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
        view.onContextClick = onContextClick
        view.toolTip = toolTip
    }

    final class CatcherView: NSView {
        var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?
        var onContextClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                onContextClick?()
                super.mouseDown(with: event)
            } else {
                onClick?(event.modifierFlags, event.clickCount)
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onContextClick?()
            super.rightMouseDown(with: event)
        }
    }
}

import Foundation
import SwiftUI
import VoxCarrelCore

// What a package that adds features to the app is given to add them with. EX1 onwards.
//
// The app is started with an `AppExtensions`, which is empty when the app is started by
// itself: nothing is added then, and the app is as it is without any of this. An
// extension is another module, so everything it needs is public, here and on `AppModel`.

// MARK: Entitlements

/// A feature an extension adds, as the entitlements are asked about it.
public struct ExtensionFeature: Hashable, Sendable {
    /// What the feature is known by; it is not shown.
    public let id: String
    /// What the feature is called where it is shown.
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Says which features may be used.
public protocol Entitlements: Sendable {
    /// Whether the feature may be used. The open app's own answer is always no.
    func isUnlocked(_ feature: ExtensionFeature) -> Bool
}

/// The open app's own entitlements: no feature may be used.
public struct NoEntitlements: Entitlements {
    public init() {}

    public func isUnlocked(_ feature: ExtensionFeature) -> Bool {
        false
    }
}

// MARK: Book commands

/// A command on books that an extension adds to the Book menu and to a book's context
/// menu, after the app's own. The model asks it about the books each time the menu is
/// drawn, so its answers should be quick.
@MainActor
public protocol BookCommandExtension: AnyObject {
    /// What the command is known by. It is also the end of the accessibility identifier
    /// of its menu item: "menu.book.<id>" and "contextMenu.book.<id>".
    var id: String { get }
    /// The menu item's title for these books.
    func title(for books: Set<Int64>, in model: AppModel) -> String
    /// Whether the command applies to these books now.
    func isEnabled(for books: Set<Int64>, in model: AppModel) -> Bool
    /// Carries the command out on these books.
    func run(for books: Set<Int64>, in model: AppModel)
}

/// One extension command as a menu shows it: what the view draws, and nothing else.
public struct ExtensionCommandItem: Identifiable, Equatable, Sendable {
    /// The command's `id`.
    public let id: String
    public let title: String
    public let isEnabled: Bool
}

// MARK: Sheets

/// The state of a sheet an extension puts on the window, by setting
/// `AppModel.extensionSheet`. Its view is made by a factory the extension registered in
/// `AppExtensions.sheetViews`.
@MainActor
public protocol ExtensionSheet: AnyObject, Observable {
    /// What kind of sheet this is. Sheets of one kind have one id, whatever they show:
    /// the window gives each kind a sheet window of its own, at its own size.
    var id: String { get }
    /// Called when the window closes the sheet: another library was opened, or there
    /// was no view to show it with. It is not called when the extension takes the sheet
    /// down itself, by setting `AppModel.extensionSheet` to nil.
    func closed()
}

/// An extension's sheet as the window's sheet: two are the same when they are the same
/// object.
public struct ExtensionSheetShown: Equatable, @unchecked Sendable {
    // Unchecked: the sheet is the main actor's, and is only read there.
    public let sheet: any ExtensionSheet
    /// The sheet's `id`, read when this was made, so that it can be asked anywhere.
    public let id: String

    @MainActor
    public init(_ sheet: any ExtensionSheet) {
        self.sheet = sheet
        id = sheet.id
    }

    public static func == (a: ExtensionSheetShown, b: ExtensionSheetShown) -> Bool {
        a.sheet === b.sheet
    }
}

// MARK: Settings

/// A tab an extension adds to the Settings window, after the app's own.
public struct ExtensionSettingsPane: Identifiable {
    /// What the tab is known by. It is also the end of the accessibility identifier of
    /// its label: "settings.tab.<id>".
    public let id: String
    /// The tab's title.
    public let title: String
    /// The name of the system image shown with the title.
    public let systemImage: String
    /// Makes what the tab shows. The view lays itself out; the app's own tabs are 560
    /// points wide.
    public let view: @MainActor (AppModel) -> AnyView

    public init(id: String, title: String, systemImage: String, view: @escaping @MainActor (AppModel) -> AnyView) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.view = view
    }
}

// MARK: App commands

/// A command an extension adds to the app's own menu, under About: something of the
/// app as a whole, not of a book or a library.
public struct ExtensionAppCommand: Identifiable {
    /// What the command is known by. It is also the end of the accessibility identifier
    /// of its menu item: "menu.app.<id>".
    public let id: String
    public let title: String
    /// Asked each time the menu is drawn.
    public let isEnabled: @MainActor () -> Bool
    public let perform: @MainActor () -> Void

    public init(
        id: String, title: String, isEnabled: @escaping @MainActor () -> Bool = { true },
        perform: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

// MARK: The container

/// Everything that has been added to the app. It is filled in before the app starts and
/// handed to it; the model keeps it as `AppModel.extensions`.
@MainActor
public final class AppExtensions {
    /// Nothing added. It can be made anywhere, so that it can be the value a parameter
    /// has when none is given.
    public nonisolated init() {}

    /// Which features may be used.
    public var entitlements: any Entitlements = NoEntitlements()
    /// The commands added to the Book menu and to a book's context menu, in this order.
    public var bookCommands: [any BookCommandExtension] = []
    /// What makes the views of extension sheets. Each is asked in turn and answers nil
    /// for a sheet that is not its own.
    public var sheetViews: [@MainActor (any ExtensionSheet) -> AnyView?] = []
    /// The tabs added to the Settings window, in this order.
    public var settingsPanes: [ExtensionSettingsPane] = []
    /// The commands added to the app's own menu, under About, in this order.
    public var appCommands: [ExtensionAppCommand] = []
    /// Called once the model exists, so an extension can keep a reference or set itself up.
    public var onStart: [@MainActor (AppModel) -> Void] = []

    /// The view for this sheet: the first a factory answers with; nil when none does.
    public func sheetView(for sheet: any ExtensionSheet) -> AnyView? {
        for make in sheetViews {
            if let view = make(sheet) { return view }
        }
        return nil
    }
}

// MARK: What the model does with them

extension AppModel {
    // MARK: App commands

    /// The extension commands of the app's own menu, as the menu shows them, in the
    /// order they were added. Empty when there are none: the menu then shows nothing more.
    public var extensionAppCommands: [ExtensionCommandItem] {
        extensions.appCommands.map { ExtensionCommandItem(id: $0.id, title: $0.title, isEnabled: $0.isEnabled()) }
    }

    /// Carries out the app command with this id, when there is one and it is enabled.
    public func performExtensionAppCommand(_ id: String) {
        guard let command = extensions.appCommands.first(where: { $0.id == id }), command.isEnabled() else { return }
        command.perform()
    }

    // MARK: Book commands

    /// EX2: the extension commands for these books, as a menu shows them, in the order
    /// they were added. Empty when there are none: the menu then shows nothing more.
    ///
    /// A command is enabled by its own answer. None is while no library is open, or
    /// when any of the books is a row that stands for a book the library does not have:
    /// such a row is no book's, and nothing should be asked to act on it.
    public func extensionCommands(for books: Set<Int64>) -> [ExtensionCommandItem] {
        let applies = extensionCommandsApply(to: books)
        return extensions.bookCommands.map { command in
            ExtensionCommandItem(
                id: command.id, title: command.title(for: books, in: self),
                isEnabled: applies && command.isEnabled(for: books, in: self))
        }
    }

    /// EX2: runs the extension command with this id on these books. Nothing is done
    /// when there is no such command, or it is not enabled for them.
    public func runExtensionCommand(_ id: String, for books: Set<Int64>) {
        guard extensionCommandsApply(to: books),
              let command = extensions.bookCommands.first(where: { $0.id == id }),
              command.isEnabled(for: books, in: self)
        else { return }
        command.run(for: books, in: self)
    }

    private func extensionCommandsApply(to books: Set<Int64>) -> Bool {
        isLibraryOpen && !holdsMissing(books)
    }

    // MARK: Sheets

    /// EX3: the sheet an extension has put on the window; not nil shows it. It is one
    /// of the window's sheets like any other: one at a time, in the model's order
    /// (`windowSheet`), and while it is up nothing else that needs a sheet can begin.
    ///
    /// A sheet that no factory in `extensions.sheetViews` has a view for is not kept:
    /// there would be nothing to show, and nothing to close it with. It is told it was
    /// closed.
    public var extensionSheet: (any ExtensionSheet)? {
        get { storedExtensionSheet }
        set {
            if let newValue, extensions.sheetView(for: newValue) == nil {
                storedExtensionSheet = nil
                newValue.closed()
                return
            }
            storedExtensionSheet = newValue
        }
    }

    /// EX3: whether an extension's sheet can be put up now: nothing is running, no
    /// question is waiting, and no sheet of the window is up. It needs no library.
    public var canShowExtensionSheet: Bool {
        busyLabel == nil && storedPrompt == nil && windowSheet(progressDue: false) == nil
    }

    /// Takes down the extension's sheet, when there is one, and tells it so.
    func closeExtensionSheet() {
        guard let sheet = storedExtensionSheet else { return }
        storedExtensionSheet = nil
        sheet.closed()
    }

    // MARK: Working on the library

    /// The folder of the library that is open; nil while none is.
    public var libraryRoot: URL? {
        worker?.libraryRoot
    }

    /// EX5: runs an extension's work on the library as one operation, like the app's
    /// own: `busyLabel` is `label` while it runs, and everything shown is read again
    /// when it ends, whether or not it succeeded. An error it throws is shown as a
    /// sentence in `alert`.
    ///
    /// The work is not run when an operation is already running, when no library is
    /// open, or while a sheet that does its own work is up.
    ///
    /// - Returns: Whether the work was run and threw nothing.
    @discardableResult
    public func performExtensionWork(_ label: String, _ work: (LibraryWorker) async throws -> Void) async -> Bool {
        guard let worker = await begin(label) else { return false }
        var succeeded = true
        do {
            try await work(worker)
        } catch {
            show(error)
            succeeded = false
        }
        await finish()
        return succeeded
    }
}

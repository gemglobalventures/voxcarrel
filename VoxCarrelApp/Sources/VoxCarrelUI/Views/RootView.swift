import SwiftUI
import UniformTypeIdentifiers
import VoxCarrelAppCore

/// The window: the welcome panel, the library-not-available panel, or the library.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.status {
            case .notChosen:
                WelcomeView()
            case .unavailable(let folder):
                LibraryProblemView(
                    title: "Library Not Available",
                    symbol: "externaldrive.badge.questionmark",
                    message: "VoxCarrel cannot find the library folder, or cannot make changes in it. "
                        + "If it is on an external drive, connect the drive and try again.",
                    path: folder.path)
            case .available:
                if let failure = model.openFailure {
                    LibraryProblemView(
                        title: "Library Could Not Be Opened",
                        symbol: "exclamationmark.triangle",
                        message: failure,
                        path: nil)
                } else {
                    LibraryView()
                        .modifier(ImportDropTarget())
                }
            }
        }
        .modifier(Dialogs())
        .onAppear {
            let openWindow = openWindow
            MainWindow.open = { openWindow(id: "main") }
        }
    }
}

/// V1: no library has been chosen yet.
private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to VoxCarrel", systemImage: "books.vertical")
        } description: {
            Text(
                "A library folder is where VoxCarrel keeps your audiobooks and ebooks, filed by author and title."
            )
        } actions: {
            Button("Choose Library Folder…") {
                Panels.chooseLibrary(for: model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("welcome.chooseLibrary")
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .accessibilityIdentifier("welcome.panel")
    }
}

/// V1: the library folder is not there, or is there and would not open.
private struct LibraryProblemView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let symbol: String
    let message: String
    let path: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            VStack(spacing: 8) {
                Text(message)
                    .accessibilityIdentifier("libraryProblem.message")
                if let path {
                    Text(path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("libraryProblem.path")
                }
            }
        } actions: {
            Button("Try Again") {
                Task { await model.retryLibrary() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("libraryProblem.tryAgain")
            Button("Choose Another Folder…") {
                Panels.chooseLibrary(for: model)
            }
            .accessibilityIdentifier("libraryProblem.chooseAnother")
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .accessibilityIdentifier("libraryProblem.panel")
    }
}

/// X1: files and folders dropped anywhere on the library are imported. A drop target
/// inside it (the inspector's cover) takes what is dropped on it for itself.
private struct ImportDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], delegate: Delegate(model: model, isTargeted: $isTargeted))
            .overlay {
                if isTargeted {
                    Rectangle()
                        .strokeBorder(.tint, lineWidth: 4)
                        .background(.tint.opacity(0.08))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private struct Delegate: DropDelegate {
        let model: AppModel
        @Binding var isTargeted: Bool

        /// Nothing is taken, or shown as about to be, while an import cannot begin.
        func validateDrop(info: DropInfo) -> Bool {
            model.canImport && info.hasItemsConforming(to: [.fileURL])
        }

        func dropEntered(info: DropInfo) {
            isTargeted = true
        }

        func dropExited(info: DropInfo) {
            isTargeted = false
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .copy)
        }

        func performDrop(info: DropInfo) -> Bool {
            isTargeted = false
            let providers = info.itemProviders(for: [.fileURL])
            let model = model
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.fileURL(from: provider) { urls.append(url) }
                }
                await model.beginImport(urls)
            }
            return true
        }

        private static func fileURL(from provider: NSItemProvider) async -> URL? {
            await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
        }
    }
}

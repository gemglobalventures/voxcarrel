import SwiftUI
import VoxCarrelAppCore

/// The window: the welcome panel, the library-not-available panel, or the library.
struct RootView: View {
    @Environment(AppModel.self) private var model

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
                }
            }
        }
        .modifier(Dialogs())
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

import SwiftUI

/// Proves the build and launch path: one window showing the app's name and the
/// library folder it was pointed at (`-libraryPath <folder>` on the command line).
@main
struct VoxCarrelApp: App {
    @AppStorage("libraryPath") private var libraryPath = ""

    var body: some Scene {
        WindowGroup("VoxCarrel") {
            VStack(spacing: 12) {
                Text("VoxCarrel").font(.largeTitle)
                Text(libraryPath.isEmpty ? "No library chosen" : libraryPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(40)
            .frame(minWidth: 480, minHeight: 240)
        }
    }
}

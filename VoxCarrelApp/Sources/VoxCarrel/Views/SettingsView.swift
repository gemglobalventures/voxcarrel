import SwiftUI
import VoxCarrelAppCore

/// V7
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Library") {
                LabeledContent("Library folder") {
                    Text(model.libraryFolder?.path ?? "No folder chosen")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings.libraryPath")
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") {
                        model.revealLibraryFolder()
                    }
                    .disabled(model.libraryFolder == nil)
                    .accessibilityIdentifier("settings.revealLibrary")
                    Button("Choose…") {
                        Panels.chooseLibrary(for: model)
                    }
                    .accessibilityIdentifier("settings.chooseLibrary")
                }
            }
            Section("Importing") {
                Toggle("Copy files when importing (leave originals in place)", isOn: $model.copyOnImport)
                    .accessibilityIdentifier("settings.copyOnImport")
            }
            Section("Online Lookup") {
                Picker("Audible store", selection: $model.audibleStore) {
                    ForEach(AppModel.audibleStoreChoices) { choice in
                        Text(choice.title).tag(choice.store)
                    }
                }
                .accessibilityIdentifier("settings.audibleStore")
                Text(
                    model.lookupPrivacyText
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.lookupPrivacy")
            }
        }
        .formStyle(.grouped)
        // A question or a message is shown by the main window: it comes in front of this one.
        .onChange(of: model.wantsToBeSeen) { _, wanted in
            if wanted { openWindow(id: "main") }
        }
        .onAppear {
            let openWindow = openWindow
            if MainWindow.open == nil { MainWindow.open = { openWindow(id: "main") } }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

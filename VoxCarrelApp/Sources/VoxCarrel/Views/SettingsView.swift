import SwiftUI
import VoxCarrelAppCore

/// V7
struct SettingsView: View {
    @Environment(AppModel.self) private var model

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
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V7; plan 7, V3: the settings, on two tabs: General (the library folder, copying on
/// import) and Lookup (the sources, the Audible stores, and what a lookup sends).
struct SettingsView: View {
    /// Both tabs are this wide; the window takes its height from the tab that is shown.
    static let width: CGFloat = 560

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                        .accessibilityIdentifier("settings.tab.general")
                }
            LookupSettings()
                .tabItem {
                    Label("Lookup", systemImage: "magnifyingglass")
                        .accessibilityIdentifier("settings.tab.lookup")
                }
        }
        // A question or a message is shown by the main window: it comes in front of this one.
        .onChange(of: model.wantsToBeSeen) { _, wanted in
            if wanted { openWindow(id: "main") }
        }
        .onAppear {
            let openWindow = openWindow
            if MainWindow.open == nil { MainWindow.open = { openWindow(id: "main") } }
        }
    }
}

/// The library folder, and whether importing copies.
private struct GeneralSettings: View {
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
        .frame(width: SettingsView.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Plan 7, V3: the lookup sources, each with its switch; under Audible, its stores; and
/// at the foot what a lookup sends. The tab has a height of its own and scrolls within
/// it, so that the window is no taller on a small screen.
private struct LookupSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Sources") {
                ForEach(model.lookupSourceRows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        SourceRow(row: row)
                        if row.source == .audible {
                            AudibleStores()
                        }
                    }
                }
            }
            Section {
                Text(model.lookupPrivacyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.lookupPrivacy")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width, height: 600)
    }
}

/// One source: its name and what it is good for, its switch, and under them anything
/// there is to warn about.
private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let row: LookupSourceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Its name is the switch's label for VoiceOver; it is written beside it.
                .accessibilityHidden(true)
                Toggle(row.title, isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityHint(row.detail)
                    .accessibilityIdentifier("settings.source.\(row.source.rawValue)")
            }
            if let note = row.note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.source.\(row.source.rawValue).note")
            }
        }
    }

    private var isOn: Binding<Bool> {
        let model = model
        let source = row.source
        return Binding(
            get: { row.isOn },
            set: { model.setLookupSource(source, on: $0) })
    }
}

/// Under Audible: which store is the user's own, and which others a lookup searches.
/// The user's own is always searched. The list cannot be changed while Audible is off.
private struct AudibleStores: View {
    private static let columns = [GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .leading)]

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            // Not only a lookup's: it is also where a book marked as on Audible is taken
            // to be, so it can be chosen while Audible is off as a source.
            HStack(spacing: 8) {
                Text("Your store")
                Picker("Your Audible store", selection: $model.audibleStore) {
                    ForEach(AppModel.audibleStoreChoices) { choice in
                        Text(choice.title).tag(choice.store)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Your Audible store")
                .accessibilityIdentifier("settings.ownAudibleStore")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Stores to search")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                    ForEach(model.audibleStoreRows) { row in
                        StoreTick(row: row)
                    }
                }
            }
            .disabled(!model.audibleStoresAreEnabled)
        }
        .font(.callout)
        .padding(.leading, 16)
    }
}

/// One store's tick. The user's own store says so, and its tick cannot be taken off.
private struct StoreTick: View {
    @Environment(AppModel.self) private var model
    let row: AudibleStoreRow

    var body: some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.title)
                    .lineLimit(1)
                if row.isOwn {
                    Text("your store")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!row.isEnabled)
        .accessibilityIdentifier("settings.audibleStore.\(row.store.rawValue)")
    }

    private var isOn: Binding<Bool> {
        let model = model
        let store = row.store
        return Binding(
            get: { row.isOn },
            set: { model.setAudibleStore(store, searched: $0) })
    }
}

import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V7; plan 7, V3: the settings, on three tabs: General (the library folder, the folder
/// layout, copying on import, the Audible account, the Kindle's address), Lookup (the sources, the Audible stores, and what a lookup sends) and Watch
/// Folders (the folders watched for books that arrive).
struct SettingsView: View {
    /// Every tab is this wide; the window takes its height from the tab that is shown.
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
            WatchFolderSettings(model: model)
                .tabItem {
                    Label("Watch Folders", systemImage: "tray.and.arrow.down")
                        .accessibilityIdentifier("settings.tab.watchFolders")
                }
            // The tabs extensions have added, after the app's own.
            ForEach(model.extensions.settingsPanes) { pane in
                pane.view(model)
                    .tabItem {
                        Label(pane.title, systemImage: pane.systemImage)
                            .accessibilityIdentifier("settings.tab.\(pane.id)")
                    }
            }
        }
        // A question, a message or the preview of a change of folder layout is shown by
        // the main window: it comes in front of this one.
        .onChange(of: model.wantsToBeSeen) { _, wanted in
            if wanted { openWindow(id: "main") }
        }
        .onAppear {
            let openWindow = openWindow
            if MainWindow.open == nil { MainWindow.open = { openWindow(id: "main") } }
        }
    }
}

/// The library folder, how its folders are arranged, and whether importing copies.
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
                if let note = model.librarySyncNote {
                    Label(note, systemImage: "icloud")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.librarySyncNote")
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
            CatalogueSettings(model: model)
            FolderLayoutSettings(model: model)
            BackupSettings(model: model)
            Section("Importing") {
                Toggle("Copy files when importing (leave originals in place)", isOn: $model.copyOnImport)
                    .accessibilityIdentifier("settings.copyOnImport")
            }
            AudibleAccountSettings(model: model)
            KindleAddressSettings(model: model)
            ReadwiseSettings(model: model)
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where the catalogue is kept: with the books, or on this Mac apart from them.
private struct CatalogueSettings: View {
    let model: AppModel
    @State private var isConfirming = false

    var body: some View {
        Section(CatalogueText.heading) {
            Text(model.catalogueStatusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.catalogue.status")
            HStack {
                Spacer()
                Button(model.catalogueIsOnMac ? CatalogueText.moveBackTitle : CatalogueText.moveTitle) {
                    isConfirming = true
                }
                .disabled(!model.canMoveCatalogue)
                .accessibilityIdentifier("settings.catalogue.move")
            }
        }
        .confirmationDialog(
            model.catalogueIsOnMac ? CatalogueText.confirmBack : CatalogueText.confirmMove, isPresented: $isConfirming
        ) {
            Button(CatalogueText.moveButton) {
                let toMac = !model.catalogueIsOnMac
                Task { await model.moveCatalogue(toMac: toMac) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.catalogueIsOnMac ? CatalogueText.confirmBackMessage : CatalogueText.confirmMoveMessage)
        }
    }
}

/// Backups of the catalogue: when the last was made, making one now, and restoring one.
private struct BackupSettings: View {
    let model: AppModel
    /// The backup chosen to restore, in the list.
    @State private var picked: BackupLine.ID?
    @State private var isChoosing = false
    @State private var isConfirming = false

    var body: some View {
        Section(BackupText.heading) {
            Text(BackupText.intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.backupStatusText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.backups.status")
            HStack {
                Spacer()
                Button(BackupText.showTitle) { model.revealBackups() }
                    .disabled(!model.keepsBackups)
                Button(BackupText.restoreTitle) {
                    picked = model.backups.first?.id
                    isChoosing = true
                }
                .disabled(!model.canRestoreBackup)
                .accessibilityIdentifier("settings.backups.restore")
                Button(BackupText.backUpNowTitle) {
                    Task { await model.backUpNow() }
                }
                .disabled(!model.canBackUp)
                .accessibilityIdentifier("settings.backups.now")
            }
        }
        .sheet(isPresented: $isChoosing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(BackupText.confirmTitle)
                    .font(.headline)
                List(model.backups, selection: $picked) { line in
                    Text(line.text)
                        .lineLimit(1)
                }
                .listStyle(.inset)
                .frame(height: 220)
                .accessibilityIdentifier("settings.backups.list")
                Text(BackupText.confirmMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { isChoosing = false }
                        .keyboardShortcut(.cancelAction)
                    Button(BackupText.confirmButton) {
                        isChoosing = false
                        isConfirming = true
                    }
                    .disabled(picked == nil)
                    .accessibilityIdentifier("settings.backups.choose")
                }
            }
            .padding(20)
            .frame(width: 520)
        }
        .confirmationDialog(BackupText.confirmTitle, isPresented: $isConfirming) {
            Button(BackupText.confirmButton, role: .destructive) {
                guard let picked else { return }
                Task { await model.restoreBackup(picked) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(BackupText.confirmMessage)
        }
    }
}

/// The Audible account: linking one while none is linked; which is linked, and
/// unlinking it, while one is. The sheet and the question are the library window's.
private struct AudibleAccountSettings: View {
    let model: AppModel

    var body: some View {
        Section("Audible Account") {
            if let summary = model.audibleAccountSummary {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(summary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.audible.summary")
                    Button("Unlink…") {
                        model.unlinkAudible()
                    }
                    .disabled(!model.canUnlinkAudible)
                    .accessibilityIdentifier("settings.audible.unlink")
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.lastReadLines(), id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let health = model.accountHealth {
                            ForEach(health) { line in
                                Label(line.text, systemImage: line.isWorking ? "checkmark.circle" : "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(line.isWorking ? Color.secondary : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("settings.audible.health.\(line.id)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.audible.lastRead")
                    Button(model.checkConnectionTitle) {
                        Task { await model.checkConnection() }
                    }
                    .disabled(!model.canCheckConnection)
                    .accessibilityIdentifier("settings.audible.check")
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.audibleSettingsText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.audible.explanation")
                    Button("Link Account…") {
                        model.beginAudibleLink()
                    }
                    .disabled(!model.canBeginAudibleLink)
                    .accessibilityIdentifier("settings.audible.link")
                }
            }
        }
    }
}

/// The Kindle's email address, for Send to Kindle when Amazon's app is not installed.
/// What is typed is kept as it is typed; the model says when it is not an address.
private struct KindleAddressSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        Section("Kindle") {
            LabeledContent(KindleText.addressTitle) {
                TextField(KindleText.addressTitle, text: $model.kindleAddress)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel(KindleText.addressTitle)
                    .accessibilityIdentifier("settings.kindle.address")
            }
            if let problem = model.kindleAddressProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.kindle.addressProblem")
            }
            Text(KindleText.addressHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.kindle.addressHelp")
        }
    }
}

/// The Readwise token: a field to paste it into while none is saved; that one is
/// saved, and the button that removes it, while one is. A saved token is never shown.
private struct ReadwiseSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        Section("Readwise") {
            if model.hasReadwiseToken {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.readwiseSavedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.readwise.saved")
                    Button("Remove") {
                        model.removeReadwiseToken()
                    }
                    .disabled(!model.canRemoveReadwiseToken)
                    .accessibilityIdentifier("settings.readwise.remove")
                }
            } else {
                Text(model.readwiseSettingsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.readwise.explanation")
                HStack(spacing: 12) {
                    SecureField("Access token", text: $model.readwiseTokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { model.saveReadwiseToken() }
                        .accessibilityLabel("Readwise access token")
                        .accessibilityIdentifier("settings.readwise.token")
                    Button("Save") {
                        model.saveReadwiseToken()
                    }
                    .disabled(!model.canSaveReadwiseToken)
                    .accessibilityIdentifier("settings.readwise.save")
                }
                if model.offersReadwiseTokenOnThisMac {
                    Button(model.useReadwiseTokenTitle) {
                        model.useReadwiseTokenOnThisMac()
                    }
                    .accessibilityIdentifier("settings.readwise.useExisting")
                }
            }
        }
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
            Section("Series") {
                Toggle(isOn: Binding(get: { model.asksWikidataForSeries }, set: { model.asksWikidataForSeries = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wikidata")
                        Text("Asked what books a series holds, and in what order, when you check a series. It is sent the series' name, or a book's title, and nothing else. Wikidata is open data, and is asked when Audible has no list or is off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("settings.lookup.wikidata")
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
        .frame(width: SettingsView.width, height: 700)
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

/// The folders watched for books that arrive, each with its settings; under them, adding
/// one. The tab has a height of its own and scrolls within it. Nothing can be changed
/// while no library is open: the folders belong to the library.
///
/// The model is handed down, not read from the environment: a row of the list may be
/// drawn once more after the list it was in has gone.
private struct WatchFolderSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.watchFolderRows) { row in
                    WatchFolderRowView(model: model, row: row)
                }
                HStack {
                    Spacer()
                    Button("Add Folder…") {
                        Panels.addWatchFolder(for: model)
                    }
                    .accessibilityIdentifier("settings.watchFolders.add")
                }
            } header: {
                Text("Watch Folders")
            } footer: {
                Text(
                    "VoxCarrel watches these folders while it is open. Books that arrive are listed in the Inbox; "
                        + "nothing is moved until you review them."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.watchFolders.caption")
            }
        }
        .formStyle(.grouped)
        .disabled(!model.isLibraryOpen)
        .frame(width: SettingsView.width, height: 460)
    }
}

/// One watch folder: where it is and its switch; whether its books are moved or copied,
/// whether PDFs count, and its buttons; and under them why it is not being watched.
///
/// Each control shows what the row says and asks the model for the change: the row
/// changes when the library has saved it.
private struct WatchFolderRowView: View {
    let model: AppModel
    let row: WatchFolderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(row.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.watchFolder.\(row.id).path")
                Toggle("Watch \(row.path)", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.watchFolder.\(row.id).enabled")
            }
            HStack(spacing: 12) {
                Picker("When reviewed", selection: mode) {
                    Text("Move").tag(WatchFolderMode.move)
                    Text("Copy").tag(WatchFolderMode.copy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Whether a book reviewed from this folder is moved into the library or copied")
                .accessibilityLabel("Move or copy books from \(row.path)")
                .accessibilityIdentifier("settings.watchFolder.\(row.id).mode")
                Toggle("Include PDFs", isOn: includesPDFs)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.watchFolder.\(row.id).includesPDFs")
                Spacer(minLength: 0)
                Button("Scan Existing Files") {
                    Task { await model.scanExisting(inWatchFolder: row.id) }
                }
                .help("List the books that were in this folder when it was added")
                .accessibilityIdentifier("settings.watchFolder.\(row.id).scanExisting")
                Button("Remove") {
                    Task { await model.removeWatchFolder(row.id) }
                }
                .help("Stop watching this folder. Its files are left as they are.")
                .accessibilityIdentifier("settings.watchFolder.\(row.id).remove")
            }
            .font(.callout)
            .controlSize(.small)
            if let note = row.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.watchFolder.\(row.id).note")
            }
        }
    }

    private var isEnabled: Binding<Bool> {
        let model = model
        let id = row.id
        return Binding(
            get: { row.isEnabled },
            set: { enabled in
                Task { await model.setWatchFolder(id, enabled: enabled) }
            })
    }

    private var includesPDFs: Binding<Bool> {
        let model = model
        let id = row.id
        return Binding(
            get: { row.includesPDFs },
            set: { included in
                Task { await model.setWatchFolder(id, includesPDFs: included) }
            })
    }

    private var mode: Binding<WatchFolderMode> {
        let model = model
        let id = row.id
        return Binding(
            get: { row.mode },
            set: { mode in
                Task { await model.setWatchFolder(id, mode: mode) }
            })
    }
}

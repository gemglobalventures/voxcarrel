import SwiftUI
import VoxCarrelAppCore

/// The library window: sidebar, books, inspector, toolbar and search.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inspectorShown") private var inspectorShown = true

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
                // At the head of the sidebar, as in the system's own Books: in the
                // toolbar the field stood across the edge of the inspector.
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
        } detail: {
            BooksView()
                .frame(minWidth: 320, minHeight: 300)
                .inspector(isPresented: $inspectorShown) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 320, max: 420)
                }
                .navigationTitle(model.windowTitle)
                .navigationSubtitle(model.windowSubtitle)
                .toolbar {
                    LibraryToolbar(model: model, inspectorShown: $inspectorShown)
                }
        }
    }
}

/// V3
private struct LibraryToolbar: ToolbarContent {
    @Bindable var model: AppModel
    @Binding var inspectorShown: Bool

    var body: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $model.viewMode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show books as a grid or as a list")
            .accessibilityIdentifier("toolbar.viewMode")
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $model.sort.key) {
                    ForEach(BookSortKey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                            .accessibilityIdentifier("toolbar.sort.\(key.rawValue)")
                    }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $model.sort.ascending) {
                    Text("Ascending").tag(true)
                        .accessibilityIdentifier("toolbar.sort.ascending")
                    Text("Descending").tag(false)
                        .accessibilityIdentifier("toolbar.sort.descending")
                }
                .pickerStyle(.inline)
                Divider()
                // Plan 10: each series as one row of the list, or one stack in the grid.
                Toggle("Group by Series", isOn: $model.groupsBySeries)
                    .accessibilityIdentifier("toolbar.sort.groupBySeries")
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Choose how books are sorted, and whether a series is shown as one")
            .accessibilityIdentifier("toolbar.sort")
        }
        ToolbarItem {
            Button {
                Panels.importFiles(into: model)
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canImport)
            .help("Import audiobooks and ebooks")
            .accessibilityIdentifier("toolbar.import")
        }
        ToolbarItem {
            Button {
                Task { await model.beginSendToPhone() }
            } label: {
                Label("Send to Phone", systemImage: "iphone")
            }
            .disabled(!model.canSendToPhone)
            .help("Send the selected audiobook to your phone")
            .accessibilityIdentifier("toolbar.sendToPhone")
        }
        ToolbarItem {
            Button {
                inspectorShown.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
            .accessibilityIdentifier("toolbar.inspector")
        }
    }
}

/// The books: as covers or as a table, or a few words when there are none to show.
/// Above the books of a series, what is known of Audible's list of it (plan 9).
private struct BooksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let header = model.seriesHeader {
                SeriesHeaderStrip(model: model, header: header)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let bar = model.statusBar {
                Divider()
                StatusBarStrip(bar: bar)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.booksContent {
        case .notLoaded:
            // The library is being opened, under the progress sheet.
            Color.clear
        case .empty(let empty):
            // G7
            ContentUnavailableView {
                Label(empty.title, systemImage: empty.symbol)
            } description: {
                Text(empty.message)
            }
            .accessibilityIdentifier(empty.accessibilityIdentifier)
        case .books:
            switch model.viewMode {
            case .grid: BookGridView()
            case .list: BookListView()
            }
        case .inbox:
            InboxView()
        }
    }
}

/// The bar along the bottom of the list of books: what is listed, and the library's totals.
private struct StatusBarStrip: View {
    let bar: StatusBar

    var body: some View {
        HStack(spacing: 12) {
            Text(bar.shown)
                .accessibilityIdentifier("statusBar.shown")
            Spacer(minLength: 12)
            Text(bar.library)
                .accessibilityIdentifier("statusBar.library")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

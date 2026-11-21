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
        } detail: {
            BooksView()
                .frame(minWidth: 320, minHeight: 300)
                .inspector(isPresented: $inspectorShown) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
                }
                .navigationTitle(model.windowTitle)
                .navigationSubtitle(model.windowSubtitle)
                .toolbar {
                    LibraryToolbar(model: model, inspectorShown: $inspectorShown)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
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
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Choose how books are sorted")
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
private struct BooksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
        }
    }
}

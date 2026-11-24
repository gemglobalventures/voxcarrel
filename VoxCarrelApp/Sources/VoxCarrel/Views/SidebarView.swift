import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V2: Library, Browse and Collections.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// Which Browse fields are open. All closed at first.
    @State private var expanded: Set<BrowseField> = []
    @State private var nameText = ""
    @State private var isNamingNew = false
    @State private var renaming: BookCollection?
    @State private var deleting: BookCollection?

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                // WF13: first, while there is a watch folder. A count of zero shows no badge.
                if model.showsInbox {
                    Label(model.title(of: .inbox), systemImage: SidebarItem.inbox.symbol)
                        .badge(model.inboxCount)
                        .tag(SidebarItem.inbox)
                        .accessibilityIdentifier("sidebar.inbox")
                }
                ForEach(SidebarItem.fixed, id: \.self) { item in
                    Label(model.title(of: item), systemImage: item.symbol)
                        .badge(Text("\(model.sidebar.counts[item] ?? 0)"))
                        .tag(item)
                        .accessibilityIdentifier("sidebar.\(String(describing: item))")
                }
            }

            Section("Browse") {
                ForEach(BrowseField.sidebarOrder, id: \.self) { field in
                    DisclosureGroup(isExpanded: isExpanded(field)) {
                        ForEach(model.sidebar.browse[field] ?? [], id: \.self) { value in
                            Text(value)
                                .lineLimit(1)
                                .tag(SidebarItem.browse(field, value))
                                .accessibilityIdentifier("sidebar.browse.\(field.rawValue).\(value)")
                        }
                    } label: {
                        Label(field.title, systemImage: field.symbol)
                    }
                    .accessibilityIdentifier("sidebar.browse.\(field.rawValue)")
                }
            }

            // G34–G36: the genres by group, each with its count, then the books that
            // have none. G13, G23, G29: the header has what is done with genres.
            Section {
                ForEach(model.genreTree) { group in
                    DisclosureGroup(isExpanded: isOpen(group.group)) {
                        ForEach(group.genres) { genre in
                            Text(genre.name)
                                .lineLimit(1)
                                .badge(genre.count)
                                .tag(genre.item)
                                .accessibilityIdentifier("sidebar.genre.\(genre.name)")
                        }
                    } label: {
                        Label(group.title, systemImage: group.item.symbol)
                            .lineLimit(1)
                            .badge(group.count)
                            .tag(group.item)
                    }
                    .tag(group.item)
                    .accessibilityIdentifier("sidebar.genreGroup.\(group.group.rawValue)")
                }
                if model.showsNoGenre {
                    Label(model.title(of: .noGenre), systemImage: SidebarItem.noGenre.symbol)
                        .badge(model.noGenreCount)
                        .tag(SidebarItem.noGenre)
                        .contextMenu {
                            // G29
                            Button("Fill in Genres…") {
                                Task { await model.beginGenreFill() }
                            }
                            .disabled(!model.canFillInGenres)
                            .accessibilityIdentifier("sidebar.noGenre.fill")
                        }
                        .accessibilityIdentifier("sidebar.noGenre")
                }
            } header: {
                GenresHeader(model: model)
            }
            // The header's own controls stand where the button that hides a section would.
            .collapsible(false)

            Section("Collections") {
                ForEach(model.sidebar.collections) { collection in
                    if let id = collection.id {
                        Label(collection.name, systemImage: SidebarItem.collection(id).symbol)
                            .lineLimit(1)
                            .tag(SidebarItem.collection(id))
                            .contextMenu {
                                Button("Rename…") {
                                    nameText = collection.name
                                    renaming = collection
                                }
                                .accessibilityIdentifier("sidebar.collection.rename")
                                Button("Delete…", role: .destructive) {
                                    deleting = collection
                                }
                                .accessibilityIdentifier("sidebar.collection.delete")
                            }
                            .accessibilityIdentifier("sidebar.collection.\(collection.name)")
                    }
                }
                Button {
                    nameText = ""
                    isNamingNew = true
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sidebar.newCollection")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
        .alert("New Collection", isPresented: $isNamingNew) {
            TextField("Name", text: $nameText)
                .accessibilityIdentifier("collection.new.name")
            Button("Create") {
                let name = nameText
                Task { await model.createCollection(name: name, adding: []) }
            }
            .accessibilityIdentifier("collection.new.create")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("collection.new.cancel")
        } message: {
            Text("Enter a name for the collection.")
        }
        .alert("Rename Collection", isPresented: isSet($renaming), presenting: renaming) { collection in
            TextField("Name", text: $nameText)
                .accessibilityIdentifier("collection.rename.name")
            Button("Rename") {
                let name = nameText
                if let id = collection.id {
                    Task { await model.renameCollection(id: id, to: name) }
                }
            }
            .accessibilityIdentifier("collection.rename.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("collection.rename.cancel")
        } message: { collection in
            Text("Enter a new name for \"\(collection.name)\".")
        }
        .confirmationDialog(
            "Delete the collection \"\(deleting?.name ?? "")\"?",
            isPresented: isSet($deleting), presenting: deleting
        ) { collection in
            Button("Delete Collection", role: .destructive) {
                if let id = collection.id {
                    Task { await model.deleteCollection(id: id) }
                }
            }
            .accessibilityIdentifier("collection.delete.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("collection.delete.cancel")
        } message: { _ in
            Text("The books in it stay in your library.")
        }
    }

    /// The list always has one item selected: clicking empty space changes nothing.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.sidebarSelection },
            set: { item in
                if let item { model.sidebarSelection = item }
            })
    }

    /// G34: whether a group of genres is open, as the model remembers it.
    private func isOpen(_ group: GenreGroup) -> Binding<Bool> {
        let model = model
        return Binding(
            get: { model.isOpen(group: group) },
            set: { model.setOpen($0, group: group) })
    }

    private func isExpanded(_ field: BrowseField) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(field) },
            set: { open in
                if open { expanded.insert(field) } else { expanded.remove(field) }
            })
    }

    /// True while there is a collection being renamed or deleted; set false, it is forgotten.
    private func isSet(_ collection: Binding<BookCollection?>) -> Binding<Bool> {
        Binding(
            get: { collection.wrappedValue != nil },
            set: { shown in
                if !shown { collection.wrappedValue = nil }
            })
    }
}

/// The heading of the sidebar's genres. G13: "Update files…" with how many books have
/// files to update, while any has. G23, G29: a menu of what is done with genres.
///
/// Handed the model: it is drawn by the list, and reads nothing from the environment.
private struct GenresHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text("Genres")
                .lineLimit(1)
            Spacer(minLength: 4)
            if let offer = model.genreFilesOffer {
                Button {
                    Task { await model.beginGenreFilesUpdate() }
                } label: {
                    HStack(spacing: 4) {
                        Text(offer.title)
                            .lineLimit(1)
                        Text("\(offer.count)")
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canUpdateGenreFiles)
                .help(offer.help)
                .accessibilityIdentifier("sidebar.genres.updateFiles")
            }
            Menu {
                GenreCommandItems(model: model, updateTitle: "Update Files…", prefix: "sidebar.genres.menu")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Manage genres, update files and fill in genres")
            .accessibilityLabel("Genres")
            .accessibilityIdentifier("sidebar.genres.menu")
        }
    }
}

/// G14, G23, G29: the three commands about genres, for the Library menu and for the
/// menu in the sidebar's heading. Whether each applies is the model's to say.
struct GenreCommandItems: View {
    let model: AppModel
    /// What the command that updates files is called here.
    let updateTitle: String
    /// The start of each item's accessibility identifier.
    let prefix: String

    var body: some View {
        Button("Manage Genres…") {
            model.beginManageGenres()
        }
        .disabled(!model.canManageGenres)
        .accessibilityIdentifier("\(prefix).manageGenres")
        Button(updateTitle) {
            Task { await model.beginGenreFilesUpdate() }
        }
        .disabled(!model.canUpdateGenreFiles)
        .accessibilityIdentifier("\(prefix).updateFiles")
        Button("Fill in Genres…") {
            Task { await model.beginGenreFill() }
        }
        .disabled(!model.canFillInGenres)
        .accessibilityIdentifier("\(prefix).fillInGenres")
    }
}

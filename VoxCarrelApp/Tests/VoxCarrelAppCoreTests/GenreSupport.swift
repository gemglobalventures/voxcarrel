import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

extension Harness {
    /// The genre tag the book's first file holds, read from the file itself; nil for none.
    func genreTag(_ title: String) throws -> String? {
        let url = try #require(try fileURLs(try id(title)).first)
        return try FileMetadataIO().read(url).metadata.genreSource
    }

    /// The names of the sidebar's genres, group by group.
    var treeNames: [[String]] {
        model.genreTree.map { $0.genres.map(\.name) }
    }

    /// Opens Manage Genres and gives its state.
    func manager() throws -> GenreManager {
        model.beginManageGenres()
        return try #require(model.genreManager)
    }

    /// Renames a genre through Manage Genres, and closes it.
    func rename(_ name: String, to new: String) async throws {
        let manager = try manager()
        manager.beginRename(name)
        manager.renameText = new
        await manager.commitRename()
        model.closeManageGenres()
    }

    /// Makes a genre of the owner's own and gives it to these books, as the inspector would.
    func give(_ genre: String, in group: GenreGroup, to titles: [String]) async throws {
        for title in titles {
            try await select(title)
            await model.createDraftGenre(genre, group: group)
            await model.save()
        }
        model.select([])
        await model.settle()
    }
}

/// A library of ebooks that have no genre, for Fill in Genres: "Dune" by Frank Herbert,
/// "Emma" by Jane Austen and "Zen Gardens" by Ann Lee.
@MainActor
func fillLibrary() async throws -> Harness {
    try await Harness.merging { library in
        _ = try library.epub("Dune", "Frank Herbert")
        _ = try library.epub("Emma", "Jane Austen")
        _ = try library.epub("Zen Gardens", "Ann Lee")
    }.h
}

import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// G21, G22: what the genre field offers as the owner types, from the library's list.
@Suite struct GenreChoicesTests {
    /// The built-in list, with two of the owner's own, one built-in genre renamed and
    /// one merged away.
    private func catalogue() -> GenreCatalogue {
        var entries = BuiltInGenre.all.map { GenreEntry(name: $0.name, group: $0.group, builtInName: $0.name) }
        // Humour is now called Comedy; Horror was merged into Fantasy.
        entries[entries.firstIndex { $0.name == "Humour" }!].name = "Comedy"
        let horror = entries.firstIndex { $0.name == "Horror" }!
        entries[horror].isHidden = true
        entries[horror].mergedInto = "Fantasy"
        entries.append(GenreEntry(name: "Sea Stories", group: .fiction))
        entries.append(GenreEntry(name: "Atlases", group: .other))
        entries.append(GenreEntry(name: "Pub Quiz", group: .other))
        return GenreCatalogue(entries)
    }

    @Test func GH2_theGroupsHaveTheirTitles() {
        #expect(GenreGroup.allCases.map(\.title) == ["Fiction", "Non-fiction", "Children & Young Adult", "Other"])
    }

    @Test func GH21_nothingTypedOffersEveryGenreThatIsShownByGroup() {
        let offered = catalogue().suggestions(for: "")
        #expect(offered.groups.map(\.title) == ["Fiction", "Non-fiction", "Children & Young Adult", "Other"])
        let fiction = offered.groups[0].genres.map(\.name)
        // GH-a: the built-in ones in their own order, then the owner's own by name.
        #expect(fiction == [
            "Literary & General", "Classics", "Crime & Mystery", "Thrillers & Spies", "Science Fiction", "Fantasy",
            "Historical Fiction", "Romance", "Comedy", "Sea Stories",
        ])
        #expect(offered.groups[3].genres.map(\.name) == ["Atlases", "Pub Quiz"])
        // A genre that was merged away is not offered.
        #expect(!offered.groups.flatMap(\.genres).contains { $0.name == "Horror" })
        #expect(offered.createName == nil)
        #expect(offered.problem == nil)
    }

    @Test func GH21_aTypedPrefixNarrowsTheGenresWhateverItsCapitals() {
        let offered = catalogue().suggestions(for: "  sc")
        #expect(offered.groups.map(\.group) == [.fiction, .nonFiction])
        #expect(offered.groups[0].genres.map(\.name) == ["Science Fiction"])
        #expect(offered.groups[1].genres.map(\.name) == ["Science & Nature"])
        // "sc" is no genre's name and no source's: it can be made one.
        #expect(offered.createName == "sc")
        #expect(offered.createTitle == "Create \"sc\"")
    }

    @Test func GH21_genresTheBookHasAreNotOfferedAgain() {
        let offered = catalogue().suggestions(for: "Fantasy", excluding: ["fantasy"])
        #expect(offered.groups.isEmpty)
        // Fantasy is on the list, so there is nothing to create either.
        #expect(offered.createName == nil)
    }

    @Test func GH22_aSourceNameOffersTheGenreItMeansAndNotCreate() {
        let offered = catalogue().suggestions(for: "sci-fi")
        #expect(offered.groups.flatMap(\.genres).map(\.name) == ["Science Fiction"])
        #expect(offered.createName == nil)

        // A renamed built-in genre is offered by its new name, for its old one too.
        let renamed = catalogue().suggestions(for: "Humor")
        #expect(renamed.groups.flatMap(\.genres).map(\.name) == ["Comedy"])
        #expect(renamed.createName == nil)

        // The name of a genre that was merged away offers the genre it went into.
        let merged = catalogue().suggestions(for: "horror")
        #expect(merged.groups.flatMap(\.genres).map(\.name) == ["Fantasy"])
        #expect(merged.createName == nil)
    }

    @Test func GH22_aNameThatIsNotOnTheListOffersCreateTidied() {
        let offered = catalogue().suggestions(for: "  Cold   War ")
        #expect(offered.groups.isEmpty)
        #expect(offered.createName == "Cold War")
        #expect(offered.createTitle == "Create \"Cold War\"")
        #expect(offered.problem == nil)
        #expect(GenreSuggestions.createGroups == [.fiction, .nonFiction, .children, .other])
    }

    @Test(arguments: ["Cops, Robbers", "Cops; Robbers", "Cops/Robbers"])
    func GH22_aNameWithASeparatorIsRefusedWithTheReason(typed: String) {
        let offered = catalogue().suggestions(for: typed)
        #expect(offered.createName == nil)
        #expect(offered.createTitle == nil)
        #expect(offered.problem == "A genre's name cannot have a comma, a semicolon or a slash in it.")
    }

    @Test func GH22_whatTypedTextIsOnTheListIsWhatTheLibrarySays() {
        let catalogue = catalogue()
        #expect(catalogue.listedGenre(forTyped: "fantasy") == "Fantasy")
        #expect(catalogue.listedGenre(forTyped: "SF") == "Science Fiction")
        #expect(catalogue.listedGenre(forTyped: "humour") == "Comedy")
        #expect(catalogue.listedGenre(forTyped: "Horror") == "Fantasy")
        #expect(catalogue.listedGenre(forTyped: "pub quiz") == "Pub Quiz")
        #expect(catalogue.listedGenre(forTyped: "Cold War") == nil)
        #expect(catalogue.names(["humour", "Horror", "FANTASY", "Cold War"]) == ["Comedy", "Fantasy", "Cold War"])
    }

    // MARK: Chips

    @Test func GH21_chipsAreAddedOnceRemovedAndMoved() {
        var genres = ["Fantasy", "Humour"]
        genres = GenreChips.adding("History", to: genres)
        // G1: a genre is not there twice, whatever its capitals.
        genres = GenreChips.adding("fantasy", to: genres)
        #expect(genres == ["Fantasy", "Humour", "History"])
        #expect(GenreChips.moving(genres, from: 2, to: 0) == ["History", "Fantasy", "Humour"])
        #expect(GenreChips.moving(genres, from: 0, to: 2) == ["Humour", "History", "Fantasy"])
        // A place that is not there changes nothing.
        #expect(GenreChips.moving(genres, from: 5, to: 0) == genres)
        #expect(GenreChips.removing("HUMOUR", from: genres) == ["Fantasy", "History"])
        // G37
        #expect(GenreChips.shown(genres) == "Fantasy, Humour, History")
    }
}

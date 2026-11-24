import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct GenreListTests {
    @Test func G2_theBuiltInListIsTheTwentySevenInOrder() {
        let fiction = [
            "Literary & General", "Classics", "Crime & Mystery", "Thrillers & Spies", "Science Fiction", "Fantasy",
            "Historical Fiction", "Romance", "Horror", "Humour",
        ]
        let nonFiction = [
            "Biography & Memoir", "History", "Politics & Society", "Business & Careers", "Money & Investing",
            "Science & Nature", "Technology", "Health & Mind", "Self-Development", "Philosophy & Religion",
            "Arts & Culture", "Travel & Places", "Sports & Outdoors", "True Crime", "Reference & Learning",
        ]
        let children = ["Children", "Young Adult"]
        #expect(BuiltInGenre.all.map(\.name) == fiction + nonFiction + children)
        #expect(BuiltInGenre.all.count == 27)
        #expect(BuiltInGenre.all.filter { $0.group == .fiction }.map(\.name) == fiction)
        #expect(BuiltInGenre.all.filter { $0.group == .nonFiction }.map(\.name) == nonFiction)
        #expect(BuiltInGenre.all.filter { $0.group == .children }.map(\.name) == children)
        #expect(BuiltInGenre.all.allSatisfy { $0.group != .other })
    }

    @Test func G2_theGroupsAreFixed() {
        #expect(GenreGroup.allCases == [.fiction, .nonFiction, .children, .other])
        #expect(GenreGroup.allCases.map(\.rawValue) == ["fiction", "nonFiction", "children", "other"])
    }

    @Test func G7_twoBuiltInGenresAreGeneral() {
        #expect(BuiltInGenre.all.filter(\.isGeneral).map(\.name) == ["Literary & General", "Reference & Learning"])
    }

    @Test func G3_aBuiltInGenreIsFoundByItsNameWhateverTheCase() {
        #expect(BuiltInGenre.named("crime & mystery")?.name == "Crime & Mystery")
        #expect(BuiltInGenre.named("  Humour ")?.group == .fiction)
        #expect(BuiltInGenre.named("LitRPG") == nil)
    }

    @Test func G1_namesAreComparedWithoutRegardToCase() {
        #expect(GenreName.same("Crime & Mystery", "crime & MYSTERY"))
        #expect(GenreName.same("Élan", "élan"))
        #expect(!GenreName.same("Crime & Mystery", "Crime and Mystery"))
        #expect(!GenreName.same("Horror", "Horror "))
    }

    @Test func G5_noBuiltInNameHoldsASeparator() {
        for genre in BuiltInGenre.all {
            #expect(GenreName.valid(genre.name) == genre.name)
        }
        let names = BuiltInGenre.all.map { $0.name.lowercased() }
        #expect(Set(names).count == names.count)
    }

    @Test func G9_aNameIsTidied() {
        #expect(GenreName.valid("  Grimdark   Western \n") == "Grimdark Western")
        #expect(GenreName.valid("Sci-Fi & Co’s") == "Sci-Fi & Co’s")
        #expect(GenreName.valid("a\tb") == "a b")
    }

    @Test func G22_aNameWithASeparatorOrNothingInItIsNotValid() {
        #expect(GenreName.valid("") == nil)
        #expect(GenreName.valid("   ") == nil)
        #expect(GenreName.valid("Mystery, Thriller & Suspense") == nil)
        #expect(GenreName.valid("Horror; Romance") == nil)
        #expect(GenreName.valid("Mystery/Thriller") == nil)
    }
}

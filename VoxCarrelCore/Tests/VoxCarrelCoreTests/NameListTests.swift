import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct NameListTests {
    @Test func joinsWithSemicolons() {
        #expect(NameList.join(["Andy Weir", "Ray Porter"]) == "Andy Weir; Ray Porter")
        #expect(NameList.join(["Tolkien, J. R. R."]) == "Tolkien, J. R. R.")
        #expect(NameList.join([]) == nil)
    }

    @Test func ourOwnOutputRoundTrips() {
        for names in [["Andy Weir"], ["Tolkien, J. R. R.", "Lewis, C. S."], ["A B", "C D", "E F"]] {
            #expect(NameList.split(NameList.join(names)) == names)
        }
    }

    @Test func splitsOtherAppsCommaLists() {
        #expect(NameList.split("Andy Weir, Ray Porter") == ["Andy Weir", "Ray Porter"])
        // An ampersand is part of a name far more often than it separates two: it never splits.
        #expect(NameList.split("Terry Pratchett & Neil Gaiman") == ["Terry Pratchett & Neil Gaiman"])
        #expect(NameList.split("A B ;C D") == ["A B", "C D"])
    }

    @Test func surnameFirstNamesStayWhole() {
        #expect(NameList.split("Tolkien, J. R. R.") == ["Tolkien, J. R. R."])
        #expect(NameList.split("King, Stephen") == ["King, Stephen"])
    }

    @Test func emptyAndBlankGiveNothing() {
        #expect(NameList.split(nil) == [])
        #expect(NameList.split("  ") == [])
        #expect(NameList.split(" ; ; ") == [])
    }

    @Test func namesWithAnAmpersandStayWhole() {
        #expect(NameList.split("Simon & Schuster") == ["Simon & Schuster"])
        #expect(NameList.split("Penn & Teller") == ["Penn & Teller"])
        #expect(NameList.split("Penn & Teller; Simon & Schuster") == ["Penn & Teller", "Simon & Schuster"])
        for names in [["Simon & Schuster"], ["Penn & Teller", "Andy Weir"]] {
            #expect(NameList.split(NameList.join(names)) == names)
        }
    }
}

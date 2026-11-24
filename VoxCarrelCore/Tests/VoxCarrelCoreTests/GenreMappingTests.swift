import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct GenreMappingTests {
    private func genres(_ text: String) -> [String] {
        GenreMapping.map(.text(text)).names
    }

    private func genres(paths: [[String]]) -> [String] {
        GenreMapping.map(.paths(paths)).names
    }

    private func path(_ text: String) -> [String] {
        text.components(separatedBy: " > ")
    }

    // MARK: G5 The table

    @Test func G5_everyNameInTheTableMapsToABuiltInGenre() {
        let builtIn = Set(BuiltInGenre.all.map(\.name))
        var seen = 0
        for top in GenreTable.tops {
            #expect(builtIn.contains(top.genre), "\(top.name)")
            for row in top.rows {
                if let genre = row.genre { #expect(builtIn.contains(genre), "\(top.name) > \(row.name)") }
                seen += 1
            }
        }
        for row in GenreTable.plain {
            #expect(row.genre.map(builtIn.contains) == true, "\(row.name)")
            seen += 1
        }
        #expect(seen > 400)
        #expect(GenreTable.tops.count == 24)
    }

    @Test func G5_everyBuiltInGenreIsMeantBySomeName() {
        var meant = Set(GenreTable.tops.map(\.genre))
        for top in GenreTable.tops { meant.formUnion(top.rows.compactMap(\.genre)) }
        for genre in BuiltInGenre.all { #expect(meant.contains(genre.name), "\(genre.name)") }
    }

    @Test func G5_everyTopAndSecondLevelNameIsKnown() {
        #expect(AudibleNames.secondLevel.count == 24)
        let builtIn = Set(BuiltInGenre.all.map(\.name))
        for (top, names) in AudibleNames.secondLevel {
            let alone = GenreMapping.map(.paths([[top]]))
            #expect(alone.builtIn.count == 1 && alone.unknown.isEmpty, "\(top)")
            #expect(genres(top).count == 1 && builtIn.contains(genres(top)[0]), "\(top) as text")
            for name in names {
                #expect(GenreTable.row(name, under: top)?.genre != nil, "\(top) > \(name)")
                let flat = GenreMapping.map(.text(name))
                #expect(flat.builtIn.count == 1 && flat.unknown.isEmpty, "\(name) as text")
            }
        }
    }

    @Test func G5_everyDeeperNameUnderTheThreeFictionTopsIsKnown() {
        let seen = [
            ("Mystery, Thriller & Suspense", "Mystery", ["Modern Detectives"]),
            ("Mystery, Thriller & Suspense", "Thriller & Suspense", ["Espionage", "Political"]),
        ]
        for (top, second, names) in AudibleNames.deeper + seen {
            for name in names {
                #expect(GenreTable.row(name, under: top) != nil, "\(top) > \(second) > \(name)")
                // In a path it never becomes a genre of the owner's own.
                let mapped = GenreMapping.map(.paths([[top, second, name]]))
                #expect(mapped.builtIn.count == 1 && mapped.unknown.isEmpty, "\(top) > \(second) > \(name)")
                // Nor in a tag, where it may say nothing by itself.
                #expect(GenreMapping.map(.text(name)).unknown.isEmpty, "\(name) as text")
            }
        }
    }

    @Test func G5_aNameThatMeansTwoThingsHasAPlainEntry() {
        #expect(GenreTable.index.conflicts == [])
        #expect(GenreTable.index.duplicates == [])
    }

    @Test func G5_theMappingKnowsTheListsOwnNames() {
        for genre in BuiltInGenre.all {
            #expect(genres(genre.name) == [genre.name])
            #expect(genres(genre.name.uppercased()) == [genre.name])
        }
    }

    @Test func G5_aTagOfTheListsOwnNamesReadsBackAsWritten() {
        let lists = [
            ["Literary & General", "Crime & Mystery"],
            ["History", "Thrillers & Spies", "Reference & Learning"],
            ["Politics & Society", "Technology", "History"],
            ["Young Adult", "Fantasy", "Romance", "Humour", "Children"],
        ]
        for names in lists {
            #expect(genres(names.joined(separator: "; ")) == names)
            #expect(genres(names.joined(separator: ";")) == names)
        }
        #expect(genres("History; history; Fantasy") == ["History", "Fantasy"])
    }

    // MARK: G6 Reading text

    @Test func G6_aKnownNameWithACommaIsOneName() {
        let name = "Mystery, Thriller & Suspense"
        // At the start, in the middle and at the end.
        #expect(genres("\(name), Horror") == ["Thrillers & Spies", "Horror"])
        #expect(genres("Horror, \(name), Romance") == ["Horror", "Thrillers & Spies", "Romance"])
        #expect(genres("Horror, \(name)") == ["Horror", "Thrillers & Spies"])
        #expect(GenreMapping.map(.text("Horror, \(name), Romance")).unknown == [])
    }

    @Test func G6_otherNamesWithCommasStayWhole() {
        #expect(genres("Relationships, Parenting & Personal Development") == ["Self-Development"])
        #expect(genres("Horror, Fairy Tales, Folk Tales & Myths") == ["Horror", "Children"])
        #expect(genres("Ancient, Classical & Medieval Literature, Horror") == ["Classics", "Horror"])
        #expect(genres("Australia, New Zealand & Oceania") == ["History"])
        #expect(genres("Con Artists, Hoaxes & Deceptions") == ["True Crime"])
    }

    @Test func G6_theLongestKnownNameIsMatchedFirst() {
        // "Ancient, Classical & Medieval Literature" and not "Ancient" then the rest.
        let mapped = GenreMapping.map(.text("Ancient, Classical & Medieval Literature"))
        #expect(mapped.builtIn == ["Classics"])
        #expect(mapped.unknown == [])
        // "Mystery" twice over: once inside the long name, once alone.
        #expect(genres("Mystery, Mystery, Thriller & Suspense, Horror") == ["Crime & Mystery", "Horror"])
    }

    @Test func G6_textIsSplitAtSemicolonsSlashesAndCommas() {
        #expect(genres("Horror; Romance") == ["Horror", "Romance"])
        #expect(genres("Horror/Romance") == ["Horror", "Romance"])
        #expect(genres("Horror / Romance // Fantasy") == ["Horror", "Romance", "Fantasy"])
        #expect(genres("Horror, Romance") == ["Horror", "Romance"])
        #expect(genres(" ;; Horror ; , ") == ["Horror"])
    }

    @Test func G6_aKnownNameIsNotJoinedAcrossASemicolon() {
        // The comma inside the name is not a semicolon.
        let mapped = GenreMapping.map(.text("Mystery; Thriller & Suspense"))
        #expect(mapped.names == ["Crime & Mystery", "Thrillers & Spies"])
    }

    @Test func G6_GP2_aKnownWordingWithASlashIsOnePiece() {
        let mapped = GenreMapping.map(.text("Mystery/Thriller"))
        #expect(mapped.builtIn == ["Thrillers & Spies"])
        #expect(mapped.unknown == [])
        #expect(genres("Horror; Mystery/Thriller; Romance") == ["Horror", "Thrillers & Spies", "Romance"])
        #expect(genres("Horror/Mystery / Thriller") == ["Horror", "Thrillers & Spies"])
    }

    // MARK: G7 General and specific

    @Test func G7_aSpecificNameWinsOverTheGeneralOneItSitsUnder() {
        #expect(genres("Mystery, Thriller & Suspense, Espionage") == ["Thrillers & Spies"])
        #expect(genres("Mystery, Thriller & Suspense, Mystery") == ["Crime & Mystery"])
        #expect(genres("Mystery, Thriller & Suspense; Cozy") == ["Crime & Mystery"])
        #expect(genres("Science Fiction & Fantasy, Fantasy") == ["Fantasy"])
        #expect(genres(paths: [["Mystery, Thriller & Suspense"], ["Mystery, Thriller & Suspense", "Mystery"]])
            == ["Crime & Mystery"])
        #expect(genres(paths: [["Comedy & Humor", "Biographies & Memoirs"], ["Comedy & Humor"]])
            == ["Biography & Memoir"])
    }

    @Test func G7_aGeneralNameAloneGivesItsGenre() {
        #expect(genres("Mystery, Thriller & Suspense") == ["Thrillers & Spies"])
        #expect(genres("Literature & Fiction") == ["Literary & General"])
        #expect(genres("Fiction") == ["Literary & General"])
        #expect(genres("Education & Learning") == ["Reference & Learning"])
        #expect(genres(paths: [["Literature & Fiction", "Genre Fiction", "War & Military"]]) == ["Literary & General"])
    }

    @Test func G7_aNameUnderAnotherTopDoesNotSetThatTopAside() {
        // "Fantasy" here is the genre, not the kind of romance.
        #expect(genres("Romance, Fantasy") == ["Romance", "Fantasy"])
        #expect(genres("Romance; Science Fiction") == ["Romance", "Science Fiction"])
    }

    @Test func G7_aGeneralGenreIsDroppedBesideOthers() {
        #expect(genres("Fiction, Horror") == ["Horror"])
        #expect(genres("Horror; Literature & Fiction") == ["Horror"])
        #expect(genres("Reference & Learning, History") == ["History"])
        #expect(genres(paths: [
            ["Literature & Fiction", "Genre Fiction", "War & Military"],
            ["Mystery, Thriller & Suspense", "Thriller & Suspense", "Spies & Politics", "Espionage"],
        ]) == ["Thrillers & Spies"])
        #expect(GenreMapping.map(.subjects(["Fiction", "Spy stories"])).names == ["Thrillers & Spies"])
    }

    @Test func G7_generalGenresWithNothingElseAreKept() {
        #expect(genres("Fiction, Education & Learning") == ["Literary & General", "Reference & Learning"])
        // A genre of the owner's own does not set a general one aside.
        #expect(genres("Fiction, Steampunk Opera") == ["Literary & General", "Steampunk Opera"])
    }

    // MARK: G8 Wording that says nothing

    @Test(arguments: [
        "Audiobook", "Audiobooks", "Audio Book", "Book", "Books", "Ebook", "Podcast", "Unknown", "Other", "Misc",
        "General", "Unabridged", "Abridged", "Non-Fiction", "Nonfiction",
    ])
    func G8_aWordThatSaysNothingIsDropped(word: String) {
        for text in [word, word.uppercased(), "  \(word.lowercased()) "] {
            let mapped = GenreMapping.map(.text(text))
            #expect(mapped.builtIn == [] && mapped.unknown == [], "\(text)")
        }
        #expect(genres("\(word), Horror") == ["Horror"])
        #expect(genres("Horror; \(word)") == ["Horror"])
        #expect(GenreMapping.map(.paths([[word]])).names == [])
    }

    @Test func G8_numbersAreReadAsID3GenresAndThenJudged() {
        // 12 is "Other", which says nothing.
        #expect(genres("(12)") == [])
        #expect(genres("12") == [])
        #expect(genres("( 12 )") == [])
        // 183 is "Audiobook", 186 "Podcast".
        #expect(genres("(183)") == [])
        #expect(genres("186") == [])
        // 57 is "Comedy", 100 "Humour": known names.
        #expect(genres("(57)") == ["Humour"])
        #expect(genres("100") == ["Humour"])
        // 17 is "Rock": not known, so the owner's own.
        #expect(GenreMapping.map(.text("(17)")).unknown == ["Rock"])
        #expect(GenreMapping.map(.text("17; Horror")).names == ["Horror", "Rock"])
        // 62 is "Pop/Funk": a name cannot hold a slash.
        #expect(GenreMapping.map(.text("62")).unknown == ["Pop", "Funk"])
    }

    @Test func G8_aNumberThatIsNoID3GenreIsDropped() {
        #expect(genres("2024") == [])
        #expect(genres("(999)") == [])
        #expect(genres("Horror, 2024") == ["Horror"])
        // A number in a name is part of the name.
        #expect(genres("20th Century Boys") == ["20th Century Boys"])
    }

    // MARK: G9 Wording the mapping does not know

    @Test func G9_unknownWordingBecomesAGenreOfTheOwnersOwn() {
        let mapped = GenreMapping.map(.text("  LitRPG ;  Grimdark   Western  , Horror"))
        #expect(mapped.builtIn == ["Horror"])
        #expect(mapped.unknown == ["LitRPG", "Grimdark Western"])
        #expect(mapped.names == ["Horror", "LitRPG", "Grimdark Western"])
    }

    @Test func G9_unknownWordingIsOtherwiseUnchanged() {
        #expect(GenreMapping.map(.text("litRPG & Co’s")).unknown == ["litRPG & Co’s"])
        // The same wording twice is one genre, as first written.
        #expect(GenreMapping.map(.text("LitRPG, litrpg; LITRPG")).unknown == ["LitRPG"])
    }

    @Test func G9_everyUnknownNameIsAValidName() {
        for source: GenreSource in [
            .text("A / B; C, D"), .paths([["Strange, New & Odd", "Deeper/Still"]]), .text("(62)"),
        ] {
            let mapped = GenreMapping.map(source)
            #expect(!mapped.unknown.isEmpty)
            for name in mapped.unknown { #expect(GenreName.valid(name) == name) }
        }
    }

    @Test func G9_anUnknownSubjectIsDropped() {
        let mapped = GenreMapping.map(.subjects([
            "Large type books", "Spy stories", "New York Times reviewed", "Fiction, espionage", "PR6058.E64",
        ]))
        #expect(mapped.builtIn == ["Thrillers & Spies"])
        #expect(mapped.unknown == [])
        #expect(GenreMapping.map(.subjects(["Large type books"])).names == [])
    }

    @Test func G9_subjectsGoThroughTheSameTable() {
        #expect(GenreMapping.map(.subjects(["Science fiction", "Finance"])).names
            == ["Science Fiction", "Money & Investing"])
        #expect(GenreMapping.map(.subjects(["Detective and mystery stories", "Fiction, general"])).names
            == ["Crime & Mystery"])
    }

    // MARK: G10 The same every time

    @Test func G10_theOrderOfThePiecesDoesNotChangeWhichGenresAreFound() {
        let pieces = ["Mystery, Thriller & Suspense", "Espionage", "Fiction", "Cozy", "LitRPG"]
        let expected: Set<String> = ["Thrillers & Spies", "Crime & Mystery", "LitRPG"]
        var orders = 0
        for order in permutations(pieces) {
            for separator in ["; ", "/", ", "] {
                let found = genres(order.joined(separator: separator))
                #expect(Set(found) == expected, "\(order)")
                #expect(found.count == expected.count)
            }
            orders += 1
        }
        #expect(orders == 120)
    }

    @Test func G10_theOrderOfThePathsDoesNotChangeWhichGenresAreFound() {
        let paths = [
            ["Computers & Technology", "Computer Science"],
            ["History", "Military", "Military Science"],
            ["Politics & Social Sciences", "Politics & Government", "International Relations", "Arms Control"],
            ["Literature & Fiction"],
        ]
        for order in permutations(paths) {
            #expect(Set(genres(paths: order)) == ["Politics & Society", "Technology", "History"])
            // The most specific is first whatever the order.
            #expect(genres(paths: order).first == "Politics & Society")
        }
    }

    @Test func G10_theSameTextGivesTheSameGenresWhateverWasMappedBefore() {
        let texts = GP4.map(\.text) + ["LitRPG", "(17)", "Fiction, Horror", "Sci-Fi/Fantasy"]
        let first = texts.map { GenreMapping.map(.text($0)) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let order = texts.indices.shuffled(using: &generator)
            for index in order {
                #expect(GenreMapping.map(.text(texts[index])) == first[index])
            }
        }
    }

    // MARK: G11 Order and number

    @Test func G11_theMostSpecificIsFirstThenTheSourcesOrder() {
        // "Espionage" is four levels down, the others three.
        #expect(genres("International Mystery & Crime, Espionage") == ["Thrillers & Spies", "Crime & Mystery"])
        #expect(genres("Espionage, International Mystery & Crime") == ["Thrillers & Spies", "Crime & Mystery"])
        // The same depth: as the source gave them.
        #expect(genres("Horror, Romance, History") == ["Horror", "Romance", "History"])
        #expect(genres("History, Romance, Horror") == ["History", "Romance", "Horror"])
        #expect(genres(paths: [
            ["Romance", "Paranormal"],
            ["Science Fiction & Fantasy", "Fantasy", "Epic"],
            ["History", "Europe"],
        ]) == ["Fantasy", "Romance", "History"])
    }

    @Test func G11_genresOfTheOwnersOwnComeAfterTheBuiltIn() {
        #expect(genres("LitRPG, Horror, Grimdark, Romance") == ["Horror", "Romance", "LitRPG", "Grimdark"])
    }

    @Test func G11_aGenreIsGivenOnce() {
        #expect(genres("Thriller, Suspense, Espionage, Spy stories") == ["Thrillers & Spies"])
    }

    @Test func G11_atMostFiveAreKept() {
        let mapped = GenreMapping.map(.text("Horror, Romance, History, Travel, Fantasy, Classics, LitRPG"))
        #expect(mapped.names == ["Horror", "Romance", "History", "Travel & Places", "Fantasy"])
        #expect(mapped.builtIn.count + mapped.unknown.count == 5)

        let mixed = GenreMapping.map(.text("A1x, B1x, Horror, C1x, D1x, E1x, F1x"))
        #expect(mixed.names == ["Horror", "A1x", "B1x", "C1x", "D1x"])
        #expect(mixed.builtIn == ["Horror"])
        #expect(mixed.unknown == ["A1x", "B1x", "C1x", "D1x"])

        let subjects = GenreMapping.map(.subjects([
            "Horror", "Romance", "History", "Travel", "Fantasy", "Classics", "Humor",
        ]))
        #expect(subjects.names.count == 5)
    }

    // MARK: GP1 Paths

    @Test func GP1_theDeepestKnownNameDecides() {
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage")])
            == ["Thrillers & Spies"])
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > Mystery > Cozy")]) == ["Crime & Mystery"])
        // A name the table does not know is passed over for the one above it.
        #expect(genres(paths: [path("History > Military > Military Science")]) == ["History"])
        #expect(genres(paths: [path("Science Fiction & Fantasy > Fantasy > Never Heard Of It")]) == ["Fantasy"])
        #expect(GenreMapping.map(.paths([path("History > Never Heard Of It")])).unknown == [])
    }

    @Test func GP1_onePathGivesOneGenre() {
        for (top, names) in AudibleNames.secondLevel {
            for name in names {
                #expect(GenreMapping.map(.paths([[top, name]])).names.count == 1)
            }
        }
        for (top, second, names) in AudibleNames.deeper {
            for name in names {
                #expect(GenreMapping.map(.paths([[top, second, name]])).names.count == 1)
            }
        }
    }

    @Test func GP1_theTopNameDecidesWhatASharedNameMeans() {
        #expect(genres(paths: [path("Children's Audiobooks > History")]) == ["Children"])
        #expect(genres(paths: [path("Children's Audiobooks > Action & Adventure > Fantasy")]) == ["Children"])
        #expect(genres(paths: [path("Teen & Young Adult > Romance > Paranormal")]) == ["Young Adult"])
        #expect(genres(paths: [path("Comedy & Humor > Biographies & Memoirs")]) == ["Biography & Memoir"])
        #expect(genres(paths: [path("History > Military")]) == ["History"])
        #expect(genres(paths: [path("History > Ancient > Military")]) == ["History"])
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > Thriller & Suspense > Military")])
            == ["Thrillers & Spies"])
        #expect(genres(paths: [path("Science Fiction & Fantasy > Fantasy > Military")]) == ["Fantasy"])
        #expect(genres(paths: [path("Science Fiction & Fantasy > Science Fiction > Military")]) == ["Science Fiction"])
        #expect(genres(paths: [path("Biographies & Memoirs > Professionals & Academics > Business")])
            == ["Biography & Memoir"])
        #expect(genres(paths: [path("Religion & Spirituality > Christianity > History")]) == ["Philosophy & Religion"])
    }

    @Test func GP1_aNameThatOnlyNarrowsLeavesTheOneAboveToDecide() {
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > Mystery > Historical")]) == ["Crime & Mystery"])
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > Thriller & Suspense > Action & Adventure")])
            == ["Thrillers & Spies"])
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > Crime Fiction > Thrillers")]) == ["Crime & Mystery"])
        #expect(genres(paths: [path("Science Fiction & Fantasy > Science Fiction > Anthologies & Short Stories")])
            == ["Science Fiction"])
    }

    @Test func GP1_someNamesCoverEverythingBeneathThem() {
        #expect(genres(paths: [path("Mystery, Thriller & Suspense > True Crime > Espionage")]) == ["True Crime"])
        #expect(genres(paths: [path("Biographies & Memoirs > True Crime > Espionage")]) == ["True Crime"])
        #expect(genres(paths: [path("Literature & Fiction > Horror > Anthologies & Short Stories")]) == ["Horror"])
        #expect(genres(paths: [path("Literature & Fiction > Anthologies & Short Stories > Horror")]) == ["Horror"])
        #expect(genres(paths: [path("Literature & Fiction > Historical Fiction > Mystery")]) == ["Historical Fiction"])
        #expect(genres(paths: [path("Literature & Fiction > Ancient, Classical & Medieval Literature > Poetry")])
            == ["Classics"])
        #expect(genres(paths: [path("Literature & Fiction > Erotica > LGBTQ+")]) == ["Romance"])
    }

    @Test func GP1_aPathWithNoKnownNameGivesItsDeepestNameAsTheOwnersOwn() {
        let mapped = GenreMapping.map(.paths([["Strange  Things", " Stranger  Still "]]))
        #expect(mapped.builtIn == [])
        #expect(mapped.unknown == ["Stranger Still"])
        #expect(GenreMapping.map(.paths([[], ["", " "]])).names == [])
    }

    @Test func GP1_aPathUnderAnUnknownTopIsReadByItsPlainNames() {
        #expect(genres(paths: [["Strange Things", "Science Fiction", "Odd"]]) == ["Science Fiction"])
    }

    @Test func GP1_aRootAboveTheTopNameIsPassedOver() {
        #expect(genres(paths: [["Genres", "History", "Military"]]) == ["History"])
        #expect(genres(paths: [["Genres", "Children's Audiobooks", "History"]]) == ["Children"])
    }

    // MARK: GP2 Plain wordings

    @Test(arguments: [
        ("Sci-Fi", "Science Fiction"), ("SciFi", "Science Fiction"), ("SF", "Science Fiction"),
        ("Science-Fiction", "Science Fiction"), ("Science fiction", "Science Fiction"),
        ("Fantasy fiction", "Fantasy"), ("Fantasy", "Fantasy"),
        ("Mystery/Thriller", "Thrillers & Spies"), ("Thriller", "Thrillers & Spies"),
        ("Thrillers", "Thrillers & Spies"), ("Suspense", "Thrillers & Spies"), ("Spy", "Thrillers & Spies"),
        ("Spy stories", "Thrillers & Spies"), ("Espionage", "Thrillers & Spies"),
        ("Detective and mystery stories", "Crime & Mystery"), ("Crime", "Crime & Mystery"),
        ("Mystery", "Crime & Mystery"),
        ("Biography", "Biography & Memoir"), ("Autobiography", "Biography & Memoir"),
        ("Memoir", "Biography & Memoir"),
        ("Fiction", "Literary & General"), ("Poetry", "Literary & General"),
        ("Business", "Business & Careers"), ("Economics", "Money & Investing"), ("Finance", "Money & Investing"),
        ("Investments", "Money & Investing"),
        ("Self-Help", "Self-Development"), ("Self Help", "Self-Development"),
        ("Psychology", "Health & Mind"), ("Health", "Health & Mind"),
        ("Philosophy", "Philosophy & Religion"), ("Religion", "Philosophy & Religion"),
        ("Science", "Science & Nature"), ("History", "History"), ("Politics", "Politics & Society"),
        ("Travel", "Travel & Places"), ("Sports", "Sports & Outdoors"),
        ("Humor", "Humour"), ("Humour", "Humour"), ("Comedy", "Humour"),
        ("Horror", "Horror"), ("Romance", "Romance"), ("Classics", "Classics"),
        ("Young Adult", "Young Adult"), ("YA", "Young Adult"),
        ("Kids", "Children"), ("Children's", "Children"), ("Juvenile fiction", "Children"),
        ("True Crime", "True Crime"), ("Technology", "Technology"), ("Computers", "Technology"),
    ])
    func GP2_aPlainWordingIsKnown(wording: String, genre: String) {
        let mapped = GenreMapping.map(.text(wording))
        #expect(mapped.builtIn == [genre])
        #expect(mapped.unknown == [])
        #expect(GenreMapping.map(.subjects([wording])).names == [genre])
    }

    @Test func GP2_nonFictionSaysNothing() {
        #expect(genres("Non-Fiction") == [])
        #expect(genres("Nonfiction; History") == ["History"])
    }

    // MARK: GP3 Matching

    @Test func GP3_matchingIgnoresCaseAndSpaces() {
        #expect(genres("mystery, thriller & suspense") == ["Thrillers & Spies"])
        #expect(genres("  MYSTERY,THRILLER  &   SUSPENSE ") == ["Thrillers & Spies"])
        #expect(genres("sci-fi") == ["Science Fiction"])
        #expect(genres(paths: [[" history ", "MILITARY"]]) == ["History"])
    }

    @Test func GP3_matchingTakesAndForAmpersand() {
        #expect(genres("Mystery, Thriller and Suspense") == ["Thrillers & Spies"])
        #expect(genres("Politics and Social Sciences") == ["Politics & Society"])
        #expect(genres("Detective & mystery stories") == ["Crime & Mystery"])
        #expect(genres("Science Fiction&Fantasy") == ["Science Fiction"])
    }

    @Test func GP3_matchingTakesEitherApostrophe() {
        #expect(genres("Children's Audiobooks") == ["Children"])
        #expect(genres("Children’s Audiobooks") == ["Children"])
        #expect(genres("Children’s") == ["Children"])
        #expect(genres(paths: [["Literature & Fiction", "Women’s Fiction"]]) == ["Literary & General"])
    }

    // MARK: GP4 The owner's eleven values

    static let GP4: [(text: String, genres: [String])] = [
        ("Audiobook", []),
        ("Mystery, Thriller & Suspense", ["Thrillers & Spies"]),
        ("International Mystery & Crime, Espionage, Traditional Detectives", ["Thrillers & Spies", "Crime & Mystery"]),
        ("War & Military, Military, Political, Suspense", ["Thrillers & Spies"]),
        ("Suspense, Crime Thrillers, Modern Detectives, Espionage, Political", ["Thrillers & Spies", "Crime & Mystery"]),
        ("Politics & Social Sciences", ["Politics & Society"]),
        ("Mystery, Thriller & Suspense, Mystery", ["Crime & Mystery"]),
        ("Money & Finance, Investing & Trading", ["Money & Investing"]),
        ("Literature & Fiction", ["Literary & General"]),
        ("International Mystery & Crime, Espionage", ["Thrillers & Spies", "Crime & Mystery"]),
        ("", []),
    ]
    private var GP4: [(text: String, genres: [String])] { Self.GP4 }

    @Test func GP4_theOwnersElevenValues() {
        #expect(GP4.count == 11)
        for (text, expected) in GP4 {
            let mapped = GenreMapping.map(.text(text))
            #expect(mapped.builtIn == expected, "\(text)")
            #expect(mapped.unknown == [], "\(text)")
        }
    }

    // MARK: GP5 The owner's seven titles

    @Test func GP5_theOwnersSevenTitles() {
        let titles: [(title: String, paths: [String], genres: [String])] = [
            ("Without Remorse", [
                "Literature & Fiction > Action & Adventure > Mystery, Thriller & Suspense > Thriller & Suspense",
                "Literature & Fiction > Action & Adventure > War & Military",
                "Literature & Fiction > Genre Fiction > War & Military",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Suspense",
            ], ["Thrillers & Spies"]),
            ("The Sum of All Fears", [
                "Literature & Fiction > Action & Adventure > War & Military",
                "Literature & Fiction > Genre Fiction > Political",
                "Literature & Fiction > Genre Fiction > War & Military",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage",
            ], ["Thrillers & Spies"]),
            ("Bad Actors", [
                "Mystery, Thriller & Suspense > Mystery > International Mystery & Crime",
                "Mystery, Thriller & Suspense > Mystery > Traditional Detectives",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage",
            ], ["Thrillers & Spies", "Crime & Mystery"]),
            ("Slow Horses", [
                "Mystery, Thriller & Suspense > Thriller & Suspense > Crime Thrillers",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Political",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Suspense",
            ], ["Thrillers & Spies", "Crime & Mystery"]),
            ("Tom Clancy Defense Protocol", [
                "Literature & Fiction > Genre Fiction > War & Military",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Military",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Political",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Suspense",
            ], ["Thrillers & Spies"]),
            ("Clown Town", [
                "Mystery, Thriller & Suspense > Mystery",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Crime Thrillers",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Political",
                "Mystery, Thriller & Suspense > Thriller & Suspense > Suspense",
            ], ["Thrillers & Spies", "Crime & Mystery"]),
            ("Project Maven", [
                "Computers & Technology > Computer Science",
                "History > Military > Military Science",
                "Politics & Social Sciences > Politics & Government > Freedom & Security > National & International Security",
                "Politics & Social Sciences > Politics & Government > International Relations > Arms Control",
            ], ["Politics & Society", "Technology", "History"]),
        ]
        #expect(titles.count == 7)
        for (title, paths, expected) in titles {
            let mapped = GenreMapping.map(.paths(paths.map(path)))
            #expect(mapped.builtIn == expected, "\(title)")
            #expect(mapped.unknown == [], "\(title)")
        }
    }

    // MARK: G4 The wording kept

    @Test func G4_theWordingOfASource() {
        #expect(GenreMapping.wording(of: .text("Mystery, Thriller & Suspense")) == "Mystery, Thriller & Suspense")
        #expect(GenreMapping.wording(of: .text("  Audiobook ")) == "Audiobook")
        #expect(GenreMapping.wording(of: .text("  ")) == nil)
        #expect(GenreMapping.wording(of: .paths([["History", "Military"], [], ["Romance"]]))
            == "History > Military; Romance")
        #expect(GenreMapping.wording(of: .paths([])) == nil)
        #expect(GenreMapping.wording(of: .paths([[" "]])) == nil)
        #expect(GenreMapping.wording(of: .subjects(["Spy stories", " ", "Fiction"])) == "Spy stories; Fiction")
        #expect(GenreMapping.wording(of: .subjects([])) == nil)
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var all: [[T]] = []
        for index in items.indices {
            var rest = items
            let item = rest.remove(at: index)
            all += permutations(rest).map { [item] + $0 }
        }
        return all
    }
}

/// Audible's category names as they stood on 2026-11-24: every top name with the names
/// directly beneath it, and the third level of the three fiction tops.
enum AudibleNames {
    static let secondLevel: [(top: String, names: [String])] = [
        ("Arts & Entertainment", [
            "Architecture", "Art", "Audio Performances & Dramatizations", "Entertainment & Performing Arts",
            "Music", "Photography",
        ]),
        ("Biographies & Memoirs", [
            "Adventurers, Explorers & Survival", "Art & Literature", "Cultural & Regional",
            "Diaries & Correspondence", "Entertainment & Celebrities", "Historical", "LGBTQ+", "Military & War",
            "People with Disabilities", "Politics & Activism", "Professionals & Academics", "Religious",
            "Sports", "True Crime", "Women",
        ]),
        ("Business & Careers", [
            "Business Development & Entrepreneurship", "Career Success", "Management & Leadership",
            "Marketing & Sales", "Women in Business", "Workplace & Organizational Behavior",
        ]),
        ("Children's Audiobooks", [
            "Action & Adventure", "Activities & Hobbies", "Animals & Nature", "Art", "Biographies",
            "Education & Learning", "Fairy Tales, Folk Tales & Myths", "Geography & Cultures",
            "Growing Up & Facts of Life", "History", "Holidays & Celebrations", "Humor", "Literature & Fiction",
            "Music & Performing Arts", "Mystery & Suspense", "Religions", "Science & Technology",
            "Science Fiction & Fantasy", "Sports & Outdoors", "Vehicles & Transportation",
        ]),
        ("Comedy & Humor", [
            "Biographies & Memoirs", "Literature & Fiction", "Performing Arts",
        ]),
        ("Computers & Technology", [
            "Computer Science", "Content Creation & Social Media", "Data Science", "History & Culture",
            "Programming & Software Development", "Security & Encryption",
        ]),
        ("Education & Learning", [
            "Education", "Language Learning", "Study Guides & Test Preparation", "Words, Language & Grammar",
            "Writing & Publishing",
        ]),
        ("Erotica", [
            "Literature & Fiction", "Sex Instruction",
        ]),
        ("Health & Wellness", [
            "Addiction & Recovery", "Aging & Longevity", "Alternative & Complementary Medicine",
            "Beauty, Grooming & Style", "Children's Health", "Dentistry & Oral Health",
            "Fitness, Diet & Nutrition", "Hygiene & Healthy Living", "Medicine & Health Care Industry",
            "Physical Illness & Disease", "Psychology & Mental Health", "Safety & Emergency Preparedness",
            "Sexual & Reproductive Health",
        ]),
        ("History", [
            "Africa", "Americas", "Ancient", "Arctic & Antarctica", "Asia", "Australia, New Zealand & Oceania",
            "Europe", "LGBTQ+", "Middle East", "Military", "Modern", "Religious", "Russia", "Women", "World",
        ]),
        ("Home & Garden", [
            "Crafts & Hobbies", "Food & Wine", "Gardening & Horticulture", "House & Home", "Pets & Animal Care",
            "Sustainable & Green Living",
        ]),
        ("LGBTQ+", [
            "Biographies & Memoirs", "History", "LGBTQ+ Studies", "Literature & Fiction",
            "Mystery, Thriller & Suspense", "Parenting & Families", "Romance", "Science Fiction & Fantasy",
        ]),
        ("Literature & Fiction", [
            "Action & Adventure", "African American", "Ancient, Classical & Medieval Literature",
            "Anthologies & Short Stories", "Classics", "Drama & Plays", "Erotica", "Essays", "Genre Fiction",
            "Historical Fiction", "Horror", "Humor & Satire", "LGBTQ+", "Literary History & Criticism",
            "Memoirs, Diaries & Correspondence", "Poetry", "Women's Fiction", "World Literature",
        ]),
        ("Money & Finance", [
            "Banks & Banking", "Corporate & Public Finance", "E-Commerce", "Economics", "Insurance",
            "International", "Investing & Trading", "Personal Finance", "Real Estate", "Taxation",
        ]),
        ("Mystery, Thriller & Suspense", [
            "Crime Fiction", "Mystery", "Thriller & Suspense", "True Crime",
        ]),
        ("Politics & Social Sciences", [
            "Anthropology", "Archaeology", "Law", "Philosophy", "Politics & Government", "Social Sciences",
            "Sociology",
        ]),
        ("Relationships, Parenting & Personal Development", [
            "Parenting & Families", "Personal Development", "Relationships",
        ]),
        ("Religion & Spirituality", [
            "Agnosticism", "Atheism", "Buddhism", "Christianity", "Hinduism", "Islam", "Judaism", "Occult",
            "Other Religions, Practices & Sacred Texts", "Religious Studies", "Spirituality",
        ]),
        ("Romance", [
            "Action & Adventure", "Anthologies & Short Stories", "Christian", "Clean & Wholesome",
            "Contemporary", "Erotica", "Fantasy", "Historical", "LGBTQ+", "Military", "Multicultural",
            "Paranormal", "Romantic Comedy", "Romantic Suspense", "Royalty", "Science Fiction", "Sports",
            "Westerns",
        ]),
        ("Science & Engineering", [
            "Engineering", "Mathematics", "Science",
        ]),
        ("Science Fiction & Fantasy", [
            "Fantasy", "Science Fiction",
        ]),
        ("Sports & Outdoors", [
            "Adventurers, Explorers & Survival", "Baseball & Softball", "Basketball", "Biographies & Memoirs",
            "Bodybuilding & Strength Training", "Coaching", "Combat Sports & Self-Defense", "Cricket",
            "Cycling", "Equestrian Sports", "Extreme Sports", "Football", "Golf", "Hockey", "Motor Sports",
            "Olympics & Paralympics", "Outdoors & Nature", "Rugby", "Running & Jogging", "Soccer",
            "Sociology of Sports", "Sports History", "Sports Psychology", "Sports Writing", "Tennis",
            "Track & Field", "Triathlon", "Volleyball", "Walking", "Water Sports", "Winter Sports", "Workouts",
        ]),
        ("Teen & Young Adult", [
            "Arts & Entertainment", "Biographies", "Education & Learning", "Health, Lifestyle & Relationships",
            "History & Culture", "LGBTQ+", "Literature & Fiction", "Mystery, Thriller & Suspense",
            "Politics, Society & Current Events", "Religion & Spirituality", "Romance", "Science & Technology",
            "Science Fiction & Fantasy", "Sports & Outdoors",
        ]),
        ("Travel & Tourism", [
            "Adventure Travel", "Africa", "Asia", "Australia & Oceania", "Caribbean", "Central & South America",
            "Europe", "Guided Tours", "Middle East", "North America", "Polar Regions", "Russia",
            "Travel Writing & Commentary",
        ]),
    ]

    static let deeper: [(top: String, second: String, names: [String])] = [
        ("Literature & Fiction", "Action & Adventure", [
            "Anthologies & Short Stories", "Classics", "Fantasy", "Mystery, Thriller & Suspense", "Romance",
            "Science Fiction", "War & Military", "Women's Adventure",
        ]),
        ("Literature & Fiction", "Ancient, Classical & Medieval Literature", [
            "Collections", "Drama", "Poetry",
        ]),
        ("Literature & Fiction", "Anthologies & Short Stories", [
            "Action & Adventure", "Ancient, Classical & Medieval Literature", "Anthologies", "Christian",
            "Erotica", "Fantasy", "Historical Fiction", "Horror", "LGBTQ+", "Mystery", "Romance",
            "Science Fiction", "Short Stories", "Thriller & Suspense",
        ]),
        ("Literature & Fiction", "Drama & Plays", [
            "Ancient, Classical & Medieval", "Comedy", "Contemporary", "Historical", "Religious & Liturgical",
            "Shakespeare", "Tragedy", "Tragicomedy",
        ]),
        ("Literature & Fiction", "Erotica", [
            "Collections & Anthologies", "LGBTQ+", "Romantic", "Science Fiction & Fantasy",
        ]),
        ("Literature & Fiction", "Genre Fiction", [
            "Absurdist", "Alternate History", "Animals", "Biographical Fiction", "Christian Fiction",
            "City Life", "Coming of Age", "Contemporary Fiction", "Domestic Thrillers", "Dystopian",
            "Epistolary", "Family Life", "Friendship", "Holidays", "Literary Fiction", "Magical Realism",
            "Mash-Ups", "Medical", "Metaphysical & Visionary", "Movie, TV & Video Game Tie-Ins", "Political",
            "Psychological", "Sagas", "Satire", "Sea Adventures", "Small Town & Rural", "Sports", "Suburban",
            "Urban", "War & Military", "Westerns",
        ]),
        ("Literature & Fiction", "Historical Fiction", [
            "20th Century", "Ancient", "Anthologies & Short Stories", "Biographical", "Fantasy", "Medieval",
            "Mystery", "Renaissance", "Thrillers",
        ]),
        ("Literature & Fiction", "Horror", [
            "Anthologies & Short Stories", "Ghosts", "Gothic", "Occult",
        ]),
        ("Literature & Fiction", "Humor & Satire", [
            "Dark Humor", "Satire",
        ]),
        ("Literature & Fiction", "LGBTQ+", [
            "Anthologies & Short Stories", "Erotica", "Genre Fiction",
        ]),
        ("Literature & Fiction", "Poetry", [
            "Ancient, Classical & Medieval", "Collections & Anthologies", "Themes & Styles",
        ]),
        ("Literature & Fiction", "World Literature", [
            "Asian", "European", "Indigenous", "Jewish", "Middle Eastern", "Russian & Soviet", "United States",
        ]),
        ("Mystery, Thriller & Suspense", "Crime Fiction", [
            "Action & Adventure", "Noir", "Serial Killers", "Thrillers",
        ]),
        ("Mystery, Thriller & Suspense", "Mystery", [
            "Action & Adventure", "Amateur Sleuths", "Anthologies & Short Stories", "Cozy", "Dramatizations",
            "Hard-Boiled", "Historical", "International Mystery & Crime", "LGBTQ+", "Police Procedurals",
            "Private Investigators", "Traditional Detectives", "Women Sleuths",
        ]),
        ("Mystery, Thriller & Suspense", "Thriller & Suspense", [
            "Action & Adventure", "Anthologies & Short Stories", "Christian", "Crime Thrillers",
            "Domestic Thrillers", "Dramatizations", "Historical", "LGBTQ+", "Legal", "Medical & Forensic",
            "Military", "Psychological", "Romantic Suspense", "Spies & Politics", "Supernatural", "Suspense",
            "Technothrillers",
        ]),
        ("Mystery, Thriller & Suspense", "True Crime", [
            "Con Artists, Hoaxes & Deceptions", "Espionage", "Heists & Robberies", "Historical", "Murder",
            "Organized Crime", "Sexual Crimes & Assault",
        ]),
        ("Science Fiction & Fantasy", "Fantasy", [
            "Action & Adventure", "Alternate History", "Anthologies & Short Stories", "Christian",
            "Coming of Age", "Dragons & Mythical Creatures", "Dramatizations", "Epic", "Fairy Tales", "Gaslamp",
            "Historical", "Humorous", "LGBTQ+", "Military", "Movie, TV & Video Game Tie-Ins",
            "Paranormal & Urban", "Romantic", "Superhero", "Sword & Sorcery",
        ]),
        ("Science Fiction & Fantasy", "Science Fiction", [
            "Adventure", "Alternate History", "Anthologies & Short Stories", "Christian", "Cyberpunk",
            "Dramatizations", "Dystopian", "First Contact", "Genetic Engineering", "Hard Science Fiction",
            "Humorous", "LGBTQ+", "Military", "Movie, TV & Video Game Tie-Ins", "Post-Apocalyptic", "Romantic",
            "Space Exploration", "Space Opera", "Steampunk", "Time Travel",
        ]),
    ]
}

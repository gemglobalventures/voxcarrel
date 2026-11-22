import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct LibraryOfCongressProviderTests {
    private static let query = LookupQuery(title: "A Perfect Spy", author: "John le Carré")

    // MARK: Hand-made answers

    /// An answer in the catalogue's own shape around `records`, each the inside of a `mods` element.
    private static func answer(_ records: [String]) -> Data {
        let wrapped = records.enumerated().map { index, record in
            """
            <zs:record><zs:recordSchema>mods</zs:recordSchema><zs:recordPacking>xml</zs:recordPacking><zs:recordData>\
            <mods xmlns="http://www.loc.gov/mods/v3" version="3.8">\(record)</mods>\
            </zs:recordData><zs:recordPosition>\(index + 1)</zs:recordPosition></zs:record>
            """
        }.joined()
        return Data("""
        <?xml version="1.0"?>
        <zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/"><zs:version>1.1</zs:version>\
        <zs:numberOfRecords>\(records.count)</zs:numberOfRecords><zs:records>\(wrapped)</zs:records>\
        </zs:searchRetrieveResponse>
        """.utf8)
    }

    /// The inside of a record for a sound recording called "The Book" by Ann Author, with `more` added.
    private static func record(
        _ more: String = "", id: String = "100", kind: String = "sound recording-nonmusical",
        title: String = "<titleInfo><title>The Book</title></titleInfo>",
        author: String = #"<name type="personal" usage="primary"><namePart>Author, Ann,</namePart></name>"#
    ) -> String {
        "\(title)\(author)<typeOfResource>\(kind)</typeOfResource>\(more)<recordInfo><recordIdentifier>\(id)</recordIdentifier></recordInfo>"
    }

    private static func search(_ records: [String], query: LookupQuery = LookupQuery(title: "The Book")) async throws -> [LookupCandidate] {
        try await LibraryOfCongressProvider(http: FakeHTTP(data: answer(records))).search(query)
    }

    private static func one(_ more: String) async throws -> LookupCandidate {
        let found = try await search([record(more)])
        #expect(found.count == 1)
        return try #require(found.first)
    }

    // MARK: C1 the request

    @Test func C1_titleAndAuthorRequest() async throws {
        let http = FakeHTTP(data: fixture("loc-perfectspy", type: "xml"))
        let provider = LibraryOfCongressProvider(http: http)
        #expect(provider.source == .libraryOfCongress)
        _ = try await provider.search(LookupQuery(
            title: " A Perfect Spy ", author: "John le Carré", isbn: "9780394551418", asin: "B004WPQ4BI", narrator: "Frank Muller"))
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        // The catalogue's one working address: plain http on port 210.
        #expect(url.absoluteString.hasPrefix("http://lx2.loc.gov:210/lcdb?version=1.1&operation=searchRetrieve&maximumRecords=20&recordSchema=mods&query="))
        #expect(url.scheme == "http")
        #expect(url.host == "lx2.loc.gov")
        #expect(url.port == 210)
        #expect(url.path == "/lcdb")
        #expect(url.user == nil)
        #expect(url.fragment == nil)
        #expect(queryItems(url) == [
            "version": "1.1", "operation": "searchRetrieve", "maximumRecords": "20", "recordSchema": "mods",
            "query": #"bath.title="A Perfect Spy" and bath.author="carre""#,
        ])
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 5)
        // Nothing but what is searched for is sent: no narrator, no ASIN, no ISBN beside a title.
        #expect(!url.absoluteString.contains("Muller"))
        #expect(!url.absoluteString.contains("B004WPQ4BI"))
        #expect(!url.absoluteString.contains("9780394551418"))
    }

    @Test func C1_C9_headersLimitsAndRedirects() async throws {
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        _ = try await LibraryOfCongressProvider(http: http, limit: 7).search(Self.query)
        #expect(http.requests.map(\.headers) == [["User-Agent": "VoxCarrel/0.1 (https://voxcarrel.app)", "Accept": "application/xml"]])
        // C9: at most 5 MB; no redirect is followed; the one address named as the exception.
        #expect(http.limits == [
            FakeHTTP.Limits(
                maxBytes: 5 * 1024 * 1024, redirectHosts: [],
                insecure: [InsecureOrigin(scheme: "http", host: "lx2.loc.gov", port: 210)]),
        ])
        #expect(queryItems(try #require(http.urls.first))["maximumRecords"] == "7")
    }

    /// C1: the address the provider asks is one the network layer lets through, and
    /// only with the exception the provider names.
    @Test func C1_theAddressAskedIsTheNamedException() async throws {
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        _ = try await LibraryOfCongressProvider(http: http).search(Self.query)
        let url = try #require(http.urls.first)
        let limits = try #require(http.limits.first)
        #expect(URLSessionFetcher.mayRequest(url, insecure: limits.insecure))
        #expect(!URLSessionFetcher.mayRequest(url, insecure: []))
    }

    /// C1: a redirect of the catalogue's answer, to anywhere, fails the search as refused
    /// and is not followed.
    @Test(arguments: [
        ("/redirect-a", "https://www.loc.gov/final-a"), ("/redirect-b", "http://lx2.loc.gov:210/final-b"),
        ("/redirect-c", "https://lx2.loc.gov/final-c"),
    ])
    func C1_aRedirectIsNeverFollowed(path: String, to address: String) async throws {
        let target = try #require(URL(string: address))
        StubURLProtocol.set(.redirect(to: target), forPath: path)
        let fetcher = URLSessionFetcher(timeout: 60, protocolClasses: [StubURLProtocol.self])
        let from = try #require(URL(string: "http://lx2.loc.gov:210\(path)"))
        await #expect(throws: LookupError.refused(status: 302)) {
            _ = try await fetcher.get(
                from, headers: [:], maxBytes: 1000, redirectHosts: ["loc.gov", "lx2.loc.gov", "www.loc.gov"],
                insecure: [.libraryOfCongress])
        }
        #expect(StubURLProtocol.requests(forPath: path).count == 1)
        #expect(StubURLProtocol.requests(forPath: target.path).isEmpty)
    }

    @Test(arguments: [(0, "1"), (-3, "1"), (1, "1"), (100, "100"), (5000, "100")])
    func C1_theNumberAskedForIsKeptSensible(limit: Int, sent: String) async throws {
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        _ = try await LibraryOfCongressProvider(http: http, limit: limit).search(Self.query)
        #expect(queryItems(try #require(http.urls.first))["maximumRecords"] == sent)
    }

    @Test(arguments: [
        ("Debt of Honor", "", #"bath.title="Debt of Honor""#),
        ("Debt of Honor", "  ", #"bath.title="Debt of Honor""#),
        // A leading article stays: the catalogue finds the title with it.
        ("The Devil’s Alternative", "Frederick Forsyth", #"bath.title="The Devil’s Alternative" and bath.author="forsyth""#),
        ("An Instance of the Fingerpost", "Iain Pears", #"bath.title="An Instance of the Fingerpost" and bath.author="pears""#),
        ("A Perfect Spy", "John le Carré", #"bath.title="A Perfect Spy" and bath.author="carre""#),
        ("The", "x", #"bath.title="The" and bath.author="x""#),
        // Quotes and backslashes cannot end the value early.
        (#"The "Perfect" \Spy\"#, #"John "le" Carr\é"#, #"bath.title="The Perfect Spy" and bath.author="carre""#),
        (#"Spy" or bath.title="x"#, #"a" or dc.any="b"#, #"bath.title="Spy or bath.title=x" and bath.author="dc.any=b""#),
        ("Tom & Jerry: 100% #1 + more? /a=b", "A&B=C", #"bath.title="Tom & Jerry: 100% #1 + more? /a=b" and bath.author="a&b=c""#),
        ("Spy\nwith\u{0}  breaks\u{202E}", "", #"bath.title="Spy with breaks""#),
    ])
    func C1_theQuery(title: String, author: String, expected: String) async throws {
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        _ = try await LibraryOfCongressProvider(http: http).search(LookupQuery(title: title, author: author))
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(queryItems(url)["query"] == expected)
        #expect(url.host == "lx2.loc.gov")
        #expect(url.path == "/lcdb")
        #expect(url.fragment == nil)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 5)
        // The lookup's own encoder: nothing but unreserved characters and escapes in a value.
        let encoded = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(encoded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~,%=&".contains($0)) })
        #expect(encoded.filter { $0 == "&" }.count == 4)
    }

    /// The surname is taken to be the last word of the first author's name, in lower case
    /// and without accents. That is only part of a surname of several words ("le Carré",
    /// "García Márquez"); the catalogue is searched for the word, which it still holds.
    @Test(arguments: [
        ("John le Carré", "carre"),
        ("Le Carré, John", "carre"),
        ("Le Carre\u{301}, John, 1931-2020", "carre"),
        ("Tom Clancy", "clancy"),
        ("Gabriel García Márquez", "marquez"),
        ("Ursula K. Le Guin", "guin"),
        ("J. R. R. Tolkien", "tolkien"),
        ("Tolkien, J. R. R.", "tolkien"),
        ("Martin Luther King Jr.", "king"),
        ("Julian Rhind-Tutt", "rhind-tutt"),
        ("Flann O'Brien", "o'brien"),
        ("HOMER", "homer"),
        ("Søren Kierkegaard", "kierkegaard"),
    ])
    func C1_theAuthorsSurname(author: String, surname: String) async throws {
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        _ = try await LibraryOfCongressProvider(http: http).search(LookupQuery(title: "Spy", author: author))
        #expect(queryItems(try #require(http.urls.first))["query"] == #"bath.title="Spy" and bath.author="\#(surname)""#)
    }

    // MARK: C2

    @Test func C2_anISBNWithoutATitle() async throws {
        for isbn in ["9780394551418", "978-0-394-55141-8", " 9780394551418 "] {
            let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
            _ = try await LibraryOfCongressProvider(http: http).search(LookupQuery(author: "John le Carré", isbn: isbn))
            #expect(http.urls.count == 1)
            let url = try #require(http.urls.first)
            #expect(queryItems(url) == [
                "version": "1.1", "operation": "searchRetrieve", "maximumRecords": "20", "recordSchema": "mods",
                "query": "bath.isbn=9780394551418",
            ])
        }
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        _ = try await LibraryOfCongressProvider(http: http).search(LookupQuery(isbn: "034038784x"))
        #expect(queryItems(try #require(http.urls.first))["query"] == "bath.isbn=034038784X")
    }

    @Test(arguments: [
        LookupQuery(), LookupQuery(author: "John le Carré"), LookupQuery(asin: "B004WPQ4BI"),
        LookupQuery(title: "  ", author: "x"), LookupQuery(isbn: "12345"), LookupQuery(isbn: #"1" or bath.title="x"#),
        LookupQuery(title: #""\""#, narrator: "Frank Muller"), LookupQuery(narrator: "Frank Muller", wantsAudioEditions: true),
    ])
    func C2_neitherTitleNorISBNMakesNoRequest(query: LookupQuery) async throws {
        let http = FakeHTTP(data: fixture("loc-perfectspy", type: "xml"))
        #expect(try await LibraryOfCongressProvider(http: http).search(query).isEmpty)
        #expect(http.requests.isEmpty)
    }

    // MARK: C3 to C7 on the trial's answer

    /// Three records for the title, two of them print: the one sound recording is the
    /// 1987 cassette edition read by Frank Muller.
    @Test func C3_C4_C5_C6_C7_theCassetteEditionOfTheTrial() async throws {
        let found = try await LibraryOfCongressProvider(http: FakeHTTP(data: fixture("loc-perfectspy", type: "xml"))).search(Self.query)
        #expect(found.count == 1)
        let candidate = try #require(found.first)
        #expect(candidate.id == "libraryOfCongress:5615214")
        #expect(candidate.source == .libraryOfCongress)

        var expected = BookMetadata(title: "A perfect spy")
        expected.authors = ["John Le Carré"]
        expected.narrators = ["Frank Muller"]
        expected.year = 1987
        expected.publisher = "Recorded Books"
        expected.language = "en"
        expected.durationSeconds = 18 * 3600
        #expect(candidate.metadata == expected)
        // The accent is one character with its letter.
        #expect(candidate.metadata.authors.first?.unicodeScalars.contains("\u{301}") == false)

        #expect(candidate.edition == EditionFacts(format: .cassette, abridged: false, publisher: "Recorded Books", year: 1987, stores: []))
        // C6
        #expect(candidate.note == "Library of Congress · Cassette · Unabridged · 18h 0m · 1987")
        #expect(candidate.coverURL == nil)
        #expect(candidate.thumbnailURL == nil)
        #expect(candidate.hasMoreDetails == false)
        // C7: the cataloguer's note is not a description.
        #expect(candidate.metadata.summary == nil)
        #expect(candidate.metadata.isbn == nil)
    }

    @Test func C6_detailsAddNothingAndAskNothing() async throws {
        let http = FakeHTTP(data: fixture("loc-perfectspy", type: "xml"))
        let provider = LibraryOfCongressProvider(http: http)
        let candidate = try #require(try await provider.search(Self.query).first)
        #expect(try await provider.details(for: candidate) == candidate)
        #expect(http.urls.count == 1)
    }

    // MARK: C3

    @Test(arguments: [
        ("sound recording-nonmusical", true), ("sound recording", true), ("Sound Recording-Nonmusical", true),
        (" sound recording ", true),
        ("text", false), ("", false), ("moving image", false), ("notated music", false), ("a sound recording", false),
        // Music is not a book read aloud.
        ("sound recording-musical", false),
    ])
    func C3_onlySoundRecordingsAreUsed(kind: String, used: Bool) async throws {
        let found = try await Self.search([Self.record(kind: kind)])
        #expect(found.count == (used ? 1 : 0))
    }

    @Test func C3_aRecordThatDoesNotSayWhatItIsIsIgnored() async throws {
        let record = #"<titleInfo><title>The Book</title></titleInfo><recordInfo><recordIdentifier>1</recordIdentifier></recordInfo>"#
        #expect(try await Self.search([record]).isEmpty)
    }

    // MARK: C4 titles

    @Test(arguments: [
        (#"<titleInfo><nonSort xml:space="preserve">A  </nonSort><title>perfect spy</title></titleInfo>"#, "A perfect spy", nil),
        ("<titleInfo><nonSort>The</nonSort><title>devil's alternative</title></titleInfo>", "The devil's alternative", nil),
        ("<titleInfo><nonSort>L'</nonSort><title>étranger</title></titleInfo>", "L'étranger", nil),
        ("<titleInfo><title>Devil take the hindmost</title><subTitle>a history of speculation</subTitle></titleInfo>",
         "Devil take the hindmost", "a history of speculation"),
        ("<titleInfo><title>  Debt   of\n honor /</title><subTitle> </subTitle></titleInfo>", "Debt of honor", nil),
        // Another title of the same work does not replace its own.
        (#"<titleInfo type="alternative"><title>Other</title></titleInfo><titleInfo><title>Own</title></titleInfo>"#, "Own", nil),
        (#"<titleInfo><title>Own</title></titleInfo><titleInfo><title>Second</title></titleInfo>"#, "Own", nil),
        // A title that belongs to something else in the record.
        ("<relatedItem><titleInfo><title>Series</title></titleInfo></relatedItem><titleInfo><title>Own</title></titleInfo>", "Own", nil),
        ("<subject><titleInfo><title>About</title></titleInfo></subject><titleInfo><title>Own</title></titleInfo>", "Own", nil),
    ] as [(String, String, String?)])
    func C4_theTitle(xml: String, title: String, subtitle: String?) async throws {
        let found = try await Self.search([Self.record(title: xml)])
        #expect(found.count == 1)
        #expect(found.first?.metadata.title == title)
        #expect(found.first?.metadata.subtitle == subtitle)
    }

    // MARK: C4 people

    @Test func C4_authorsByRoleOrByBeingPrimary() async throws {
        let names = """
        <name type="personal" usage="primary"><namePart>Clancy, Tom,</namePart><namePart type="date">1947-2013</namePart></name>
        <name type="personal"><namePart>Writer, Second</namePart><role><roleTerm type="text">Author.</roleTerm></role></name>
        <name type="personal"><namePart>Coder, Third</namePart><role><roleTerm type="code" authority="marcrelator">aut</roleTerm></role></name>
        <name type="personal"><namePart>Clancy, Tom,</namePart><role><roleTerm type="text">author</roleTerm></role></name>
        <name type="personal"><namePart type="given">Given</namePart><namePart type="family">Family</namePart><namePart type="termsOfAddress">Sir</namePart><role><roleTerm>author</roleTerm></role></name>
        <name type="corporate"><namePart>Recorded Books, Inc.</namePart><role><roleTerm>author</roleTerm></role></name>
        <name type="personal"><namePart>Words, Turner of</namePart><role><roleTerm type="text">translator</roleTerm></role></name>
        <name type="personal"><namePart>MacDonald, John.</namePart></name>
        <subject><name type="personal"><namePart>About, Someone</namePart></name></subject>
        <relatedItem><name type="personal"><namePart>Elsewhere, Someone</namePart></name></relatedItem>
        """
        let found = try await Self.search([Self.record(author: names)])
        let metadata = try #require(found.first?.metadata)
        // The same person twice is one author.
        #expect(metadata.authors == ["Tom Clancy", "Second Writer", "Third Coder", "Given Family"])
        // No performers note: a person with no stated part in it who is not an author read it.
        #expect(metadata.narrators == ["John MacDonald"])
    }

    @Test func C4_aPersonNamedAsNarratorIsOne() async throws {
        let names = """
        <name type="personal"><namePart>Reader, Rae</namePart><role><roleTerm type="text">narrator.</roleTerm></role></name>
        <name type="personal"><namePart>Voice, Val</namePart><role><roleTerm type="code">nrt</roleTerm></role></name>
        <name type="personal"><namePart>Editor, Ed</namePart><role><roleTerm type="text">editor</roleTerm></role></name>
        """
        let found = try await Self.search([Self.record(author: names)])
        #expect(found.first?.metadata.authors == [])
        #expect(found.first?.metadata.narrators == ["Rae Reader", "Val Voice"])
    }

    @Test(arguments: [
        ("Narrated by Frank Muller.", ["Frank Muller"]),
        ("Read by Frank Muller.", ["Frank Muller"]),
        ("Read by Rae Reader and Val Voice.", ["Rae Reader", "Val Voice"]),
        ("Narrator: Frank Muller.", ["Frank Muller"]),
        ("Readers: Rae Reader, Val Voice.", ["Rae Reader", "Val Voice"]),
        ("Performed by Frank Muller.", ["Frank Muller"]),
        ("Read by Rae Reader, Val Voice and Sam Speaker.", ["Rae Reader", "Val Voice", "Sam Speaker"]),
        ("Narrators: Rae Reader; Val Voice", ["Rae Reader", "Val Voice"]),
        ("  narrated   by\n FRANK MULLER  ", ["FRANK MULLER"]),
        ("Read by J. R. Voice.", ["J. R. Voice"]),
        ("Read by Rae Reader and Rae Reader.", ["Rae Reader"]),
        ("Read by the author.", ["Ann Author"]),
        ("Read by John Le Carre\u{301}.", ["John Le Carré"]),
    ])
    func C4_narratorsFromThePerformersNote(text: String, narrators: [String]) async throws {
        // The note is believed before the other names in the record.
        let candidate = try await Self.one(
            #"<name type="personal"><namePart>Other, Someone</namePart></name><note type="performers">\#(text)</note>"#)
        #expect(candidate.metadata.narrators == narrators)
        #expect(candidate.metadata.authors == ["Ann Author"])
    }

    @Test(arguments: [
        "", "Full cast recording with music.", "Narrated by", "Read by .",
        "Read by a cast of some of the finest voices ever to have been gathered in one place.",
    ])
    func C4_aNoteThatNamesNobodyFallsBackToTheOtherNames(text: String) async throws {
        let candidate = try await Self.one(
            #"<name type="personal"><namePart>Muller, Frank, 1951-</namePart></name><note type="performers">\#(text)</note>"#)
        #expect(candidate.metadata.narrators == ["Frank Muller"])
    }

    @Test func C4_aNoteOfAnotherKindIsNotAPerformersNote() async throws {
        let candidate = try await Self.one(#"<note>Read by Rae Reader.</note><note type="statement of responsibility">Narrated by Val Voice.</note>"#)
        #expect(candidate.metadata.narrators == [])
    }

    // MARK: C4 the rest

    @Test(arguments: [
        ("<dateIssued>p1987</dateIssued>", 1987),
        ("<dateIssued>c1986</dateIssued>", 1986),
        ("<dateIssued>[1994?]</dateIssued>", 1994),
        (#"<dateIssued encoding="marc">1987</dateIssued><dateIssued>p1986</dateIssued>"#, 1987),
        (#"<dateIssued>p1986</dateIssued><dateIssued encoding="marc">1987</dateIssued>"#, 1987),
        (#"<dateIssued encoding="marc">19uu</dateIssued><dateIssued>p1990, c1989.</dateIssued>"#, 1990),
        ("<dateIssued>198-</dateIssued>", nil),
        ("<dateIssued>19870</dateIssued>", nil),
        ("<dateIssued>0000</dateIssued>", nil),
        ("<dateCreated>1987</dateCreated>", nil),
        ("", nil),
    ] as [(String, Int?)])
    func C4_theYear(xml: String, year: Int?) async throws {
        let candidate = try await Self.one("<originInfo>\(xml)</originInfo>")
        #expect(candidate.metadata.year == year)
        #expect(candidate.edition.year == year)
    }

    @Test(arguments: [
        ("<agent><namePart>Recorded Books</namePart></agent>", "Recorded Books"),
        ("<publisher>Books on Tape,</publisher>", "Books on Tape"),
        ("<agent><namePart> Hodder &amp; Stoughton : </namePart></agent><publisher>Other</publisher>", "Hodder & Stoughton"),
        ("<publisher>Other</publisher><agent><namePart>Recorded Books</namePart></agent>", "Recorded Books"),
        ("<agent><namePart>  </namePart></agent>", nil),
        ("<place><placeTerm>London</placeTerm></place>", nil),
    ] as [(String, String?)])
    func C4_thePublisher(xml: String, publisher: String?) async throws {
        let candidate = try await Self.one("<originInfo>\(xml)</originInfo>")
        #expect(candidate.metadata.publisher == publisher)
        #expect(candidate.edition.publisher == publisher)
    }

    @Test(arguments: [
        (#"<languageTerm authority="iso639-2b" type="code">eng</languageTerm>"#, "en"),
        (#"<languageTerm type="text">French</languageTerm>"#, "fr"),
        ("<languageTerm>zxx</languageTerm><languageTerm>ger</languageTerm>", "de"),
        ("<languageTerm>nonsense</languageTerm>", nil),
        ("", nil),
    ] as [(String, String?)])
    func C4_theLanguage(xml: String, language: String?) async throws {
        #expect(try await Self.one("<language>\(xml)</language>").metadata.language == language)
    }

    @Test(arguments: [
        ("<extent>12 sound cassettes (18 hr.) : analog.</extent>", 64_800.0),
        ("<extent>8 sound discs (9 hr., 30 min.) : digital ; 4 3/4 in.</extent>", 34_200.0),
        ("<extent>1 box</extent><extent>2 sound cassettes (ca. 90 min.)</extent>", 5_400.0),
        ("<extent>12 sound cassettes : analog.</extent>", nil),
        ("", nil),
    ] as [(String, Double?)])
    func C4_theLength(xml: String, seconds: Double?) async throws {
        #expect(try await Self.one("<physicalDescription>\(xml)</physicalDescription>").metadata.durationSeconds == seconds)
    }

    @Test(arguments: [
        (#"<identifier type="isbn">034038784X :</identifier>"#, "034038784X"),
        (#"<identifier type="isbn">0399139540 (alk. paper) :</identifier>"#, "0399139540"),
        (#"<identifier type="isbn">0394551419 :</identifier><identifier type="isbn">9780394551418</identifier>"#, "9780394551418"),
        (#"<identifier type="isbn">978-0-394-55141-8 (set)</identifier>"#, "9780394551418"),
        (#"<identifier type="isbn" invalid="yes">9780394551418</identifier>"#, nil),
        (#"<identifier type="lccn">89750759</identifier><identifier type="isbn">123</identifier>"#, nil),
        (#"<identifier>9780394551418</identifier>"#, nil),
    ] as [(String, String?)])
    func C4_theISBN(xml: String, isbn: String?) async throws {
        #expect(try await Self.one(xml).metadata.isbn == isbn)
    }

    // MARK: C5

    @Test(arguments: [
        (#"<form authority="marccategory">sound recording</form><form authority="marcsmd">sound cassette</form>"#, EditionFormat.cassette),
        ("<form>Sound Cassette</form>", .cassette),
        (#"<form authority="marcsmd">sound disc</form>"#, .cd),
        ("<form>sound recording</form><extent>8 sound discs (9 hr.) : digital ; 4 3/4 in.</extent>", .cd),
        ("<form>sound recording</form><extent>12 sound cassettes (18 hr.)</extent>", .cassette),
        ("<form>sound disc</form><extent>1 sound disc (11 hr.) : digital, MP3 file ; 4 3/4 in.</extent>", .mp3CD),
        // A record that turns is not a compact disc.
        ("<form>sound disc</form><extent>2 sound discs : analog, 33 1/3 rpm ; 12 in.</extent>", .other),
        ("<form>sound recording</form>", .other),
        ("<form>remote</form><form>electronic</form>", .other),
        ("", .other),
    ])
    func C5_theFormat(xml: String, format: EditionFormat) async throws {
        #expect(try await Self.one("<physicalDescription>\(xml)</physicalDescription>").edition.format == format)
    }

    @Test(arguments: [
        ("<originInfo><edition>Unabridged.</edition></originInfo>", false),
        ("<originInfo><edition>Abridged.</edition></originInfo>", true),
        ("<originInfo><edition>Abridged ed.</edition></originInfo>", true),
        ("<originInfo><edition>UNABRIDGED</edition></originInfo>", false),
        ("<note>Unabridged recording of the book.</note>", false),
        ("<note>Abridged.</note>", true),
        (#"<note type="performers">Read by Rae Reader.</note><note>An abridged reading.</note>"#, true),
        // The edition statement is believed before a note.
        ("<originInfo><edition>Unabridged.</edition></originInfo><note>Abridged version also issued.</note>", false),
        ("<originInfo><edition>1st ed.</edition></originInfo><note>In container.</note>", nil),
        ("", nil),
    ] as [(String, Bool?)])
    func C5_abridgedOrNot(xml: String, abridged: Bool?) async throws {
        #expect(try await Self.one(xml).edition.abridged == abridged)
    }

    // MARK: C6

    @Test func C6_theNoteSaysOnlyWhatIsKnown() async throws {
        #expect(try await Self.one("").note == "Library of Congress · Audio")
        let disc = """
        <originInfo><dateIssued>p1999</dateIssued><edition>Abridged.</edition></originInfo>
        <physicalDescription><form>sound disc</form><extent>2 sound discs (ca. 45 min.)</extent></physicalDescription>
        """
        #expect(try await Self.one(disc).note == "Library of Congress · CD · Abridged · 45m · 1999")
        let cassette = "<physicalDescription><form>sound cassette</form><extent>(9 hr., 30 min.)</extent></physicalDescription>"
        #expect(try await Self.one(cassette).note == "Library of Congress · Cassette · 9h 30m")
    }

    @Test func C6_theIdIsTheRecordsOwn() async throws {
        let found = try await Self.search([Self.record(id: " 5615214\n"), Self.record(id: "22"), Self.record(id: "22")])
        #expect(found.map(\.id) == ["libraryOfCongress:5615214", "libraryOfCongress:22", "libraryOfCongress:22"])
        #expect(found.allSatisfy { $0.source == .libraryOfCongress && !$0.hasMoreDetails && $0.coverURL == nil && $0.thumbnailURL == nil })
    }

    // MARK: C7

    @Test func C7_notesAndAbstractsAreNeverTheDescription() async throws {
        let candidate = try await Self.one("""
        <note>Invented note.</note><note type="summary">An invented summary.</note><abstract>An invented abstract.</abstract>
        <note type="performers">Narrated by Rae Reader.</note><tableOfContents>One -- Two</tableOfContents>
        """)
        #expect(candidate.metadata.summary == nil)
        #expect(candidate.metadata.genre == nil)
        #expect(candidate.metadata.series == nil)
        #expect(candidate.metadata.narrators == ["Rae Reader"])
    }

    // MARK: C8

    @Test func C8_noRecordsIsAnEmptyList() async throws {
        let http = FakeHTTP(data: fixture("loc-none", type: "xml"))
        #expect(try await LibraryOfCongressProvider(http: http).search(Self.query).isEmpty)
        #expect(http.urls.count == 1)
        #expect(try await Self.search([]).isEmpty)
    }

    @Test(arguments: [403, 429, 500, 503, 204, 301])
    func C8_anErrorStatusIsRefused(status: Int) async throws {
        let http = FakeHTTP(data: fixture("loc-perfectspy", type: "xml"), status: status)
        await #expect(throws: LookupError.refused(status: status)) {
            _ = try await LibraryOfCongressProvider(http: http).search(Self.query)
        }
    }

    @Test(arguments: [
        "", "   ", "not xml", "{}", #"{"records": []}"#,
        "<html><body>Busy</body></html>",
        "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body></body></html>",
        "<zs:searchRetrieveResponse xmlns:zs=\"http://www.loc.gov/zing/srw/\"><zs:records>",
        "<zs:searchRetrieveResponse xmlns:zs=\"http://www.loc.gov/zing/srw/\"><zs:records></zs:wrong></zs:searchRetrieveResponse>",
        "<searchRetrieveResponse><a></b></searchRetrieveResponse>",
        // Well-formed, but not an answer to a search.
        "<?xml version=\"1.0\"?><mods><titleInfo><title>T</title></titleInfo></mods>",
        "<explainResponse/>",
    ])
    func C8_whatCannotBeReadIsUnreadable(body: String) async throws {
        await #expect(throws: LookupError.unreadable) {
            _ = try await LibraryOfCongressProvider(http: FakeHTTP(data: Data(body.utf8))).search(Self.query)
        }
    }

    @Test func C8_anAnswerCutShortIsUnreadable() async throws {
        let whole = fixture("loc-perfectspy", type: "xml")
        // Cut inside the third record, after two whole ones: nothing of it is used.
        for length in [whole.count - 10, whole.count - 400, whole.count / 2, 200] {
            await #expect(throws: LookupError.unreadable) {
                _ = try await LibraryOfCongressProvider(http: FakeHTTP(data: whole.prefix(length))).search(Self.query)
            }
        }
    }

    @Test func C8_theCataloguesOwnErrorIsUnreadable() async throws {
        let body = """
        <zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/"><zs:version>1.1</zs:version>\
        <zs:diagnostics><diagnostic xmlns="http://www.loc.gov/zing/srw/diagnostic/"><uri>info:srw/diagnostic/1/10</uri>\
        <message>Query syntax error</message></diagnostic></zs:diagnostics></zs:searchRetrieveResponse>
        """
        await #expect(throws: LookupError.unreadable) {
            _ = try await LibraryOfCongressProvider(http: FakeHTTP(data: Data(body.utf8))).search(Self.query)
        }
    }

    @Test func C8_aMalformedRecordIsSkipped() async throws {
        let found = try await Self.search([
            Self.record(id: "1"),
            // No title.
            Self.record(id: "2", title: ""),
            Self.record(id: "3", title: "<titleInfo><title>  </title></titleInfo>"),
            // No identifier of its own.
            #"<titleInfo><title>The Book</title></titleInfo><typeOfResource>sound recording</typeOfResource>"#,
            Self.record(id: " "),
            // Not a record at all.
            "",
            "<unexpected><typeOfResource>sound recording</typeOfResource></unexpected>",
            Self.record(id: "4"),
        ])
        #expect(found.map(\.id) == ["libraryOfCongress:1", "libraryOfCongress:4"])
    }

    @Test func C8_namespacePrefixesDoNotMatter() async throws {
        let body = """
        <srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/" xmlns:m="http://www.loc.gov/mods/v3">\
        <srw:records><srw:record><srw:recordData><m:mods><m:titleInfo><m:title>The Book</m:title></m:titleInfo>\
        <m:typeOfResource>sound recording</m:typeOfResource><m:note type="performers">Read by Rae Reader.</m:note>\
        <m:recordInfo><m:recordIdentifier>9</m:recordIdentifier></m:recordInfo></m:mods></srw:recordData></srw:record></srw:records>\
        </srw:searchRetrieveResponse>
        """
        let found = try await LibraryOfCongressProvider(http: FakeHTTP(data: Data(body.utf8))).search(Self.query)
        #expect(found.map(\.id) == ["libraryOfCongress:9"])
        #expect(found.first?.metadata.narrators == ["Rae Reader"])
    }

    @Test func C8_C9_anAnswerOverTheByteLimitIsRefused() async throws {
        // A fetcher that did not hold to the limit itself.
        var body = fixture("loc-perfectspy", type: "xml")
        body.append(Data(repeating: UInt8(ascii: " "), count: 5 * 1024 * 1024))
        await #expect(throws: LookupError.unreadable) {
            _ = try await LibraryOfCongressProvider(http: FakeHTTP(data: body)).search(Self.query)
        }
        await #expect(throws: LookupError.unreadable) {
            _ = try await LibraryOfCongressProvider(http: FakeHTTP(throwing: LookupError.unreadable)).search(Self.query)
        }
        await #expect(throws: LookupError.notReachable) {
            _ = try await LibraryOfCongressProvider(http: FakeHTTP(throwing: LookupError.notReachable)).search(Self.query)
        }
    }

    @Test func C8_everythingTakenIsCleaned() async throws {
        let long = String(repeating: "x", count: 3000)
        let candidate = try await Self.one("""
        <name type="personal"><namePart>Reader,&#x202E; Rae&#x2029;</namePart></name>
        <originInfo><agent><namePart>Recorded\n\tBooks&#x202E; \(long)</namePart></agent></originInfo>
        """)
        #expect(candidate.metadata.narrators == ["Rae Reader"])
        #expect(candidate.metadata.publisher?.hasPrefix("Recorded Books x") == true)
        #expect(candidate.metadata.publisher?.count == LookupText.lineLimit)
        #expect(candidate.note.unicodeScalars.allSatisfy { !LookupText.isUnwanted($0) })

        let titled = try await Self.search([Self.record(id: "7\u{202E}", title: "<titleInfo><title>The\u{202E} Book \(long)</title></titleInfo>")])
        #expect(titled.first?.metadata.title.count == LookupText.nameLimit)
        #expect(titled.first?.metadata.title.hasPrefix("The Book x") == true)
        #expect(titled.first?.id == "libraryOfCongress:7")
    }

    @Test func C8_noMoreRecordsAreTakenThanWereAskedFor() async throws {
        let records = (1...40).map { Self.record(id: String($0)) }
        let http = FakeHTTP(data: Self.answer(records))
        #expect(try await LibraryOfCongressProvider(http: http, limit: 5).search(Self.query).count == 5)
        #expect(try await LibraryOfCongressProvider(http: http).search(Self.query).count == 20)
    }

    // MARK: C8 hostile answers

    private static func timed(_ body: Data) async -> Result<[LookupCandidate], any Error> {
        let clock = ContinuousClock()
        let start = clock.now
        let result: Result<[LookupCandidate], any Error>
        do {
            result = .success(try await LibraryOfCongressProvider(http: FakeHTTP(data: body)).search(query))
        } catch {
            result = .failure(error)
        }
        #expect(clock.now - start < .seconds(20))
        return result
    }

    private static func isUnreadable(_ result: Result<[LookupCandidate], any Error>) -> Bool {
        if case .failure(let error) = result { return error as? LookupError == .unreadable }
        return false
    }

    /// Entities that grow a thousand million times over are never expanded.
    @Test func C8_entityExpansionIsOff() async throws {
        var entities = #"<!ENTITY a0 "aaaaaaaaaa">"#
        for level in 1...9 {
            entities += #"<!ENTITY a\#(level) "\#(String(repeating: "&a\(level - 1);", count: 10))">"#
        }
        let body = """
        <?xml version="1.0"?><!DOCTYPE zs:searchRetrieveResponse [\(entities)]>
        <zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/"><zs:records><zs:record><zs:recordData>\
        <mods xmlns="http://www.loc.gov/mods/v3">\(Self.record(title: "<titleInfo><title>&a9;</title></titleInfo>"))</mods>\
        </zs:recordData></zs:record></zs:records></zs:searchRetrieveResponse>
        """
        #expect(Self.isUnreadable(await Self.timed(Data(body.utf8))))
    }

    /// Nothing outside the answer is ever read into it.
    @Test func C8_externalEntitiesAreNeverFetched() async throws {
        for declaration in [
            #"<!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/hosts">]>"#,
            #"<!DOCTYPE r [<!ENTITY x SYSTEM "https://example.invalid/x">]>"#,
            #"<!DOCTYPE r SYSTEM "https://example.invalid/x.dtd">"#,
            #"<!DOCTYPE r [<!ENTITY % p SYSTEM "file:///etc/hosts"> %p;]>"#,
            #"<!DOCTYPE r [<!ENTITY x "harmless">]>"#,
        ] {
            let body = """
            <?xml version="1.0"?>\(declaration)
            <zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/"><zs:records><zs:record><zs:recordData>\
            <mods xmlns="http://www.loc.gov/mods/v3">\(Self.record(title: "<titleInfo><title>Book &x;</title></titleInfo>"))</mods>\
            </zs:recordData></zs:record></zs:records></zs:searchRetrieveResponse>
            """
            #expect(Self.isUnreadable(await Self.timed(Data(body.utf8))))
            // The same in other encodings, which a search of the bytes would not see.
            let wide = body.replacingOccurrences(of: #"<?xml version="1.0"?>"#, with: #"<?xml version="1.0" encoding="UTF-16"?>"#)
            for encoding in [String.Encoding.utf16, .utf16BigEndian, .utf16LittleEndian, .utf32] {
                let data = try #require(wide.data(using: encoding))
                #expect(Self.isUnreadable(await Self.timed(data)))
            }
            let named = body.replacingOccurrences(of: #"<?xml version="1.0"?>"#, with: #"<?xml version="1.0" encoding="UTF-7"?>"#)
            #expect(Self.isUnreadable(await Self.timed(Data(named.utf8))))
        }
    }

    /// Were a declaration ever to get past the first look: the reading stops at an entity
    /// declared in the answer, and one that points outside it is never fetched.
    @Test func C8_theReaderItselfExpandsAndFetchesNothing() throws {
        func body(_ declaration: String) -> Data {
            Data("""
            <?xml version="1.0"?>\(declaration)
            <zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/"><zs:records><zs:record><zs:recordData>\
            <mods xmlns="http://www.loc.gov/mods/v3">\(Self.record(title: "<titleInfo><title>Book &a9;</title></titleInfo>"))</mods>\
            </zs:recordData></zs:record></zs:records></zs:searchRetrieveResponse>
            """.utf8)
        }
        var entities = #"<!ENTITY a0 "aaaaaaaaaa">"#
        for level in 1...9 {
            entities += #"<!ENTITY a\#(level) "\#(String(repeating: "&a\(level - 1);", count: 10))">"#
        }
        let clock = ContinuousClock()
        let start = clock.now
        for declaration in ["<!DOCTYPE r [\(entities)]>", #"<!DOCTYPE r [<!ENTITY a9 "harmless">]>"#] {
            #expect(throws: LookupError.unreadable) { _ = try MODSReader.parsed(body(declaration)) }
        }
        // A file of this Mac, named as an entity: its text is not read in.
        let outside = (try? MODSReader.parsed(body(#"<!DOCTYPE r [<!ENTITY a9 SYSTEM "file:///etc/hosts">]>"#))) ?? []
        for record in outside {
            #expect(record.titles.allSatisfy { ($0.title ?? "").count <= "Book ".count })
        }
        #expect(clock.now - start < .seconds(20))
        // Without a declaration the same answer is read.
        let plain = try MODSReader.parsed(Self.answer([Self.record()]))
        #expect(plain.count == 1)
        #expect(plain.first?.titles.first?.title == "The Book")
    }

    @Test func C8_deepNestingNeitherHangsNorCrashes() async throws {
        for depth in [100, 5_000, 200_000] {
            let nested = String(repeating: "<a>", count: depth) + "x" + String(repeating: "</a>", count: depth)
            // Inside a record, and in place of the records.
            for body in [
                Self.answer([Self.record(nested)]),
                Data("<zs:searchRetrieveResponse xmlns:zs=\"http://www.loc.gov/zing/srw/\">\(nested)</zs:searchRetrieveResponse>".utf8),
                Data((String(repeating: "<a>", count: depth)).utf8),
            ] {
                switch await Self.timed(body) {
                case .success(let found): #expect(found.count <= 1)
                case .failure(let error): #expect(error as? LookupError == .unreadable)
                }
            }
        }
    }

    @Test func C8_hugeAndManyValuesAreKeptSmall() async throws {
        let huge = String(repeating: "wordy ", count: 120_000)
        let names = String(repeating: #"<name type="personal"><namePart>Reader, Rae</namePart></name>"#, count: 20_000)
        let many = (1...5_000).map { #"<name type="personal"><namePart>Reader\#($0), Rae</namePart></name>"# }.joined()
        let result = await Self.timed(Self.answer([
            Self.record("<note>\(huge)</note><physicalDescription><extent>\(huge)</extent></physicalDescription>\(names)\(many)",
                        title: "<titleInfo><title>\(huge)</title></titleInfo>"),
        ]))
        let candidate = try #require(try result.get().first)
        #expect(candidate.metadata.title.count == LookupText.nameLimit)
        #expect(candidate.metadata.narrators.count <= 50)
        #expect(candidate.metadata.narrators.first == "Rae Reader")
        #expect(candidate.metadata.summary == nil)
    }
}

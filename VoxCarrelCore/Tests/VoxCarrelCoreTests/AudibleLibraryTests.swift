import Foundation
import Security
import Testing
@testable import VoxCarrelCore

/// AL1–AL9: linking to an Audible account and bringing its library in.
@Suite struct AudibleLibraryTests {
    typealias F = LibraryFixture

    /// Answers by the path of the address asked, and keeps what was asked.
    final class FakeTransport: AudibleTransport, @unchecked Sendable {
        var answers: [String: (Data, Int)] = [:]
        var asked: [URLRequest] = []
        var fails = false
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            asked.append(request)
            if fails { throw AudibleAccountError.notReachable }
            let key = (request.url?.path ?? "") + (request.url?.query.map { "?" + $0 } ?? "")
            let answer = answers[key] ?? answers[request.url?.path ?? ""] ?? (Data("{}".utf8), 404)
            return (answer.0, answer.1)
        }
    }

    /// A key of this test's own, made here: never anybody's real one.
    static let testKey: (pem: String, publicKey: SecKey) = {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let data = SecKeyCopyExternalRepresentation(key, nil)! as Data
        return (data.base64EncodedString(), SecKeyCopyPublicKey(key)!)
    }()

    static func account(_ store: AudibleStore = .us) -> AudibleAccount {
        AudibleAccount(
            store: store, serial: "SERIAL", adpToken: "{adp-token}", devicePrivateKey: testKey.pem,
            accessToken: "access", refreshToken: "refresh", deviceName: "Ann's 2nd Audible for iPhone")
    }

    @Test func AL1_aRequestIsSignedWithTheDevicesKeyOverItsMethodPathDateBodyAndToken() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.5)
        let headers = try AudibleSigner.headers(method: "GET", path: "/1.0/library?page=1", account: Self.account(), date: date)
        #expect(headers["x-adp-token"] == "{adp-token}")
        #expect(headers["x-adp-alg"] == "SHA256withRSA:1.0")
        let parts = try #require(headers["x-adp-signature"]).split(separator: ":", maxSplits: 1).map(String.init)
        #expect(parts.count == 2 && parts[1].hasSuffix("Z") && parts[1].hasPrefix("2027-01-15T08:00:00"))
        let signed = Data("GET\n/1.0/library?page=1\n\(parts[1])\n\n{adp-token}".utf8)
        let signature = try #require(Data(base64Encoded: parts[0]))
        #expect(SecKeyVerifySignature(
            Self.testKey.publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil))
        // A key given as PEM is the same key.
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(Self.testKey.pem)\n-----END RSA PRIVATE KEY-----\n"
        #expect(AudibleSigner.keyData(pem) == AudibleSigner.keyData(Self.testKey.pem))
        // What is no key is refused.
        var broken = Self.account()
        broken.devicePrivateKey = "not a key"
        #expect(throws: AudibleAccountError.unusableKey) {
            _ = try AudibleSigner.headers(method: "GET", path: "/", account: broken)
        }
    }

    @Test func AL2_theSignInPageIsAmazonsOwnAndCarriesOnlyADigestOfWhatTheAppKeeps() throws {
        var next: UInt8 = 0
        let attempt = try #require(AudibleLink.begin(store: .uk) { next &+= 7; return next })
        #expect(attempt.signInURL.host == "www.amazon.co.uk" && attempt.signInURL.scheme == "https")
        #expect(attempt.signInURL.path == "/ap/signin")
        #expect(attempt.serial.count == 40 && attempt.serial.allSatisfy { $0.isLetter || $0.isNumber })
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: attempt.signInURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        #expect(query["openid.return_to"] == "https://www.amazon.co.uk/ap/maplanding")
        #expect(query["openid.assoc_handle"] == "amzn_audible_ios_uk")
        #expect(query["marketPlaceId"] == "A2I9A3Q2GNFNGQ")
        #expect(query["openid.oa2.client_id"] == "device:\(attempt.clientId)")
        #expect(attempt.clientId == Data("\(attempt.serial)#A2CZJZGLK2JJVM".utf8).map { String(format: "%02x", $0) }.joined())
        // The verifier stays with the app; the address has its digest.
        #expect(!attempt.signInURL.absoluteString.contains(attempt.verifier))
        #expect(query["openid.oa2.code_challenge"]?.isEmpty == false)
        // Two attempts are never the same.
        let a = try #require(AudibleLink.begin(store: .us)), b = try #require(AudibleLink.begin(store: .us))
        #expect(a.serial != b.serial && a.verifier != b.verifier)
    }

    @Test func AL3_theSignInCodeIsTakenOnlyFromAmazonsOwnAddressForThatStore() throws {
        let attempt = try #require(AudibleLink.begin(store: .us))
        let good = "https://www.amazon.com/ap/maplanding?openid.assoc_handle=x&openid.oa2.authorization_code=ABC123&more=1"
        #expect(AudibleLink.signInCode(in: "  \(good)\n", for: attempt) == "ABC123")
        for bad in [
            "https://www.amazon.co.uk/ap/maplanding?openid.oa2.authorization_code=ABC123",
            "https://evil.example/ap/maplanding?openid.oa2.authorization_code=ABC123",
            "http://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=ABC123",
            "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=",
            "https://www.amazon.com/ap/signin", "some text that was on the clipboard", "",
        ] {
            #expect(AudibleLink.signInCode(in: bad, for: attempt) == nil, "\(bad)")
        }
    }

    @Test func AL4_registeringGivesTheDevicesKeysAndAFailureSaysOnlyAmazonsWordForIt() async throws {
        let attempt = try #require(AudibleLink.begin(store: .us))
        let transport = FakeTransport()
        let answer: [String: Any] = ["response": ["success": [
            "tokens": [
                "bearer": ["access_token": "A", "refresh_token": "R", "expires_in": "3600"],
                "mac_dms": ["adp_token": "{adp}", "device_private_key": "KEY"],
            ],
            "extensions": ["device_info": ["device_name": "Ann's 3rd Audible for iPhone"],
                           "customer_info": ["name": "Ann", "user_id": "amzn1.account.X"]],
        ]]]
        transport.answers["/auth/register"] = (try JSONSerialization.data(withJSONObject: answer), 200)
        let account = try await AudibleLink.register(code: "CODE", attempt: attempt, transport: transport)
        #expect(account == AudibleAccount(
            store: .us, serial: attempt.serial, adpToken: "{adp}", devicePrivateKey: "KEY", accessToken: "A",
            refreshToken: "R", deviceName: "Ann's 3rd Audible for iPhone"))
        // What was sent: to Amazon's own API, with the code and the verifier.
        let sent = try #require(transport.asked.first)
        #expect(sent.url?.absoluteString == "https://api.amazon.com/auth/register" && sent.httpMethod == "POST")
        let sentBody = try #require(sent.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        let auth = try #require(body["auth_data"] as? [String: Any])
        #expect(auth["authorization_code"] as? String == "CODE" && auth["code_verifier"] as? String == attempt.verifier)
        #expect((body["registration_data"] as? [String: Any])?["device_serial"] as? String == attempt.serial)

        // Refused.
        let refusal: [String: Any] = ["response": ["error": ["code": "InvalidValue", "message": "about the account"]]]
        transport.answers["/auth/register"] = (try JSONSerialization.data(withJSONObject: refusal), 400)
        await #expect(throws: AudibleAccountError.notRegistered("InvalidValue")) {
            _ = try await AudibleLink.register(code: "CODE", attempt: attempt, transport: transport)
        }
        // Removing the device.
        transport.answers["/auth/deregister"] = (Data("{}".utf8), 200)
        #expect(try await AudibleLink.unregister(account, transport: transport))
        #expect(transport.asked.last?.value(forHTTPHeaderField: "Authorization") == "Bearer A")
        transport.answers["/auth/deregister"] = (Data("{}".utf8), 401)
        #expect(try await AudibleLink.unregister(account, transport: transport) == false)
    }

    static func item(
        _ asin: String, _ title: String, author: String = "Ann Author", series: (String, String)? = nil,
        finished: Bool = false, percent: Double = 0, kind: String = "SinglePartBook"
    ) -> [String: Any] {
        var item: [String: Any] = [
            "asin": asin, "title": title, "authors": [["asin": "A1", "name": author]],
            "narrators": [["name": "Nell Narrator"]], "runtime_length_min": 600, "is_finished": finished,
            "percent_complete": percent, "purchase_date": "2021-03-04T05:06:07.890Z", "release_date": "2019-05-01",
            "publisher_name": "A Press", "language": "english", "content_delivery_type": kind,
            "product_images": ["500": "https://m.media-amazon.com/images/I/x._SL500_.jpg"],
            "category_ladders": [["root": "Genres", "ladder": [
                ["name": "Mystery, Thriller & Suspense"], ["name": "Thriller & Suspense"], ["name": "Espionage"],
            ]]],
        ]
        if let series { item["series"] = [["asin": "S1", "title": series.0, "sequence": series.1]] }
        return item
    }

    @Test func AL5_aLibraryItemIsReadAsABookAndAPodcastIsNot() throws {
        let book = try #require(AudibleLibraryReader.book(from: Self.item(
            "B000000001", "The Gray Man", author: "Mark Greaney", series: ("Gray Man", "1"), finished: true, percent: 99.5)))
        #expect(book.asin == "B000000001" && book.title == "The Gray Man" && book.authors == ["Mark Greaney"])
        #expect(book.narrators == ["Nell Narrator"] && book.series == "Gray Man" && book.seriesNumber == "1")
        #expect(book.minutes == 600 && book.isFinished && book.percentComplete == 99.5 && book.year == 2019)
        #expect(book.purchased == Date(timeIntervalSince1970: 1_614_834_367.89))
        #expect(book.genrePaths == [["Mystery, Thriller & Suspense", "Thriller & Suspense", "Espionage"]])
        #expect(book.coverURL?.host == "m.media-amazon.com")
        #expect(book.status == .finished)
        #expect(AudibleLibraryReader.book(from: Self.item("B2", "Begun", percent: 42))?.status == .inProgress)
        #expect(AudibleLibraryReader.book(from: Self.item("B3", "Untouched"))?.status == .unread)
        #expect(AudibleLibraryReader.book(from: Self.item("B4", "A Show", kind: "PodcastParent")) == nil)
        #expect(AudibleLibraryReader.book(from: ["asin": "B5"]) == nil)
        #expect(AudibleLibraryReader.book(from: "nonsense") == nil)
    }

    @Test func AL6_theLibraryIsReadPageByPageWithSignedRequestsAndARefusalIsSaidAsOne() async throws {
        let transport = FakeTransport()
        func page(_ n: Int) -> String {
            "/1.0/library?num_results=50&page=\(n)&response_groups=\(AudibleLibraryReader.groups)"
        }
        let first = (0..<50).map { Self.item("B\(1000 + $0)", "Book \($0)") }
        let second = [Self.item("B2000", "Last Book"), Self.item("B1000", "Book 0 again"), Self.item("P1", "Show", kind: "PodcastParent")]
        transport.answers[page(1)] = (try JSONSerialization.data(withJSONObject: ["items": first]), 200)
        transport.answers[page(2)] = (try JSONSerialization.data(withJSONObject: ["items": second]), 200)
        let books = try await AudibleLibraryReader.books(of: Self.account(.uk), transport: transport)
        #expect(books.count == 51 && books.last?.title == "Last Book")
        #expect(transport.asked.count == 2)
        #expect(transport.asked.allSatisfy { $0.url?.host == "api.audible.co.uk" && $0.httpMethod == "GET" })
        #expect(transport.asked.allSatisfy { $0.value(forHTTPHeaderField: "x-adp-signature") != nil })

        transport.answers[page(1)] = (Data("{}".utf8), 403)
        await #expect(throws: AudibleAccountError.refused(403)) {
            _ = try await AudibleLibraryReader.books(of: Self.account(.uk), transport: transport)
        }
        transport.fails = true
        await #expect(throws: AudibleAccountError.notReachable) {
            _ = try await AudibleLibraryReader.books(of: Self.account(.uk), transport: transport)
        }
    }

    private func owned(_ asin: String, _ title: String, author: String = "Ann Author", finished: Bool = false, percent: Double = 0,
                       series: (String, String)? = nil) throws -> AudibleOwnedBook {
        try #require(AudibleLibraryReader.book(from: Self.item(asin, title, author: author, series: series, finished: finished, percent: percent)))
    }

    @Test func AL7_booksTheLibraryLacksAreAddedAsOwnedOnAudibleWithAudiblesDetails() throws {
        let f = try F()
        let list = [
            try owned("B000000001", "The Gray Man", author: "Mark Greaney", finished: true, percent: 100, series: ("Gray Man", "1")),
            try owned("B000000002", "On Target", author: "Mark Greaney", percent: 40, series: ("Gray Man", "2")),
            try owned("B000000003", "Ballistic", author: "Mark Greaney", series: ("Gray Man", "3")),
        ]
        // Asked first what it would do: nothing is changed.
        let preview = try f.service.bringInAudibleLibrary(list, store: .us, apply: false)
        #expect(preview.added.count == 3 && preview.marked.isEmpty && preview.statusChanged == 2)
        #expect(try f.store.books().isEmpty)

        let report = try f.service.bringInAudibleLibrary(list, store: .us, apply: true)
        #expect(report == preview)
        let books = try f.store.books()
        #expect(books.map(\.title) == ["Ballistic", "On Target", "The Gray Man"])
        let gray = try #require(books.last)
        #expect(gray.asin == "B000000001" && gray.series == "Gray Man" && gray.seriesNumber == "1")
        #expect(gray.narrators == ["Nell Narrator"] && gray.durationSeconds == 36_000 && gray.year == 2019)
        #expect(gray.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B000000001")])
        #expect(gray.readStatus == .finished && gray.dateFinished != nil)
        #expect(gray.genres == ["Thrillers & Spies"])
        #expect(gray.folderPath == nil && !gray.needsAttention)
        // Dated when it was bought, so it is not "recently added".
        #expect(abs(gray.dateAdded.timeIntervalSince1970 - 1_614_834_367.89) < 1)
        #expect(books[1].readStatus == .inProgress && books[0].readStatus == .unread)
        #expect(try f.store.allFiles().isEmpty)

        // Done again, it changes nothing.
        let again = try f.service.bringInAudibleLibrary(list, store: .us, apply: true)
        #expect(again.changesNothing && again.alreadyThere == 3)
        #expect(try f.store.books().count == 3)
        // The series now feeds Up Next: after the finished one comes the one being read, so nothing more.
        #expect(try f.service.upNext().inProgress.map(\.title) == ["On Target"])
    }

    @Test func AL8_aBookTheLibraryHasIsMarkedAndKeepsItsOwnDetailsAndItsStatusOnlyMovesOn() throws {
        let f = try F()
        // By Audible ID, with details of the owner's own; and by title and author.
        var first = Book(metadata: BookMetadata(title: "My Own Title For It", authors: ["M. Greaney"]))
        first.asin = "B000000001"
        first.readStatus = .finished
        first.rating = 5
        let byId = try #require(try f.store.insert(first, files: []).id)
        var second = Book(metadata: BookMetadata(title: "On Target", authors: ["Mark Greaney"]))
        second.readStatus = .inProgress
        let byName = try #require(try f.store.insert(second, files: []).id)

        let list = [
            try owned("B000000001", "The Gray Man", author: "Mark Greaney", percent: 10),
            try owned("B000000002", "On Target", author: "Mark Greaney", finished: true, percent: 100),
        ]
        let report = try f.service.bringInAudibleLibrary(list, store: .uk, apply: true)
        #expect(report.added.isEmpty && report.marked.count == 2 && report.statusChanged == 1)
        #expect(try f.store.books().count == 2)

        let one = try #require(try f.store.book(id: byId))
        #expect(one.title == "My Own Title For It" && one.authors == ["M. Greaney"] && one.rating == 5)
        // Finished here, only begun there: it is not moved back.
        #expect(one.readStatus == .finished)
        #expect(one.externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B000000001")])
        let two = try #require(try f.store.book(id: byName))
        #expect(two.readStatus == .finished && two.asin == "B000000002")
        #expect(LibraryService.movedOn(.unread, to: .unread) == nil && LibraryService.movedOn(.finished, to: .inProgress) == nil)
        #expect(LibraryService.movedOn(.unread, to: .finished) == .finished)
    }

    @Test func AL9_coversAreStoredOnlyForBooksThatHaveNone() throws {
        let f = try F()
        _ = try f.service.bringInAudibleLibrary([try owned("B000000001", "The Gray Man")], store: .us, apply: true)
        let waiting = try f.service.audibleBooksWithoutCover()
        #expect(waiting.map(\.asin) == ["B000000001"])
        let id = try #require(waiting.first?.bookId)
        let cover = CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), mime: "image/jpeg")
        #expect(try f.service.setCoverIfNone(cover, for: id))
        #expect(try f.service.setCoverIfNone(cover, for: id) == false)
        #expect(try f.service.setCoverIfNone(cover, for: 9999) == false)
        #expect(try f.service.audibleBooksWithoutCover().isEmpty)
    }
}

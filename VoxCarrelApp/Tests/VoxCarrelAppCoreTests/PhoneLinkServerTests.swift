import Foundation
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A real server on the loopback address, serving a file in a temporary folder.
@MainActor
private final class Link {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let folder: URL
    let file: URL
    let name: String
    let bytes: [UInt8]
    let timers: LinkTimers
    let events: LinkEvents
    var server: PhoneLinkServer?
    private(set) var offer: PhoneLinkOffer

    /// The server's own limits, but with waits long enough that a test held up by the
    /// rest of the suite is never taken for a caller that has gone quiet.
    nonisolated static var patient: PhoneLinkServer.Settings {
        var settings = PhoneLinkServer.Settings()
        settings.requestTimeout = 120
        settings.closeTimeout = 120
        settings.stallTimeout = 120
        return settings
    }

    init(
        bytes: [UInt8] = LinkProbe.contents(10_000), name: String = "Dune.m4b",
        settings: PhoneLinkServer.Settings = Link.patient
    ) throws {
        folder = try makeTempDir()
        file = folder.appendingPathComponent("served.bin")
        try Data(bytes).write(to: file)
        self.bytes = bytes
        self.name = name
        let timers = LinkTimers()
        let events = LinkEvents()
        self.timers = timers
        self.events = events
        let server = PhoneLinkServer(addresses: { ["127.0.0.1"] }, schedule: timers.schedule, settings: settings)
        self.server = server
        offer = try server.start(file: file, fileName: name, now: Self.now) { events.note($0) }
    }

    var port: Int { offer.port }
    var host: String { "127.0.0.1:\(offer.port)" }
    /// The path of the one resource, as a client sends it.
    var path: String { "/\(offer.token)/\(PhoneLinkText.percentEncoded(name))" }

    func request(_ method: String = "GET", path: String? = nil, headers: [String] = []) -> String {
        (["\(method) \(path ?? self.path) HTTP/1.1", "Host: \(host)"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
    }

    var headers: [UInt8] {
        PhoneLinkRequest.fileHeaders(fileName: name, size: Int64(bytes.count), rangeFrom: nil)
    }

    /// Starts another link on the same server.
    func restart() throws {
        let events = events
        offer = try #require(server).start(file: file, fileName: name, now: Self.now) { events.note($0) }
    }

    /// Stops the server and checks that nothing is left listening.
    func end(sourceLocation: SourceLocation = #_sourceLocation) async {
        server?.stop()
        #expect(server?.isServing != true, sourceLocation: sourceLocation)
        #expect(await LinkProbe.portIsClosed(port), "the port is still open", sourceLocation: sourceLocation)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Bytes for a file too large for the system to take in one go: each megabyte differs.
private func largeContents(megabytes: Int) -> [UInt8] {
    let block = LinkProbe.contents(1_048_576)
    var all: [UInt8] = []
    all.reserveCapacity(megabytes * block.count)
    for index in 0..<megabytes {
        all.append(contentsOf: block)
        all[index * block.count] = UInt8(truncatingIfNeeded: index)
        all[index * block.count + 1] = UInt8(truncatingIfNeeded: index >> 8)
    }
    return all
}

/// A run of bytes that compares as one thing and describes itself by its length: when two
/// of them differ, megabytes are neither printed nor searched for where they differ.
private struct Bytes: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var description: String { "\(bytes.count) bytes" }
    var debugDescription: String { description }
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.connectionProxyDictionary = [:]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}

/// Reads an answer's status line and headers off a connection, and no further.
private func readHead(_ connection: RawConnection) async -> String {
    var bytes: [UInt8] = []
    while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
        let next = await connection.read(1)
        guard next.count == 1 else { break }
        bytes += next
    }
    return String(decoding: bytes, as: UTF8.self)
}

@MainActor
@Suite struct PhoneLinkServerTests {
    // MARK: PH1 Starting

    @Test func ph1_startListensOnTheChosenAddressAndReturnsTheOffer() async throws {
        let link = try Link()
        let offer = link.offer
        #expect(offer.address == "127.0.0.1")
        #expect(offer.port > 0 && offer.port < 65536)
        #expect(offer.file == link.file)
        #expect(offer.fileName == "Dune.m4b")
        #expect(offer.expiresAt == Link.now.addingTimeInterval(600))
        #expect(offer.httpURL.absoluteString == "http://127.0.0.1:\(offer.port)/\(offer.token)/Dune.m4b")
        #expect(offer.bookPlayerLink == PhoneLinkText.bookPlayerLink(for: offer.httpURL))
        // 32 bytes, URL-safe, no padding.
        #expect(offer.token.count == 43)
        let standard = offer.token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        #expect(Data(base64Encoded: standard)?.count == 32)
        #expect(link.server?.isServing == true)
        #expect(link.timers.delays == [600])

        // It accepts on that address, and on no other: not even the other loopback one.
        let v4 = try #require(RawConnection(port: offer.port))
        v4.close()
        #expect(RawConnection(port: offer.port, ipv6: true) == nil)
        await link.events.settle()
        #expect(link.events.all == [])
        await link.end()
    }

    @Test func ph1_everyLinkHasItsOwnTokenAndStartingAgainStopsTheEarlierLink() async throws {
        let link = try Link()
        let first = link.offer
        try link.restart()
        let second = link.offer

        #expect(first.token != second.token)
        #expect(link.server?.isServing == true)
        if first.port != second.port {
            #expect(await LinkProbe.portIsClosed(first.port))
        }
        // The earlier link's address gets nothing from the new one.
        let old = "GET /\(first.token)/Dune.m4b HTTP/1.1\r\nHost: \(link.host)\r\n\r\n"
        #expect(try await LinkProbe.exchange(old, port: second.port).isTheRefusal)
        // The new one works.
        let answer = try await LinkProbe.exchange(link.request(), port: second.port)
        #expect(Bytes(answer.body) == Bytes(link.bytes))
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    @Test func ph1_ph8_withNoLocalAddressStartThrowsAPlainError() async throws {
        let folder = try makeTempDir()
        let file = try touch(folder.appendingPathComponent("a.m4b"))
        let timers = LinkTimers()
        for addresses in [[], ["not an address"], ["::1"]] as [[String]] {
            let server = PhoneLinkServer(addresses: { addresses }, schedule: timers.schedule)
            #expect(throws: PhoneLinkError.noLocalAddress) {
                try server.start(file: file, fileName: "a.m4b", now: Link.now) { _ in }
            }
            #expect(!server.isServing)
        }
        #expect(PhoneLinkError.noLocalAddress.localizedDescription == "This Mac has no address on a local network.")
        #expect(timers.delays == [])
    }

    @Test func ph1_aNameThatCannotGoInAnAddressIsRefused() async throws {
        let folder = try makeTempDir()
        let file = try touch(folder.appendingPathComponent("a.m4b"))
        let server = PhoneLinkServer(addresses: { ["127.0.0.1"] }, schedule: LinkTimers().schedule)
        for name in ["", "..", "a/b.m4b", "a\r\nX-Injected: 1.m4b", "a\u{0000}.m4b"] {
            #expect(throws: PhoneLinkError.badFileName) {
                try server.start(file: file, fileName: name, now: Link.now) { _ in }
            }
            #expect(!server.isServing)
        }
    }

    // MARK: PH2 Everything but the one resource

    @Test func ph2_everyOtherRequestGetsTheSameEmpty404AndAClosedConnection() async throws {
        let link = try Link()
        let token = link.offer.token
        var wrongToken = token
        wrongToken.removeLast()
        wrongToken.append(token.last == "A" ? "B" : "A")
        let good = link.request()
        #expect(PhoneLinkRequest.answer(Array(good.utf8), for: PhoneLinkResource(
            token: token, fileName: link.name, size: 10_000, authority: link.host)) == .serve(headOnly: false, rangeFrom: nil))

        let requests: [(what: String, bytes: [UInt8])] = [
            ("a wrong token", Array(link.request(path: "/\(wrongToken)/Dune.m4b").utf8)),
            ("no token", Array(link.request(path: "/Dune.m4b").utf8)),
            ("an empty token", Array(link.request(path: "//Dune.m4b").utf8)),
            ("a wrong name", Array(link.request(path: "/\(token)/Other.m4b").utf8)),
            ("the root", Array(link.request(path: "/").utf8)),
            ("the token alone", Array(link.request(path: "/\(token)").utf8)),
            ("the folder", Array(link.request(path: "/\(token)/").utf8)),
            ("the file on disk", Array(link.request(path: "/\(token)/served.bin").utf8)),
            ("a path with ..", Array(link.request(path: "/\(token)/../\(token)/Dune.m4b").utf8)),
            ("a path out of the folder", Array(link.request(path: "/\(token)/../../../../etc/passwd").utf8)),
            ("an encoded ..", Array(link.request(path: "/\(token)/%2e%2e%2fserved.bin").utf8)),
            ("an encoded slash", Array(link.request(path: "/\(token)%2FDune.m4b").utf8)),
            ("an encoded NUL", Array(link.request(path: "/\(token)/Dune.m4b%00").utf8)),
            ("a double encoding", Array(link.request(path: "/\(token)/Dune%252Em4b").utf8)),
            ("a query", Array(link.request(path: "/\(token)/Dune.m4b?download=1").utf8)),
            ("a whole address as the target", Array(link.request(path: "http://\(link.host)/\(token)/Dune.m4b").utf8)),
            ("POST", Array(link.request("POST").utf8)),
            ("PUT", Array(link.request("PUT").utf8)),
            ("DELETE", Array(link.request("DELETE").utf8)),
            ("OPTIONS", Array(link.request("OPTIONS").utf8)),
            ("a lower-case method", Array(link.request("get").utf8)),
            ("HTTP/0.9", Array("GET \(link.path)\r\n".utf8)),
            ("the HTTP/2 preface", Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)),
            ("HTTP/2 as the version", Array("GET \(link.path) HTTP/2.0\r\nHost: \(link.host)\r\n\r\n".utf8)),
            ("bare LF line endings", Array("GET \(link.path) HTTP/1.1\nHost: \(link.host)\n\n".utf8)),
            ("no line ending at all", Array("GET \(link.path) HTTP/1.1".utf8)),
            ("one CRLF too few", Array("GET \(link.path) HTTP/1.1\r\nHost: \(link.host)\r\n".utf8)),
            ("a NUL in the path", Array("GET \(link.path)".utf8) + [0] + Array(" HTTP/1.1\r\nHost: \(link.host)\r\n\r\n".utf8)),
            ("a NUL first", [0] + Array(good.utf8)),
            ("another host", Array("GET \(link.path) HTTP/1.1\r\nHost: evil.example\r\n\r\n".utf8)),
            ("no host", Array("GET \(link.path) HTTP/1.1\r\n\r\n".utf8)),
            ("a body", Array(link.request(headers: ["Content-Length: 4"]).utf8) + Array("body".utf8)),
            ("a request line over 8 KB", Array("GET /\(token)/\(String(repeating: "a", count: 20_000)) HTTP/1.1\r\nHost: \(link.host)\r\n\r\n".utf8)),
            ("a header block over 8 KB", Array(link.request(headers: ["X-Pad: " + String(repeating: "b", count: 20_000)]).utf8)),
            ("a megabyte of noise", [UInt8](repeating: 0x41, count: 1_000_000)),
            ("a TLS hello", [0x16, 0x03, 0x01, 0x00, 0x05, 0x01, 0x00, 0x00, 0x01, 0x00]),
            ("a good request after a bad one", Array(link.request(path: "/x").utf8) + Array(good.utf8)),
        ]
        for request in requests {
            let answer = try await LinkProbe.exchange(request.bytes, port: link.port)
            #expect(answer.isTheRefusal, "\(request.what): \(String(decoding: answer.raw.prefix(60), as: UTF8.self))")
            #expect(answer.body.isEmpty, "\(request.what)")
        }
        // The same when the caller does not say it has finished sending.
        for index in [0, 16, 22, 32, 33] {
            let answer = try await LinkProbe.exchange(requests[index].bytes, port: link.port, finish: false)
            #expect(answer.isTheRefusal, "\(requests[index].what), left open")
        }

        // None of it started a transfer, told anyone anything, or used the link up.
        await link.events.settle()
        #expect(link.events.all == [])
        #expect(link.server?.isServing == true)
        let answer = try await LinkProbe.exchange(good, port: link.port)
        #expect(Bytes(answer.raw) == Bytes(link.headers + link.bytes))
        await link.end()
    }

    @Test func ph2_urlSessionGetsAnEmpty404ForAWrongTokenOrName() async throws {
        let link = try Link()
        let session = session()
        defer { session.invalidateAndCancel() }
        for path in ["/wrong/Dune.m4b", "/\(link.offer.token)/Nope.m4b", "/", "/\(link.offer.token)/Dune.m4b/extra"] {
            let url = try #require(URL(string: "http://\(link.host)\(path)"))
            let (data, response) = try await session.data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 404, "\(path)")
            #expect(data.isEmpty, "\(path)")
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "0")
            #expect(http.allHeaderFields.count == 2, "\(http.allHeaderFields)")
        }
        // POST of the right address is still nothing.
        var post = URLRequest(url: link.offer.httpURL)
        post.httpMethod = "POST"
        post.httpBody = Data("x".utf8)
        let (data, response) = try await session.data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(data.isEmpty)
        await link.events.settle()
        #expect(link.events.all == [])
        await link.end()
    }

    @Test func ph2_atMostOneRequestIsServedOnAConnection() async throws {
        let link = try Link()
        // HEAD, then GET straight after it on the same connection: only the HEAD is answered.
        let both = link.request("HEAD") + link.request()
        let answer = try await LinkProbe.exchange(both, port: link.port, finish: false)
        #expect(answer.raw == link.headers)
        #expect(answer.closedCleanly)
        await link.events.settle()
        #expect(link.events.all == [])

        // GET twice: the file once, and nothing after it.
        let twice = try await LinkProbe.exchange(link.request() + link.request(), port: link.port)
        #expect(Bytes(twice.raw) == Bytes(link.headers + link.bytes))
        await link.end()
    }

    @Test func ph2_ph7_aRequestNotFinishedInTimeIsRefusedAndASilentCallerIsDropped() async throws {
        #expect(PhoneLinkServer.Settings().requestTimeout == 10)
        var settings = Link.patient
        settings.requestTimeout = 2
        let link = try Link(settings: settings)
        let clock = ContinuousClock()
        let request = Array(link.request().utf8)

        // Three callers at once. One says nothing: dropped, with nothing sent to it.
        let began = clock.now
        let silent = try #require(RawConnection(port: link.port))
        // One begins a request and stops: refused.
        let partial = try #require(RawConnection(port: link.port, sending: Array(request.prefix(60))))
        // One sends a good request too slowly, a byte at a time: the limit is on the
        // whole request, not on the gap between its bytes.
        let slow = try #require(RawConnection(port: link.port, sending: Array(request.prefix(1))))
        let sending = Task.detached {
            for byte in request.dropFirst() {
                guard !Task.isCancelled, await slow.send([byte]) else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(request.count > 80)

        async let nothing = silent.readToEnd()
        async let refused = partial.readToEnd()
        async let late = slow.readToEnd()
        let answers = await (nothing, refused, late)
        #expect(clock.now - began >= .milliseconds(1900))
        #expect(answers.0.bytes.isEmpty)
        #expect(RawAnswer(answers.1.bytes, closedCleanly: answers.1.closedCleanly).isTheRefusal)
        #expect(answers.2.bytes == PhoneLinkRequest.notFound)
        sending.cancel()
        _ = await sending.value
        silent.close()
        partial.close()
        slow.close()

        await link.events.settle()
        #expect(link.events.all == [])
        #expect(link.server?.isServing == true)
        await link.end()
    }

    // MARK: PH3 The file

    @Test func ph3_aGoodGetAnswersWithTheHeadersAndTheBytes() async throws {
        let link = try Link()
        let session = session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: link.offer.httpURL)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(Bytes(Array(data)) == Bytes(link.bytes))
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "10000")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(http.value(forHTTPHeaderField: "Content-Disposition")
            == "attachment; filename=\"Dune.m4b\"; filename*=UTF-8''Dune.m4b")
        #expect(http.suggestedFilename == "Dune.m4b")

        #expect(await link.events.wait(for: .finished))
        #expect(link.events.all == [.started(bytesTotal: 10_000), .progress(bytesSent: 10_000), .finished])
        await link.end()
    }

    @Test(arguments: ["Dune Messiah (Unabridged).zip", "say \"hi\" & go #1?.m4b", "名前 – Café 🎧.mp3", "100%2Fsure.m4b"])
    func ph3_ph9_aNameWithAwkwardCharactersIsFetchedThroughTheLink(name: String) async throws {
        let link = try Link(name: name)
        // What BookPlayer would fetch: everything after "url=", decoded once.
        let text = link.offer.bookPlayerLink.absoluteString
        let value = try #require(text.range(of: "url=").map { String(text[$0.upperBound...]) }?.removingPercentEncoding)
        let url = try #require(URL(string: value))
        #expect(url == link.offer.httpURL)

        let session = session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(Bytes(Array(data)) == Bytes(link.bytes))
        #expect(http.value(forHTTPHeaderField: "Content-Disposition") == PhoneLinkRequest.contentDisposition(name))
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    @Test func ph3_headGivesTheHeadersOnlyAndDoesNotUseTheLinkUp() async throws {
        let link = try Link()
        let session = session()
        defer { session.invalidateAndCancel() }
        var head = URLRequest(url: link.offer.httpURL)
        head.httpMethod = "HEAD"
        let (data, response) = try await session.data(for: head)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(data.isEmpty)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "10000")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")

        let raw = try await LinkProbe.exchange(link.request("HEAD"), port: link.port)
        #expect(raw.raw == link.headers)
        let part = try await LinkProbe.exchange(link.request("HEAD", headers: ["Range: bytes=4000-"]), port: link.port)
        #expect(part.statusLine == "HTTP/1.1 206 Partial Content")
        #expect(part.headers["content-length"] == "6000")
        #expect(part.body.isEmpty)

        await link.events.settle()
        #expect(link.events.all == [])
        #expect(link.server?.isServing == true)
        await link.end()
    }

    @Test func ph3_theFileIsReadAndSentAPieceAtATime() async throws {
        var settings = Link.patient
        settings.chunkBytes = 1000
        let link = try Link(bytes: LinkProbe.contents(10_500), settings: settings)
        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(Bytes(answer.raw) == Bytes(link.headers + link.bytes))
        #expect(await link.events.wait(for: .finished))

        // Eleven pieces: ten of a thousand bytes and the rest.
        var expected: [PhoneLinkEvent] = [.started(bytesTotal: 10_500)]
        expected += (1...10).map { .progress(bytesSent: Int64($0) * 1000) }
        expected += [.progress(bytesSent: 10_500), .finished]
        #expect(link.events.all == expected)
        #expect(PhoneLinkServer.Settings().chunkBytes == 262_144)
        await link.end()
    }

    @Test func ph3_noMoreIsReadThanTheCallerTakes() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let total = Int64(link.bytes.count)
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        #expect(await readHead(connection).hasPrefix("HTTP/1.1 200 OK\r\n"))
        let first = await connection.read(1_048_576)
        #expect(Bytes(first) == Bytes(Array(link.bytes[0..<1_048_576])))

        // The caller stops reading. The server stops too, well short of the end: what
        // it reports as sent is what the connection took, not what the file holds.
        func reported() -> Int64 {
            link.events.all.compactMap { if case .progress(let sent) = $0 { sent } else { nil } }.max() ?? 0
        }
        // Wait until what is reported has stood still for half a second.
        var paused: Int64 = -1
        for _ in 0..<40 where reported() != paused || paused < 1_048_576 {
            paused = reported()
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(reported() == paused)
        #expect(paused >= 1_048_576)
        #expect(paused < total)
        #expect(!link.events.all.contains(.finished))

        // It goes on when the caller does.
        let rest = await connection.readToEnd()
        #expect(rest.closedCleanly)
        #expect(rest.bytes.count == link.bytes.count - 1_048_576)
        #expect(Bytes(rest.bytes) == Bytes(Array(link.bytes[1_048_576...])))
        connection.close()
        #expect(await link.events.wait(for: .finished))
        #expect(reported() == total)
        // Progress only ever goes forward, and is said about once for each hundredth.
        let progress = link.events.all.compactMap { if case .progress(let sent) = $0 { sent } else { nil } }
        #expect(progress == progress.sorted())
        #expect(progress.count <= 101)
        await link.end()
    }

    @Test func ph3_aRangeFromAnOffsetToTheEndIsHonouredWith206() async throws {
        let link = try Link()
        let session = session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: link.offer.httpURL)
        request.setValue("bytes=4000-", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(Bytes(Array(data)) == Bytes(Array(link.bytes[4000...])))
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 4000-9999/10000")
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "6000")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")

        // The last byte alone.
        let last = try await LinkProbe.exchange(link.request(headers: ["Range: bytes=9999-"]), port: link.port)
        #expect(last.statusLine == "HTTP/1.1 206 Partial Content")
        #expect(last.body == [link.bytes[9999]])

        // A part from the middle on, with nothing before it, is not the whole file: the link goes on.
        #expect(await link.events.wait(for: .interrupted))
        #expect(!link.events.all.contains(.finished))
        #expect(link.server?.isServing == true)
        await link.end()
    }

    @Test func ph3_otherFormsOfRangeGetTheWholeFile() async throws {
        for range in ["bytes=0-99", "bytes=-100", "bytes=10000-", "bytes=0-0,100-", "lines=5-"] {
            let link = try Link()
            let answer = try await LinkProbe.exchange(link.request(headers: ["Range: \(range)"]), port: link.port)
            #expect(Bytes(answer.raw) == Bytes(link.headers + link.bytes), "\(range)")
            #expect(await link.events.wait(for: .finished))
            await link.end()
        }
    }

    @Test func ph3_anEmptyFileIsServedAndEndsTheLink() async throws {
        let link = try Link(bytes: [])
        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(answer.statusLine == "HTTP/1.1 200 OK")
        #expect(answer.headers["content-length"] == "0")
        #expect(answer.body.isEmpty)
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    // MARK: PH4 One complete transfer ends the link

    @Test func ph4_oneCompleteTransferEndsTheLink() async throws {
        let link = try Link()
        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(Bytes(answer.raw) == Bytes(link.headers + link.bytes))

        #expect(await link.events.wait(for: .finished))
        // By the time it is reported, nothing is listening: no waiting for it here.
        #expect(RawConnection(port: link.port) == nil)
        #expect(link.server?.isServing == false)
        #expect(await LinkProbe.portIsClosed(link.port))
        await link.events.settle()
        #expect(link.events.all.last == .finished)
        #expect(link.events.all.filter { $0 == .finished }.count == 1)
        // Its time running out afterwards says nothing more.
        link.timers.fire(0)
        await link.events.settle()
        #expect(link.events.all.last == .finished)
        #expect(!link.events.all.contains(.expired))
        await link.end()
    }

    @Test func ph4_anInterruptedTransferDoesNotEndTheLinkAndTheRestCanBeFetched() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        #expect(await readHead(connection).hasPrefix("HTTP/1.1 200 OK\r\n"))
        let got = await connection.read(1_500_000)
        #expect(Bytes(got) == Bytes(Array(link.bytes[0..<1_500_000])))
        // The phone goes out of range.
        connection.abort()

        #expect(await link.events.wait(for: .interrupted))
        #expect(!link.events.all.contains(.finished))
        #expect(link.server?.isServing == true)
        #expect(link.events.all.first == .started(bytesTotal: Int64(link.bytes.count)))

        // It tries again from where it had got to.
        let again = try #require(RawConnection(port: link.port))
        await again.send(link.request(headers: ["Range: bytes=1500000-"]))
        let head = await readHead(again)
        #expect(head.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(head.contains("Content-Range: bytes 1500000-\(link.bytes.count - 1)/\(link.bytes.count)\r\n"))
        let rest = await again.readToEnd()
        #expect(Bytes(rest.bytes) == Bytes(Array(link.bytes[1_500_000...])))
        again.close()

        // The two together reached the end: that is the file.
        #expect(await link.events.wait(for: .finished))
        #expect(link.server?.isServing == false)
        #expect(link.events.all.filter { if case .started = $0 { true } else { false } }.count == 2)
        await link.end()
    }

    @Test func ph4_aCallerThatCutsTheConnectionInsteadOfClosingItHasNotFinished() async throws {
        let link = try Link()
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        // Every byte arrives, and then the connection is cut, not closed: from the Mac's
        // side this is no different from the last of them never having arrived.
        let got = await connection.read(link.bytes.count)
        #expect(Bytes(got) == Bytes(link.bytes))
        connection.abort()

        #expect(await link.events.wait(for: .interrupted))
        #expect(!link.events.all.contains(.finished))
        #expect(link.server?.isServing == true)
        // Fetched again and closed properly, it is done.
        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(Bytes(answer.body) == Bytes(link.bytes))
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    @Test func ph4_afterAnInterruptedTransferTheWholeFileCanBeFetchedAgain() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        _ = await connection.read(100_000)
        connection.close()
        #expect(await link.events.wait(for: .interrupted))
        #expect(link.server?.isServing == true)

        let session = session()
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: link.offer.httpURL)
        #expect(Bytes(Array(data)) == Bytes(link.bytes))
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    @Test func ph4_aPartThatDoesNotJoinWhatWasSentBeforeDoesNotEndTheLink() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        _ = await connection.read(100_000)
        connection.abort()
        #expect(await link.events.wait(for: .interrupted))

        // The end of the file, leaving a gap after what the first caller was sent.
        let from = link.bytes.count - 1000
        let tail = try await LinkProbe.exchange(link.request(headers: ["Range: bytes=\(from)-"]), port: link.port)
        #expect(Bytes(tail.body) == Bytes(Array(link.bytes[from...])))
        #expect(await link.events.wait { _ in link.events.all.filter { $0 == .interrupted }.count == 2 })
        #expect(!link.events.all.contains(.finished))
        #expect(link.server?.isServing == true)
        await link.end()
    }

    // MARK: PH5 Expiry

    @Test func ph5_atItsExpiryTheLinkStopsAndSaysSo() async throws {
        let link = try Link()
        #expect(link.timers.delays == [PhoneLinkText.lifetime])
        #expect(PhoneLinkText.lifetime == 600)
        #expect(link.offer.expiresAt.timeIntervalSince(Link.now) == 600)

        link.timers.fire(0)

        #expect(await link.events.wait(for: .expired))
        #expect(RawConnection(port: link.port) == nil)
        #expect(link.events.all == [.expired])
        #expect(link.server?.isServing == false)
        #expect(await LinkProbe.portIsClosed(link.port))
        await link.end()
    }

    @Test func ph5_aTransferInProgressAtExpiryIsAllowedToFinish() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        let first = await connection.read(1_048_576)
        // Others are waiting on the link too; they have not asked for anything yet.
        let idle = try #require(RawConnection(port: link.port))

        link.timers.fire(0)

        // Nothing new is accepted, and whoever was only waiting is dropped.
        #expect(await LinkProbe.portIsClosed(link.port))
        #expect(await idle.readToEnd().bytes.isEmpty)
        idle.close()
        await link.events.settle()
        #expect(!link.events.all.contains(.expired))
        #expect(link.server?.isServing == true)

        // The transfer runs to its end.
        let rest = await connection.readToEnd()
        #expect(Bytes(first + rest.bytes) == Bytes(link.bytes))
        connection.close()
        #expect(await link.events.wait(for: .finished))
        await link.events.settle()
        #expect(!link.events.all.contains(.expired))
        #expect(link.server?.isServing == false)
        await link.end()
    }

    @Test func ph5_aTransferThatFailsAfterExpiryLeavesTheLinkExpired() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        _ = await connection.read(1_048_576)

        link.timers.fire(0)
        #expect(await LinkProbe.portIsClosed(link.port))
        connection.abort()

        #expect(await link.events.wait(for: .expired))
        await link.events.settle()
        #expect(link.events.all.last == .expired)
        #expect(!link.events.all.contains(.finished))
        #expect(!link.events.all.contains(.interrupted))
        #expect(link.server?.isServing == false)
        await link.end()
    }

    @Test func ph5_theExpiryOfAnEarlierLinkDoesNotEndALaterOne() async throws {
        let link = try Link()
        try link.restart()
        #expect(link.timers.delays == [600, 600])

        link.timers.fire(0)
        await link.events.settle()
        #expect(link.events.all == [])
        #expect(link.server?.isServing == true)
        #expect(try await LinkProbe.exchange(link.request("HEAD"), port: link.port).raw == link.headers)

        link.timers.fire(1)
        #expect(await link.events.wait(for: .expired))
        await link.end()
    }

    // MARK: PH6 Stopping

    @Test func ph6_stopEndsEverythingAtOnceIncludingATransferInProgress() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        let first = await connection.read(1_048_576)
        let idle = try #require(RawConnection(port: link.port))
        #expect(await link.events.wait { if case .progress = $0 { true } else { false } })
        await link.events.settle()
        let before = link.events.all

        link.server?.stop()

        // At once: nothing accepts any more by the time stop returns.
        #expect(RawConnection(port: link.port) == nil)
        #expect(link.server?.isServing == false)
        let rest = await connection.readToEnd()
        #expect(first.count + rest.bytes.count < link.bytes.count)
        #expect(await idle.readToEnd().bytes.isEmpty)
        connection.close()
        idle.close()
        // And nothing more is reported: not that it was cut short, not that it ended.
        await link.events.settle()
        #expect(link.events.all == before)
        #expect(!before.contains { $0.endsLink || $0 == .interrupted })

        // Safe to call again, and again once the time runs out.
        link.server?.stop()
        link.timers.fire(0)
        link.server?.stop()
        await link.events.settle()
        #expect(link.events.all == before)
        await link.end()
    }

    @Test func ph6_stopBeforeAnythingAndTwiceIsSafe() async throws {
        let server = PhoneLinkServer(addresses: { ["127.0.0.1"] }, schedule: LinkTimers().schedule)
        server.stop()
        server.stop()
        #expect(!server.isServing)

        let link = try Link()
        link.server?.stop()
        #expect(RawConnection(port: link.port) == nil)
        link.server?.stop()
        // A stopped server starts again.
        try link.restart()
        #expect(link.server?.isServing == true)
        #expect(Bytes(try await LinkProbe.exchange(link.request(), port: link.port).body) == Bytes(link.bytes))
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    @Test func ph6_releasingTheServerStopsIt() async throws {
        let link = try Link(bytes: largeContents(megabytes: 32))
        let connection = try #require(RawConnection(port: link.port))
        await connection.send(link.request())
        _ = await readHead(connection)
        let first = await connection.read(1_048_576)

        link.server = nil

        #expect(await LinkProbe.portIsClosed(link.port))
        let rest = await connection.readToEnd()
        #expect(first.count + rest.bytes.count < link.bytes.count)
        connection.close()
        await link.events.settle()
        #expect(!link.events.all.contains { $0.endsLink || $0 == .interrupted })
        await link.end()
    }

    @Test func ph6_nothingIsLeftListeningAfterAFailure() async throws {
        let link = try Link()
        // The file is cut short under the server: the same file, so it sees it.
        let handle = try FileHandle(forWritingTo: link.file)
        try handle.truncate(atOffset: 100)
        try handle.close()

        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(answer.body.count < link.bytes.count)
        #expect(await link.events.wait(for: .failed("The file changed while it was being sent.")))
        #expect(RawConnection(port: link.port) == nil)
        #expect(link.events.all == [.started(bytesTotal: 10_000), .failed("The file changed while it was being sent.")])
        #expect(link.server?.isServing == false)
        await link.end()
    }

    // MARK: PH7 Connections

    @Test func ph7_atMostFourConnectionsAtATime() async throws {
        let link = try Link()
        #expect(PhoneLinkServer.Settings().maxConnections == 4)

        var waiting: [RawConnection] = []
        for _ in 0..<4 { waiting.append(try #require(RawConnection(port: link.port))) }

        // A fifth is turned away without a word, even with a good request.
        for _ in 0..<3 {
            if let fifth = RawConnection(port: link.port) {
                await fifth.send(link.request())
                #expect(await fifth.readToEnd().bytes.isEmpty)
                fifth.close()
            }
        }
        await link.events.settle()
        #expect(link.events.all == [])

        // The four are still served: the first of them asks now.
        await waiting[0].send(link.request("HEAD"))
        let head = await waiting[0].readToEnd()
        #expect(head.bytes == link.headers)
        waiting[0].close()

        // With one gone there is room again.
        var served = false
        for _ in 0..<200 where !served {
            if let next = RawConnection(port: link.port) {
                await next.send(link.request("HEAD"))
                served = await next.readToEnd().bytes == link.headers
                next.close()
            }
            if !served { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(served)
        waiting.forEach { $0.close() }
        await link.end()
    }

    // MARK: PH10 The one file

    @Test func ph10_aLinkPutInTheFilesPlaceAfterStartIsNotFollowed() async throws {
        let link = try Link()
        let secret = link.folder.appendingPathComponent("secret.txt")
        try Data("something else entirely".utf8).write(to: secret)
        try FileManager.default.removeItem(at: link.file)
        try FileManager.default.createSymbolicLink(at: link.file, withDestinationURL: secret)

        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(Bytes(answer.raw) == Bytes(link.headers + link.bytes))
        #expect(await link.events.wait(for: .finished))
        await link.end()
    }

    @Test func ph10_anotherFilePutInItsPlaceAfterStartIsNotServed() async throws {
        let link = try Link()
        let other = link.folder.appendingPathComponent("other.bin")
        try Data(LinkProbe.contents(20_000).reversed()).write(to: other)
        _ = try FileManager.default.replaceItemAt(link.file, withItemAt: other)

        let answer = try await LinkProbe.exchange(link.request(), port: link.port)
        #expect(Bytes(answer.raw) == Bytes(link.headers + link.bytes))
        await link.end()
    }

    @Test func ph10_onlyAPlainFileCanBeServed() async throws {
        let folder = try makeTempDir()
        let real = try touch(folder.appendingPathComponent("real.m4b"), "audio")
        let link = folder.appendingPathComponent("link.m4b")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let timers = LinkTimers()
        let server = PhoneLinkServer(addresses: { ["127.0.0.1"] }, schedule: timers.schedule)

        for file in [link, folder, folder.appendingPathComponent("missing.m4b")] {
            #expect(throws: PhoneLinkError.fileUnreadable) {
                try server.start(file: file, fileName: "a.m4b", now: Link.now) { _ in }
            }
            #expect(!server.isServing)
        }
        #expect(timers.delays == [])
        // The file itself is served, and is not changed by it.
        let offer = try server.start(file: real, fileName: "a.m4b", now: Link.now) { _ in }
        let request = "GET /\(offer.token)/a.m4b HTTP/1.1\r\nHost: 127.0.0.1:\(offer.port)\r\n\r\n"
        #expect(try await LinkProbe.exchange(request, port: offer.port).body == Array("audio".utf8))
        #expect(try String(contentsOf: real, encoding: .utf8) == "audio")
        server.stop()
        #expect(await LinkProbe.portIsClosed(offer.port))
    }
}

/// The stand-in that the app model's tests use behaves as the server does where they rely on it.
@MainActor
@Suite struct FakePhoneLinkingTests {
    @Test func theFakeOffersALinkAndReportsWhatATestFires() throws {
        let fake = FakePhoneLinking()
        var events: [PhoneLinkEvent] = []
        let file = URL(fileURLWithPath: "/tmp/nowhere/Dune.m4b")
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(!fake.isServing)

        let offer = try fake.start(file: file, fileName: "Dune.m4b", now: now) { events.append($0) }
        #expect(fake.isServing)
        #expect(fake.offer == offer)
        #expect(fake.starts == [FakePhoneLinking.Start(file: file, fileName: "Dune.m4b", now: now)])
        #expect(offer.httpURL.absoluteString == "http://192.168.1.20:50123/fake-token-1/Dune.m4b")
        #expect(offer.bookPlayerLink == PhoneLinkText.bookPlayerLink(for: offer.httpURL))
        #expect(offer.expiresAt == now.addingTimeInterval(600))

        fake.fire(.started(bytesTotal: 10))
        fake.fire(.progress(bytesSent: 4))
        fake.fire(.interrupted)
        #expect(fake.isServing)
        fake.fire(.finished)
        #expect(!fake.isServing)
        fake.fire(.expired)
        #expect(events == [.started(bytesTotal: 10), .progress(bytesSent: 4), .interrupted, .finished])

        // Stopped, it reports nothing more; a new link has another token.
        let second = try fake.start(file: file, fileName: "Dune.m4b", now: now) { events.append($0) }
        #expect(second.token != offer.token)
        fake.stop()
        fake.fire(.failed("x"))
        #expect(!fake.isServing)
        #expect(fake.stopCount == 1)
        #expect(events.count == 4)

        fake.startError = PhoneLinkError.noLocalAddress
        #expect(throws: PhoneLinkError.noLocalAddress) {
            try fake.start(file: file, fileName: "Dune.m4b", now: now) { _ in }
        }
        #expect(!fake.isServing)
        #expect(fake.starts.count == 2)
    }
}

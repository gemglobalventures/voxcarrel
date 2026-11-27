import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// A request made of Readwise for an extension: with the owner's token, to Readwise only.
@MainActor
@Suite struct AskReadwiseTests {
    @Test func theTokenIsPutOnTheRequestAndNothingIsSentWithoutOne() async throws {
        let h = try await Harness.demo()
        // No token kept: nothing is sent.
        #expect(try await h.model.askReadwise(path: "/api/v2/highlights/", method: "POST", body: Data("{}".utf8)) == nil)
        #expect(h.audible.asked.isEmpty)

        try h.readwiseTokens.save("abc123")
        h.audible.answer("/api/v2/highlights", with: [["id": 1]])
        let answer = try #require(try await h.model.askReadwise(path: "/api/v2/highlights/", method: "POST", body: Data("{}".utf8)))
        #expect(answer.status == 200)
        let request = try #require(h.audible.asked.last)
        #expect(request.url?.absoluteString == "https://readwise.io/api/v2/highlights/" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token abc123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json" && request.httpBody == Data("{}".utf8))

        // Not a path of the API, or one that leads to another host: nothing is sent.
        #expect(try await h.model.askReadwise(path: "/accounts/") == nil)
        #expect(try await h.model.askReadwise(path: "@example.com/api/") == nil)
        #expect(h.audible.asked.count == 1)
    }
}

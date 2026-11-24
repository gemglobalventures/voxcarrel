import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// G29–G33: Fill in Genres, as its sheet's state decides it.
@MainActor
@Suite struct GenreFillSessionTests {
    /// What Audible has: Dune as the book itself, Emma under another title and author,
    /// and nothing for anything else.
    private func stock(_ lookup: FakeLookup) {
        lookup.search(.audible) { query in
            switch query.title {
            case "Dune":
                return [
                    foundBook(.audible, "us:B1", title: "Dune", authors: ["Frank Herbert"]) {
                        $0.genres = ["Science Fiction", "Classics"]
                        $0.genreSource = "Science Fiction & Fantasy > Science Fiction; Literature & Fiction > Classics"
                        $0.publisher = "Somebody Else's Audio"
                    }
                ]
            case "Emma":
                return [
                    foundBook(.audible, "us:B2", title: "Emma and Her Friends", authors: ["Jane Austin"]) {
                        $0.genres = ["Romance"]
                        $0.genreSource = "Romance"
                    }
                ]
            default:
                return []
            }
        }
    }

    /// The session, begun and looked up to the end.
    private func reviewed(_ h: Harness) async throws -> GenreFillSession {
        await h.model.beginGenreFill()
        let session = try #require(h.model.genreFill)
        session.start()
        await session.lookingUp?.value
        return session
    }

    private func row(_ session: GenreFillSession, _ title: String) throws -> GenreFillRow {
        try #require(session.rows.first { $0.title == title }, "no row for \(title)")
    }

    // MARK: G29 Which books

    @Test func GH29_itCoversBooksWithNoGenreAndASwitchAddsThoseWithOnlyAGeneralOne() async throws {
        let h = try await Harness.demo()
        #expect(h.model.canFillInGenres)
        await h.model.beginGenreFill()
        let session = try #require(h.model.genreFill)
        #expect(session.title == "Fill in Genres")
        #expect(session.phase == .ready)
        // Off to begin with.
        #expect(!session.includesGeneral)
        #expect(session.includesGeneralTitle == "Also books with only a general genre")
        #expect(session.candidateCount == 1)
        #expect(session.candidateText == "1 book has no genre.")
        #expect(session.canStart)
        #expect(session.startTitle == "Look Up")

        // Literary & General alone says little: two more books.
        session.includesGeneral = true
        #expect(session.candidateCount == 3)
        #expect(session.candidateText == "3 books have no genre, or only a general one.")
        session.includesGeneral = false
        #expect(session.candidateCount == 1)
        // Nothing has been asked of anyone yet.
        #expect(h.lookup.asked.isEmpty)
        #expect(session.rows.isEmpty)

        session.cancel()
        #expect(h.model.genreFill == nil)
    }

    @Test func GH29_aGenreInOtherIsAGeneralOneToo() async throws {
        let h = try await fillLibrary()
        try await h.give("Pub Quiz", in: .other, to: ["Dune"])
        await h.model.beginGenreFill()
        let session = try #require(h.model.genreFill)
        #expect(session.candidateCount == 2)
        #expect(session.candidateText == "2 books have no genre.")
        session.includesGeneral = true
        #expect(session.candidateCount == 3)
    }

    @Test func GH29_withNoBookToFillInThereIsNothingToStart() async throws {
        let h = try await Harness.demo()
        try await h.select("Voices from the Attic")
        h.model.addDraftGenre("Horror")
        await h.model.save()
        await h.model.beginGenreFill()
        let session = try #require(h.model.genreFill)
        #expect(session.candidateCount == 0)
        #expect(session.candidateText == "Every book has a genre.")
        #expect(!session.canStart)
        session.start()
        #expect(session.phase == .ready)
        #expect(session.lookingUp == nil)
    }

    // MARK: G32 The review list

    @Test func GH32_eachBookIsListedWithWhatWasFoundAndATick() async throws {
        let h = try await fillLibrary()
        let undoBefore = h.model.undoLabel
        stock(h.lookup)
        let session = try await reviewed(h)
        #expect(session.phase == .review)
        #expect(session.rows.map(\.title) == ["Dune", "Emma", "Zen Gardens"])
        #expect(session.rows.map(\.author) == ["Frank Herbert", "Jane Austen", "Ann Lee"])

        // Surely the book: ticked.
        let dune = try row(session, "Dune")
        #expect(dune.genres == ["Science Fiction", "Classics"])
        #expect(dune.sourceText == "Audible")
        #expect(dune.isTicked)
        #expect(dune.canTick)
        #expect(dune.note == nil)

        // Found by title and author, and not surely the book: not ticked, with what was found.
        let emma = try row(session, "Emma")
        #expect(emma.genres == ["Romance"])
        #expect(!emma.isTicked)
        #expect(emma.canTick)
        #expect(emma.note == "Found as \"Emma and Her Friends\" by Jane Austin — check before ticking")

        let zen = try row(session, "Zen Gardens")
        #expect(zen.genres.isEmpty)
        #expect(zen.note == "Nothing found")
        #expect(zen.sourceText == nil)
        #expect(!zen.isTicked)
        #expect(!zen.canTick)

        #expect(session.tickedCount == 1)
        #expect(session.summary == "Genres found for 2 of 3 books.")
        #expect(session.applyTitle == "Apply to 1 Book")
        #expect(session.canApply)
        // G33: nothing changes until Apply.
        #expect(try h.store().books().allSatisfy { $0.genres.isEmpty })
        #expect(h.model.undoLabel == undoBefore)
    }

    @Test func GH32_aBookFoundWithoutAnAuthorIsShownWithItsTitleOnly() async throws {
        let h = try await fillLibrary()
        h.lookup.find(.audible, [foundBook(.audible, "us:B9", title: "Some Dune") { $0.genres = ["History"] }])
        let session = try await reviewed(h)
        #expect(try row(session, "Dune").note == "Found as \"Some Dune\" — check before ticking")
    }

    @Test func GH32_aSourceThatAnsweredWithAnErrorIsSaidWithItsReason() async throws {
        let h = try await fillLibrary()
        h.lookup.fail(.audible, .refused(status: 503))
        h.lookup.fail(.openLibrary, .unreadable)
        let session = try await reviewed(h)
        let dune = try row(session, "Dune")
        #expect(dune.note == "Could not be looked up. The lookup service answered with an error.")
        #expect(!dune.canTick)
        #expect(!dune.isTicked)
        #expect(session.summary == "Genres found for 0 of 3 books.")
        #expect(!session.canApply)
    }

    @Test func GH32_aTickCanBeChangedOnlyWhereThereAreGenresToGive() async throws {
        let h = try await fillLibrary()
        stock(h.lookup)
        let session = try await reviewed(h)
        let ids = Dictionary(uniqueKeysWithValues: session.rows.map { ($0.title, $0.id) })

        session.setTicked(true, for: try #require(ids["Emma"]))
        session.setTicked(true, for: try #require(ids["Zen Gardens"]))
        #expect(session.rows.map(\.isTicked) == [true, true, false])
        #expect(session.applyTitle == "Apply to 2 Books")

        // GH33: Apply is disabled with nothing ticked.
        session.setTicked(false, for: try #require(ids["Emma"]))
        session.setTicked(false, for: try #require(ids["Dune"]))
        #expect(session.tickedCount == 0)
        #expect(!session.canApply)
        #expect(session.applyTitle == "Apply")
        await session.apply()
        #expect(h.model.genreFill != nil)
        #expect(try h.store().books().allSatisfy { $0.genres.isEmpty })
    }

    @Test func GH32_aProposalsGenresCanBeTakenAwayBeforeApplying() async throws {
        let h = try await fillLibrary()
        stock(h.lookup)
        let session = try await reviewed(h)
        let dune = try row(session, "Dune").id
        session.removeGenre("classics", from: dune)
        #expect(try row(session, "Dune").genres == ["Science Fiction"])
        #expect(try row(session, "Dune").isTicked)

        // With no genre left there is nothing to give the book.
        session.removeGenre("Science Fiction", from: dune)
        #expect(try row(session, "Dune").genres.isEmpty)
        #expect(!(try row(session, "Dune").isTicked))
        #expect(!(try row(session, "Dune").canTick))
        #expect(!session.canApply)
    }

    // MARK: G33 Applying and stopping

    @Test func GH33_applyGivesTheTickedBooksTheirGenresAsOneUndoableOperation() async throws {
        let h = try await fillLibrary()
        stock(h.lookup)
        let session = try await reviewed(h)
        session.setTicked(true, for: try row(session, "Emma").id)
        session.removeGenre("Classics", from: try row(session, "Dune").id)
        h.recordBusyLabels()
        await session.apply()

        #expect(h.busyLabels == ["Filling in genres…"])
        #expect(h.model.genreFill == nil)
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        let dune = try h.book(try h.id("Dune"))
        #expect(dune.genres == ["Science Fiction"])
        #expect(dune.genreSource == "Science Fiction & Fantasy > Science Fiction; Literature & Fiction > Classics")
        // G31: nothing else is taken from what was found.
        #expect(dune.publisher == nil)
        let emma = try h.book(try h.id("Emma"))
        #expect(emma.genres == ["Romance"])
        #expect(emma.title == "Emma")
        #expect(emma.authors == ["Jane Austen"])
        #expect(try h.book(try h.id("Zen Gardens")).genres.isEmpty)
        // G33: their files are written as a save writes them.
        #expect(try h.genreTag("Dune") == "Science Fiction")
        #expect(try h.genreTag("Emma") == "Romance")
        #expect(h.model.genreFilesToUpdate == 0)
        #expect(h.model.noGenreCount == 1)
        #expect(h.model.undoLabel == "Fill in genres for 2 books")

        await h.model.undo()
        #expect(try h.store().books().allSatisfy { $0.genres.isEmpty })
        #expect(try h.genreTag("Dune") == nil)
    }

    @Test func GH33_theProgressSaysWhichBookIsBeingLookedUpAndStopKeepsWhatWasFound() async throws {
        let h = try await fillLibrary()
        let gate = Gate()
        h.lookup.search(.audible) { query in
            if query.title == "Emma" { await gate.wait() }
            return query.title == "Dune"
                ? [foundBook(.audible, "us:B1", title: "Dune", authors: ["Frank Herbert"]) { $0.genres = ["Science Fiction"] }]
                : []
        }
        await h.model.beginGenreFill()
        let session = try #require(h.model.genreFill)
        session.start()
        // GH-d
        #expect(session.progressText == "Looking up 1 of 3…")
        #expect(session.phase == .lookingUp)
        #expect(!session.canApply)
        // The switch is for before the lookups begin.
        session.includesGeneral = true
        #expect(!session.includesGeneral)

        await gate.arrival()
        #expect(session.progressText == "Looking up 2 of 3…")
        #expect(session.rows.map(\.title) == ["Dune"])
        #expect(session.canStop)

        session.stop()
        await gate.release()
        await session.lookingUp?.value
        #expect(session.phase == .review)
        #expect(session.progressText == nil)
        #expect(!session.canStop)
        // What was found so far is shown, and can be applied.
        #expect(session.rows.map(\.title) == ["Dune"])
        #expect(session.summary == "Stopped after 1 of 3 books. Genres found for 1 of 1 book.")
        #expect(session.canApply)
        // The third book was never asked about.
        #expect(!h.lookup.asked.contains { $0.query.title == "Zen Gardens" })

        await session.apply()
        #expect(try h.book(try h.id("Dune")).genres == ["Science Fiction"])
    }

    @Test func GH30_withoutTheNetworkItSaysSoAndChangesNothing() async throws {
        let h = try await fillLibrary()
        let undoBefore = h.model.undoLabel
        h.lookup.fail(.audible, .notReachable)
        let session = try await reviewed(h)
        #expect(
            session.problem
                == "Genres could not be looked up because the lookup service could not be reached. Check your "
                + "internet connection. Nothing was changed.")
        #expect(session.problem == UserMessage.genreFillNotReachable)
        #expect(session.rows.isEmpty)
        #expect(session.phase == .ready)
        #expect(!session.canApply)
        #expect(session.canStart)
        #expect(try h.store().books().allSatisfy { $0.genres.isEmpty })
        #expect(h.model.undoLabel == undoBefore)
        #expect(h.model.alert == nil)

        // Trying again, with the network back, takes the sentence away.
        stock(h.lookup)
        session.start()
        await session.lookingUp?.value
        #expect(session.problem == nil)
        #expect(session.rows.count == 3)
    }

    @Test func GH30_aBookWithAnAudibleIDIsLookedUpByItAndTicked() async throws {
        let h = try await fillLibrary()
        let id = try await h.select("Emma")
        h.model.updateDraft { $0.asin = "B0EMMA0001" }
        await h.model.save()
        h.lookup.search(.audible) { query in
            guard query.asin == "B0EMMA0001" else { return [] }
            return [
                foundBook(.audible, "us:B0EMMA0001", title: "Emma (Dramatised)", authors: ["J. Austen"]) {
                    $0.asin = "B0EMMA0001"
                    $0.genres = ["Classics"]
                }
            ]
        }
        let session = try await reviewed(h)
        let emma = try row(session, "Emma")
        #expect(emma.id == id)
        #expect(emma.isTicked)
        #expect(emma.note == nil)
        #expect(emma.genres == ["Classics"])
    }

    @Test func GH32_whatIsProposedIsNamedAsTheLibraryNamesIt() async throws {
        let h = try await fillLibrary()
        try await h.rename("Science Fiction", to: "Space Books")
        stock(h.lookup)
        let session = try await reviewed(h)
        #expect(try row(session, "Dune").genres == ["Space Books", "Classics"])
    }

    @Test func GH29_closingTheSheetWhileItLooksUpStopsItAndAppliesNothing() async throws {
        let h = try await fillLibrary()
        let gate = Gate()
        h.lookup.hold(.audible, at: gate)
        await h.model.beginGenreFill()
        let session = try #require(h.model.genreFill)
        session.start()
        await gate.arrival()
        let lookingUp = session.lookingUp
        session.cancel()
        #expect(h.model.genreFill == nil)
        await gate.release()
        await lookingUp?.value
        #expect(session.rows.isEmpty)
        #expect(try h.store().books().allSatisfy { $0.genres.isEmpty })
    }
}

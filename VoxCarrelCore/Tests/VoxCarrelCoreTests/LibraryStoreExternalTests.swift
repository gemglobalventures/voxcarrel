import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Plan 6, Task 1: external copies on a book (rules M1–M5).
@Suite struct LibraryStoreExternalTests {
    func makeStore() throws -> LibraryStore {
        try LibraryStore(libraryRoot: makeTempDir())
    }

    let audible = ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B08G9PRS1K")

    func book(_ title: String, copies: [ExternalCopy] = []) -> Book {
        var book = Book(metadata: BookMetadata(title: title, authors: ["Ann Author"]))
        book.externalCopies = copies
        return book
    }

    func audioFile(_ name: String) -> BookFile {
        BookFile(path: "Ann Author/\(name)/\(name).m4b", format: .m4b, role: .audio, position: 0)
    }

    func ebookFile(_ name: String) -> BookFile {
        BookFile(path: "Ann Author/\(name)/\(name).epub", format: .epub, role: .ebook, position: 0)
    }

    func extraFile(_ name: String) -> BookFile {
        BookFile(path: "Ann Author/\(name)/Extras/Map.pdf", format: .pdf, role: .extra, position: 0)
    }

    func storedText(_ id: Int64, in store: LibraryStore) throws -> String? {
        try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT externalCopies FROM book WHERE id = ?", arguments: [id])
        }
    }

    // MARK: The model

    @Test func kindsHaveTitles() {
        #expect(ExternalKind.allCases == [.audible, .kindle])
        #expect(ExternalKind.kindle.title == "Kindle" && ExternalKind.kindle.rawValue == "kindle")
        #expect(ExternalKind.audible.title == "Audible")
        #expect(ExternalKind.audible.rawValue == "audible")
    }

    @Test func aNewBookIsNotOwnedElsewhere() {
        let plain = book("Plain")
        #expect(plain.externalCopies.isEmpty)
        #expect(plain.isOwnedElsewhere == false)
        #expect(plain.isOwned(on: .audible) == false)

        let owned = book("Owned", copies: [audible])
        #expect(owned.isOwnedElsewhere)
        #expect(owned.isOwned(on: .audible))
    }

    @Test func aCopyRoundTripsThroughTheDatabase() throws {
        let store = try makeStore()
        let bare = ExternalCopy(kind: .audible, form: .ebook)
        let id = try #require(try store.insert(book("Owned", copies: [audible, bare]), files: []).id)

        let fetched = try #require(try store.book(id: id))
        #expect(fetched.externalCopies == [audible, bare])
        #expect(fetched.externalCopies[1].store == nil)
        #expect(fetched.externalCopies[1].itemId == nil)
    }

    // MARK: M1

    // M1: a library made by the previous version opens, migrates, and no book has copies.
    @Test func M1_aV3DatabaseUpgrades() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v3")
            try queue.write { db in
                #expect(try db.columns(in: "book").contains { $0.name == "externalCopies" } == false)
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention, folderPath,
                                      asin, dateAdded, readStatus, appOnlyFields)
                    VALUES ('Old Book', '["Old Author"]', '["Old Narrator"]', '["kept"]', 4, 0,
                            'Old Author/Old Book', 'B000000001', '2025-01-02 03:04:05.000', 'finished', '["cover"]')
                    """)
                try db.execute(sql: """
                    INSERT INTO bookFile (bookId, path, format, role, position, writeProblem, originalName)
                    VALUES (?, 'Old Author/Old Book/Old Book.m4b', 'm4b', 'audio', 0, NULL, NULL)
                    """, arguments: [db.lastInsertedRowID])
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, tags, rating, needsAttention,
                                      dateAdded, readStatus, appOnlyFields)
                    VALUES ('Second Book', '["Other Author"]', '[]', '[]', 0, 1,
                            '2025-02-02 03:04:05.000', 'unread', '[]')
                    """)
                try db.execute(sql: """
                    INSERT INTO bookFile (bookId, path, format, role, position, writeProblem, originalName)
                    VALUES (?, '/elsewhere/Second.epub', 'epub', 'ebook', 0, 'locked', NULL)
                    """, arguments: [db.lastInsertedRowID])
            }
            try queue.close()
        }

        let store = try LibraryStore(libraryRoot: root)

        let columns = try store.dbQueue.read { db in try db.columns(in: "book") }
        let column = try #require(columns.first { $0.name == "externalCopies" })
        #expect(column.isNotNull)
        #expect(column.type.uppercased() == "TEXT")

        let books = try store.books()
        #expect(books.map(\.title) == ["Old Book", "Second Book"])
        #expect(books.allSatisfy { $0.externalCopies.isEmpty })
        #expect(books.allSatisfy { !$0.isOwnedElsewhere })
        let old = try #require(books.first)
        let oldId = try #require(old.id)
        #expect(old.authors == ["Old Author"])
        #expect(old.narrators == ["Old Narrator"])
        #expect(old.tags == ["kept"])
        #expect(old.rating == 4)
        #expect(old.asin == "B000000001")
        #expect(old.folderPath == "Old Author/Old Book")
        #expect(old.readStatus == .finished)
        #expect(old.appOnlyFields == [.cover])
        #expect(try storedText(oldId, in: store) == "[]")
        #expect(try store.files(bookId: oldId).map(\.path) == ["Old Author/Old Book/Old Book.m4b"])
        let second = try #require(books.last)
        #expect(second.needsAttention)
        #expect(try store.files(bookId: try #require(second.id)).map(\.writeProblem) == ["locked"])

        // The lists work on the migrated library, and the new column round-trips.
        #expect(try store.books(having: .audio).map(\.title) == ["Old Book"])
        #expect(try store.books(ownedOn: .audible).isEmpty)
        var marked = old
        marked.externalCopies = [audible]
        try store.update(marked)
        #expect(try store.book(id: oldId)?.externalCopies == [audible])
        #expect(try store.books(ownedOn: .audible).map(\.title) == ["Old Book"])

        // Opening again changes nothing.
        let again = try LibraryStore(libraryRoot: root)
        #expect(try again.book(id: oldId)?.externalCopies == [audible])
    }

    // M1: a book written before the field existed (in an undo snapshot, say) still decodes.
    @Test func M1_aBookWithoutTheFieldDecodes() throws {
        var original = book("Snapshot Book", copies: [audible])
        original.id = 7
        let data = try JSONEncoder().encode(original)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["externalCopies"] != nil)
        object.removeValue(forKey: "externalCopies")
        let old = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Book.self, from: old)
        #expect(decoded.externalCopies.isEmpty)
        #expect(decoded.title == "Snapshot Book")
        #expect(decoded.id == 7)

        // And a book written now carries its copies in a snapshot.
        #expect(try JSONDecoder().decode(Book.self, from: data).externalCopies == [audible])
    }

    // M1: an undo snapshot recorded before the field existed still decodes and still undoes.
    @Test func M1_anOldUndoSnapshotStillUndoes() throws {
        let f = try LibraryFixture()
        let source = try f.makeM4B("a.m4b", tags: LibraryFixture.meta("Old Title", "Ann Author"))
        let id = try f.importNew([source], LibraryFixture.meta("Old Title", "Ann Author"))
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "New Title"
        _ = try f.service.save([edit])
        #expect(exists(f.lib("Ann Author/New Title/New Title.m4b")))

        // Rewrite the recorded snapshot as the previous version would have written it.
        let batch = try #require(try f.store.lastBatch())
        let recorded = try #require(batch.snapshot)
        var snapshot = try #require(try JSONSerialization.jsonObject(with: recorded) as? [String: Any])
        var books = try #require(snapshot["books"] as? [[String: Any]])
        var before = try #require(books[0]["bookBefore"] as? [String: Any])
        #expect(before["externalCopies"] != nil)
        before.removeValue(forKey: "externalCopies")
        books[0]["bookBefore"] = before
        snapshot["books"] = books
        let old = try JSONSerialization.data(withJSONObject: snapshot)
        try f.store.dbQueue.write { db in
            try db.execute(sql: "UPDATE operationBatch SET snapshot = ?", arguments: [old])
        }

        #expect(OperationSnapshot.usable(from: old) != nil)
        #expect(try f.service.undoLabel() == "Edit New Title")
        try f.service.undoLast()

        let restored = try #require(try f.store.book(id: id))
        #expect(restored.title == "Old Title")
        #expect(restored.externalCopies.isEmpty)
        #expect(f.libraryTree() == ["Ann Author", "Ann Author/Old Title", "Ann Author/Old Title/Old Title.m4b"])
        #expect(try f.tags(f.lib("Ann Author/Old Title/Old Title.m4b")).title == "Old Title")
    }

    // MARK: M2

    // M2: a copy this version cannot read is skipped; the others, and the book, are read.
    @Test func M2_anUnknownKindIsSkippedOnReading() throws {
        let store = try makeStore()
        let id = try #require(try store.insert(book("Mixed"), files: []).id)
        let text = """
            [{"kind":"kobo","form":"ebook","store":"uk","itemId":"K1"},\
            {"kind":"audible","form":"audio","store":"uk","itemId":"B08G9PRS1K"},\
            {"kind":"audible","form":"hologram"},\
            "not a copy at all",\
            {"kind":"audible","form":"ebook","somethingNew":true}]
            """
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE book SET externalCopies = ? WHERE id = ?", arguments: [text, id])
        }

        let fetched = try #require(try store.book(id: id))
        #expect(fetched.title == "Mixed")
        #expect(fetched.externalCopies == [audible, ExternalCopy(kind: .audible, form: .ebook)])
        // Reading alone leaves the stored text exactly as it was.
        #expect(try store.books().count == 1)
        #expect(try storedText(id, in: store) == text)

        // The lists agree with what was read: the unreadable copies count for nothing.
        #expect(try store.books(ownedOn: .audible).map(\.id) == [id])
        #expect(try store.books(having: .audio).map(\.id) == [id])
    }

    // M2: only unreadable copies. The book is simply not owned elsewhere, and is in no list for them.
    @Test func M2_aBookWithOnlyUnknownCopiesReadsAsHavingNone() throws {
        let store = try makeStore()
        let id = try #require(try store.insert(book("Future"), files: []).id)
        let text = #"[{"kind":"kobo","form":"audio","itemId":"K1"}]"#
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE book SET externalCopies = ? WHERE id = ?", arguments: [text, id])
        }

        let fetched = try #require(try store.book(id: id))
        #expect(fetched.externalCopies.isEmpty)
        #expect(try store.books(having: .audio).isEmpty)
        #expect(try store.books(ownedOn: .audible).isEmpty)
        #expect(try storedText(id, in: store) == text)

        // Saving the book writes back what this version could not read.
        try store.update(fetched)
        #expect(try storedKinds(id, in: store) == ["kobo"])
        #expect(try store.book(id: id) == fetched)
    }

    /// The `kind` of each entry of the stored list that is an object, in order.
    func storedKinds(_ id: Int64, in store: LibraryStore) throws -> [String] {
        let text = try #require(try storedText(id, in: store))
        let list = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        return list.compactMap { ($0 as? [String: Any])?["kind"] as? String }
    }

    static let fromTheFuture = """
        [{"kind":"kobo","form":"ebook","store":"uk","itemId":"K1","shelf":{"n":2,"tags":["a",null,true]}},\
        {"kind":"audible","form":"audio","store":"uk","itemId":"B08G9PRS1K"},\
        {"kind":"audible","form":"hologram"}]
        """

    /// The entries of the stored list this version cannot read, as JSON values.
    func unread(_ id: Int64, in store: LibraryStore) throws -> [NSDictionary] {
        let text = try #require(try storedText(id, in: store))
        let list = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [NSDictionary])
        return list.filter { ($0["kind"] as? String) != "audible" || ($0["form"] as? String) == "hologram" }
    }

    // M2: whatever changes a book, the copies a newer version recorded are written back
    // whole: a save, the read status, marking and unmarking, and undo.
    @Test func M2_copiesThisVersionCannotReadSurviveEveryChange() throws {
        let f = try LibraryFixture()
        let tags = LibraryFixture.meta("Future Book", "Ann Author")
        let id = try f.importNew([try f.makeM4B("a.m4b", tags: tags)], tags)
        try f.store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE book SET externalCopies = ? WHERE id = ?", arguments: [Self.fromTheFuture, id])
        }
        let kept = try unread(id, in: f.store)
        #expect(kept.count == 2)
        #expect(try f.store.book(id: id)?.externalCopies == [audible])

        // The read status.
        try f.service.setReadStatus(.finished, for: [id])
        #expect(try unread(id, in: f.store) == kept)
        #expect(try f.store.book(id: id)?.externalCopies == [audible])

        // Unmarking and marking again.
        try f.service.setExternalCopies([], for: id)
        #expect(try unread(id, in: f.store) == kept)
        #expect(try f.store.book(id: id)?.externalCopies.isEmpty == true)
        #expect(try f.service.addExternalBook(metadata: tags, cover: nil, copy: audible) == .markedExisting(bookId: id))
        #expect(try unread(id, in: f.store) == kept)
        #expect(try f.store.book(id: id)?.externalCopies == [audible])

        // A save, and its undo.
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "Renamed"
        _ = try f.service.save([edit])
        #expect(try unread(id, in: f.store) == kept)
        // The snapshot carries them too, but undo keeps the ones the book has now.
        let later = #"[{"kind":"kobo","form":"ebook"},{"kind":"audible","form":"audio","store":"uk","itemId":"B08G9PRS1K"}]"#
        try f.store.dbQueue.write { db in
            try db.execute(sql: "UPDATE book SET externalCopies = ? WHERE id = ?", arguments: [later, id])
        }
        try f.service.undoLast()
        #expect(try f.store.book(id: id)?.title == "Future Book")
        #expect(try storedKinds(id, in: f.store) == ["audible", "kobo"])
        #expect(try f.store.book(id: id)?.externalCopies == [audible])

        // Rewriting tags and removing a collection membership aside, nothing else writes a book.
        _ = try f.service.rewriteTags(for: [id])
        #expect(try storedKinds(id, in: f.store) == ["audible", "kobo"])
    }

    // M2: a book read from a snapshot keeps them as well.
    @Test func M2_unreadCopiesRoundTripThroughJSON() throws {
        let store = try makeStore()
        let id = try #require(try store.insert(book("Future"), files: []).id)
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE book SET externalCopies = ? WHERE id = ?", arguments: [Self.fromTheFuture, id])
        }
        let fetched = try #require(try store.book(id: id))
        let back = try JSONDecoder().decode(Book.self, from: try JSONEncoder().encode(fetched))
        #expect(back == fetched)
        #expect(back.storedCopies.unread.count == 2)
    }

    // MARK: M3

    // M3: the Audiobooks and Ebooks lists take a file or a copy in that form; each book once.
    @Test func M3_listsByFormIncludeBooksOwnedElsewhere() throws {
        let store = try makeStore()
        let ebookCopy = ExternalCopy(kind: .audible, form: .ebook, store: "us", itemId: "E1")
        try store.insert(book("A File Audio"), files: [audioFile("A")])
        try store.insert(book("b Copy Audio", copies: [audible]), files: [])
        try store.insert(book("C Both Ways", copies: [audible, ebookCopy]), files: [audioFile("C"), ebookFile("C")])
        try store.insert(book("D Ebook File, Audio Copy", copies: [audible]), files: [ebookFile("D")])
        try store.insert(book("E Ebook Copy", copies: [ebookCopy]), files: [])
        try store.insert(book("F Extra Only"), files: [extraFile("F")])
        try store.insert(book("G Nothing"), files: [])

        #expect(try store.books(having: .audio).map(\.title)
            == ["A File Audio", "b Copy Audio", "C Both Ways", "D Ebook File, Audio Copy"])
        #expect(try store.books(having: .ebook).map(\.title)
            == ["C Both Ways", "D Ebook File, Audio Copy", "E Ebook Copy"])
        // Extras are files only.
        #expect(try store.books(having: .extra).map(\.title) == ["F Extra Only"])
        #expect(try store.books().count == 7)
    }

    // M3: the other filters still combine with the form.
    @Test func M3_theOtherFiltersStillApply() throws {
        let store = try makeStore()
        var flagged = book("Flagged Copy", copies: [audible])
        flagged.needsAttention = true
        var finished = book("Finished Copy", copies: [audible])
        finished.setReadStatus(.finished)
        try store.insert(flagged, files: [])
        try store.insert(finished, files: [])
        try store.insert(book("Plain File"), files: [audioFile("Plain")])

        #expect(try store.books(having: .audio, needsAttention: true).map(\.title) == ["Flagged Copy"])
        #expect(try store.books(having: .audio, needsAttention: false).map(\.title)
            == ["Finished Copy", "Plain File"])
        #expect(try store.books(having: .audio, readStatus: .finished).map(\.title) == ["Finished Copy"])
        #expect(try store.books(having: .ebook).isEmpty)
    }

    // MARK: M4

    // M4: every book with a copy of the kind, with or without files, sorted by title.
    @Test func M4_booksOwnedOnAKind() throws {
        let store = try makeStore()
        try store.insert(book("zebra", copies: [audible]), files: [])
        try store.insert(book("Apple", copies: [ExternalCopy(kind: .audible, form: .ebook)]), files: [audioFile("Apple")])
        try store.insert(book("Mango"), files: [audioFile("Mango")])
        try store.insert(book("banana", copies: [audible, ExternalCopy(kind: .audible, form: .ebook)]), files: [])

        #expect(try store.books(ownedOn: .audible).map(\.title) == ["Apple", "banana", "zebra"])
        #expect(try store.books(ownedOn: .audible).allSatisfy { $0.isOwned(on: .audible) })
    }

    @Test func M4_anEmptyLibraryHasNone() throws {
        #expect(try makeStore().books(ownedOn: .audible).isEmpty)
    }

    // MARK: M5

    // M5: no duplicates, however the list is set; the first of each stays where it was.
    @Test func M5_duplicatesAreDropped() throws {
        let other = ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B08G9PRS1K")
        let ebook = ExternalCopy(kind: .audible, form: .ebook, store: "uk", itemId: "B08G9PRS1K")
        let noId = ExternalCopy(kind: .audible, form: .audio, store: "uk")

        var b = book("Owned")
        b.externalCopies = [audible, other, audible, ebook, other, noId, noId]
        #expect(b.externalCopies == [audible, other, ebook, noId])

        b.externalCopies.append(audible)
        #expect(b.externalCopies == [audible, other, ebook, noId])
        b.externalCopies.insert(ebook, at: 0)
        #expect(b.externalCopies == [ebook, audible, other, noId])

        // As stored, and as read back.
        let store = try makeStore()
        let id = try #require(try store.insert(b, files: []).id)
        #expect(try store.book(id: id)?.externalCopies == [ebook, audible, other, noId])
    }

    // M5: duplicates already in the stored text are dropped on reading.
    @Test func M5_duplicatesInTheStoredTextAreDroppedOnReading() throws {
        let store = try makeStore()
        let id = try #require(try store.insert(book("Doubled"), files: []).id)
        let one = #"{"kind":"audible","form":"audio","store":"uk","itemId":"B08G9PRS1K"}"#
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE book SET externalCopies = ? WHERE id = ?", arguments: ["[\(one),\(one)]", id])
        }
        #expect(try store.book(id: id)?.externalCopies == [audible])
        #expect(try store.books(ownedOn: .audible).count == 1)
        #expect(try store.books(having: .audio).count == 1)
    }
}

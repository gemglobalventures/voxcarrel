import Foundation

/// Why a book's audio was not replaced. Nothing was changed.
public enum ReplaceAudioError: Error, Equatable {
    /// The book has no audio files, or no folder of its own to put one in.
    case nothingToReplace
    /// The file offered is not there, or is not an M4B or M4A with sound in it.
    case notAnAudiobook
    /// The file offered is shorter than the audio it would replace.
    case shorter(expected: Double, found: Double)
}

/// What replacing a book's audio did.
public struct AudioReplacement: Equatable, Sendable {
    /// The book's audio file now.
    public var file: BookFile
    /// The files it replaced that could not be sent to the Trash: they are still in
    /// the book's folder, and no longer the book's.
    public var leftBehind: [URL]
}

extension LibraryService {
    /// A book's audio files in order, each with where it is.
    public func audioFiles(ofBook bookId: Int64) throws -> [(file: BookFile, url: URL)] {
        try store.files(bookId: bookId).filter { $0.role == .audio }.map { ($0, store.url(for: $0)) }
    }

    /// Makes one new file the book's audio, in place of the audio files it had: for a
    /// book whose parts were joined into one file, or whose audio was made again in
    /// another form. The files it replaces go to the Trash.
    ///
    /// `staged` is a finished M4B or M4A anywhere on this Mac; it is moved into the
    /// book's folder under the book's title. Before anything of the library is touched,
    /// the book's details and cover are written into it and it is read back: it must
    /// hold sound, and no less of it than the audio it replaces (two seconds and one
    /// part in a hundred are let pass, for what an encoder trims). Then, in order: the
    /// file is moved in, the catalogue is changed in one step, and the old files are
    /// sent to the Trash. A failure before the catalogue is changed leaves the book as
    /// it was, with `staged` where it was given. An old file that will not go to the
    /// Trash afterwards is named in the answer and stays in the folder.
    ///
    /// The book's other files (an ebook, a companion) are untouched. Not undoable
    /// through VoxCarrel: the old files are in the Trash. If the last recorded operation
    /// involved this book, it can no longer be undone and is forgotten.
    public func replaceAudio(ofBook bookId: Int64, with staged: URL) throws -> AudioReplacement {
        try refuseWhileLayoutChangeIsInterrupted()
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        let rows = try store.files(bookId: bookId)
        let old = rows.filter { $0.role == .audio }
        guard !old.isEmpty, let folderPath = book.folderPath else { throw ReplaceAudioError.nothingToReplace }
        let fm = FileManager.default
        guard fm.fileExists(atPath: staged.path), let format = FileFormat(url: staged), format == .m4b || format == .m4a
        else { throw ReplaceAudioError.notAnAudiobook }

        // Its details first, while it is still nobody's.
        let cover = covers.image(for: bookId)
        _ = try metadataIO.write(book.metadata, cover: cover.map { .set($0) } ?? .keep, to: staged)
        guard let seconds = try? metadataIO.read(staged).metadata.durationSeconds, seconds > 0 else {
            throw ReplaceAudioError.notAnAudiobook
        }
        if let recorded = book.durationSeconds, recorded > 0, seconds < recorded * 0.99 - 2 {
            throw ReplaceAudioError.shorter(expected: recorded, found: seconds)
        }

        let folder = store.url(forFolder: folderPath)
        let taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let stem = PathBuilder.sanitise(book.title)
        var name = "\(stem).m4b"
        var count = 2
        while taken.contains(name.lowercased()) {
            name = "\(stem) \(count).m4b"
            count += 1
        }
        let destination = folder.appendingPathComponent(name)
        let oldURLs = old.map { store.url(for: $0) }
        try fm.moveItem(at: staged, to: destination)

        do {
            var joined = BookFile(path: "\(folderPath)/\(name)", format: .m4b, role: .audio, position: 0)
            joined.contentPrint = ContentPrint.of(destination)
            var newRows = [joined]
            for var row in rows where row.role != .audio {
                row.position = newRows.count
                newRows.append(row)
            }
            let files = workingFiles(for: newRows)
            var updated = book
            updated.durationSeconds = seconds
            updated.appOnlyFields = keepingCoverMembership(
                of: book, in: Self.appOnlyFields(files: files, hasStoredCover: false))
            updated.genreTag = Self.genreTag(after: files, of: updated, recorded: book.genreTag)

            var change = LibraryChange()
            change.writes = [.init(book: updated, files: newRows)]
            change.cutsJournalThrough = try newestBatchInvolving(bookId: bookId, files: oldURLs)
            try beforeCommit?()
            try store.apply(change)
            if change.cutsJournalThrough != nil { forgetUndoData() }
            refreshDetailsFiles(ofBooks: [bookId])
        } catch {
            // The book is as it was: the new file goes back where it came from.
            try? fm.moveItem(at: destination, to: staged)
            throw error
        }

        var leftBehind: [URL] = []
        for url in oldURLs where fm.fileExists(atPath: url.path) {
            do { try trashItem(url) } catch { leftBehind.append(url) }
        }
        let file = try store.files(bookId: bookId).first { $0.role == .audio } ?? BookFile(
            path: "\(folderPath)/\(name)", format: .m4b, role: .audio, position: 0)
        return AudioReplacement(file: file, leftBehind: leftBehind)
    }
}

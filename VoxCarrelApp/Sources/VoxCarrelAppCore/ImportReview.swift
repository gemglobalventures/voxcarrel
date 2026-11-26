import Foundation
import VoxCarrelCore

/// The books of one import while the user reviews them, before anything is imported.
///
/// A plain value: it reads no file and calls nothing. Everything it answers
/// (`readiness`, `canImport`, `entriesNeedingDestination`, `items()`) is worked out from
/// the entries as they are at that moment, so a view may change an entry directly.
public struct ImportReview: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var candidate: CandidateBook
        public var included: Bool
        /// Shown, and sent as the cover when `coverChanged`.
        public var cover: CoverImage?
        public var coverChanged: Bool
        public var existingMatch: Book?
        /// Only meaningful when `existingMatch` is not nil. IH1: starts true for a sure
        /// match and one by Audible ID, false for a possible one.
        public var addToExisting: Bool
        /// The measured length of the one audio file the entry came with, when it came
        /// with one and its length could be measured.
        var measuredAudio: MeasuredAudio?

        /// The folder last worked out for this entry as a new book, and the details it
        /// was worked out for. `computedFor` is nil until there has been an answer.
        var computedDestination: String?
        var computedFor: DestinationDetails?
        /// FP41: why the import would refuse this entry as a new book, when it would:
        /// the folder it belongs in is another book's. Worked out with the folder.
        var destinationRefusal: String?

        /// The title, first author and Audible ID `existingMatch` was looked up for; nil
        /// when it has yet to be looked up.
        var matchedFor: MatchDetails?

        /// For a match that has no files (`matchHasNoFiles`): the folder that book will
        /// be filed in when it is given its first files, and the book it was worked out
        /// for. `matchDestinationFor` is nil until there has been an answer.
        var matchDestination: String?
        var matchDestinationFor: Book?
        /// FL14: why the import would refuse to file that book's first files, when it
        /// would: the folder it belongs in is another book's.
        var matchRefusal: String?

        /// IH1: how sure `existingMatch` is. Only meaningful when it is not nil.
        public internal(set) var matchStrength: MatchStrength = .sure
        /// IH3: whether the matched book has an audio file, and a PDF as its ebook.
        var matchHasAudio = false
        var matchHasPDFEbook = false
        /// IH2: what the owner set the switch to by hand, by the id of the library book
        /// it was offered for.
        var switchChoices: [Int64: Bool] = [:]
        /// IH4: what was guessed about the entry from names and has not been put right
        /// or looked at since. The candidate's own notes are left as the scan made them.
        public internal(set) var guessNotes: GuessNotes = []
        /// IH3: the PDFs (by standardised path) that were made extras by the guess, and
        /// the PDFs whose role the owner chose while a library book was offered.
        var guessedExtras: Set<String> = []
        var rolesChosen: Set<String> = []

        // MARK: IH1, IH2 The switch

        /// IH1: where the switch stands for a match of this strength until the owner
        /// sets it: on for a sure match and one by Audible ID, off for a possible one.
        static func startsAdded(_ strength: MatchStrength) -> Bool {
            strength != .possible
        }

        /// IH2: true when the owner has set the switch for the book that is offered now.
        var ownerSetSwitch: Bool {
            guard let id = existingMatch?.id else { return false }
            return switchChoices[id] != nil || addToExisting != Self.startsAdded(matchStrength)
        }

        /// IH6: true while a possible match waits for the owner's answer.
        public var isPossibleMatchUnanswered: Bool {
            existingMatch?.id != nil && matchStrength == .possible && !ownerSetSwitch
        }

        /// The notes that are about the title and the authors.
        static let titleAndAuthorNotes: GuessNotes = [
            .fromFileName, .orderUnsure, .orderSwapped, .orderGuessedByShape, .titleLooksLikePerson,
        ]

        /// Takes account of a change made to the entry from outside: IH4, a title or
        /// authors that were changed are no longer a guess, and nor is a changed Audible
        /// ID; IH2, a switch that was changed is the owner's choice for the book it is
        /// offered for; IH3, the roles follow the switch.
        mutating func noteChanges(since before: Entry) {
            let (now, was) = (candidate.metadata, before.candidate.metadata)
            if now.title != was.title || now.authors != was.authors {
                guessNotes.subtract(Self.titleAndAuthorNotes)
            }
            if now.asin != was.asin { guessNotes.remove(.audibleIDFromName) }
            if addToExisting != before.addToExisting, let id = existingMatch?.id, id == before.existingMatch?.id {
                switchChoices[id] = addToExisting
            }
            applyRoleGuess()
        }

        // MARK: IH3 A PDF that joins a book

        /// IH3: true when a PDF that joins the matched book is more likely something
        /// that came with it than its ebook: the book was known by its Audible ID and
        /// has audio, or it has a PDF as its ebook already.
        var guessesExtraForPDFs: Bool {
            isAddedToExisting && ((matchStrength == .audibleID && matchHasAudio) || matchHasPDFEbook)
        }

        /// IH3: makes extras of the entry's PDF ebooks while they join such a book, and
        /// ebooks of them again when they no longer do. A role the owner chose is left
        /// alone, and so is an extra that was one before the guess.
        mutating func applyRoleGuess() {
            let wantsExtra = guessesExtraForPDFs
            for index in candidate.files.indices {
                let file = candidate.files[index]
                let path = file.url.standardizedFileURL.path
                guard FileFormat(url: file.url) == .pdf, !rolesChosen.contains(path) else { continue }
                if wantsExtra {
                    guard file.role == .ebook else { continue }
                    candidate.files[index].role = .extra
                    guessedExtras.insert(path)
                } else if guessedExtras.remove(path) != nil, file.role == .extra {
                    candidate.files[index].role = .ebook
                }
            }
        }

        /// True when the files will go into `existingMatch` and not into a new book.
        public var isAddedToExisting: Bool {
            addToExisting && existingMatch?.id != nil
        }

        /// The owner's word that this is another edition of `existingMatch` (another
        /// language, another narrator, a dramatisation), to be kept as a book of its
        /// own and tied to it. Only meaningful while the files are not added to it.
        public var asEdition = false

        /// Whether "another edition" can be chosen: a book of the library with files
        /// is matched, and these files are not being added to it.
        public var offersEdition: Bool {
            existingMatch?.id != nil && !isAddedToExisting && !matchHasNoFiles
        }

        /// True when this will be imported as another edition of `existingMatch`.
        public var isImportedAsEdition: Bool {
            asEdition && offersEdition
        }

        /// R9: true when the matched book has no files yet: it is in the library only
        /// as owned elsewhere (on Audible), and is in no folder. Its first files are
        /// filed from its own details, as a new book's would be.
        public var matchHasNoFiles: Bool {
            guard let match = existingMatch, match.id != nil else { return false }
            return match.folderPath == nil && match.isOwnedElsewhere && !match.needsAttention
        }

        /// Relative folder it will be filed in; nil when it cannot be filed, or when
        /// that has not been worked out yet. For an entry added to an existing book it
        /// is that book's folder; for a book that has no files yet, the folder it will
        /// be filed in.
        public var destination: String? {
            guard isAddedToExisting else { return computedDestination }
            return matchHasNoFiles ? matchDestination : existingMatch?.folderPath
        }

        /// True when the folder a match with no files will be filed in has not been
        /// worked out for that book as it is now.
        var needsMatchDestination: Bool {
            isAddedToExisting && matchHasNoFiles && matchDestinationFor != existingMatch
        }

        /// True when the folder of this new book has not been worked out for its
        /// details and files as they are now.
        func needsDestination(under pattern: FolderPattern) -> Bool {
            !isAddedToExisting
                && computedFor != DestinationDetails(candidate.metadata, hasAudio: hasAudio, pattern: pattern)
        }

        /// What the entry's book gives a folder pattern (`hasAudio` is what `{Kind}` goes by).
        var patternValues: FolderPatternValues {
            FolderPatternValues(metadata: candidate.metadata, hasAudio: hasAudio)
        }
    }

    /// The details that decide which folder a new book is filed in under a folder
    /// pattern: the text of each detail the pattern names, as it is written, and
    /// whether the book has audio when the pattern files by that. Under the standard
    /// pattern: the title, the first author, the series and the series number.
    struct DestinationDetails: Equatable, Sendable {
        var texts: [FolderToken: String?] = [:]

        init(_ metadata: BookMetadata, hasAudio: Bool, pattern: FolderPattern) {
            var used = pattern.usedTokens
            // A number only counts inside its series.
            if used.contains(.number) { used.insert(.series) }
            for token in used {
                texts[token] =
                    switch token {
                    case .title: metadata.title
                    case .author: metadata.authors.first
                    case .series: metadata.series
                    case .number: metadata.seriesNumber
                    case .narrator: metadata.narrators.first
                    case .year: metadata.year.map(String.init)
                    case .genre: metadata.genres.first
                    case .publisher: metadata.publisher
                    case .language: metadata.language
                    case .kind: hasAudio ? "audio" : "no audio"
                    }
            }
        }
    }

    /// The details that decide which library book an entry matches: the title, the
    /// first author and the Audible ID, without the spaces around them and ignoring
    /// capitals, as the library compares them.
    struct MatchDetails: Equatable, Sendable {
        var title: String
        var firstAuthor: String
        var asin: String

        init(_ metadata: BookMetadata) {
            title = metadata.title.trimmed.lowercased()
            firstAuthor = (metadata.authors.first ?? "").trimmed.lowercased()
            asin = (metadata.asin ?? "").trimmed.lowercased()
        }
    }

    public enum Readiness: Equatable, Sendable {
        case ready
        /// Lacks something the library's folder pattern needs (under the standard
        /// pattern, a title or an author): catalogued, left in place.
        case willNeedAttention
        /// Cannot be imported as it stands.
        case blocked(String)
    }

    public var entries: [Entry]
    public var skipped: [URL]
    /// How many of the files that were read the library already has, byte for byte.
    /// They are not among the entries.
    public var alreadyInLibrary = 0
    /// Which entries the list shows.
    public var filter: Filter = .all
    public var copyInsteadOfMove: Bool
    /// How the library the books are going into files its books. The review reads
    /// nothing, so whoever makes it for a library gives it that library's pattern.
    public var folderPattern: FolderPattern = .standard
    /// True when every file is inside the library folder already. Such files are
    /// always moved into place: a copy would leave the original loose in the library,
    /// to be found again and imported twice.
    public let moveOnly: Bool
    /// True when the books are ones that arrived in the watch folders and were sent
    /// for review from the Inbox.
    public let isFromInbox: Bool
    /// WF19: said beside the Copy tick when it was preset for a reason worth telling;
    /// nil otherwise.
    public let inboxNote: String?
    /// What came with the books when they were read from a calibre library; nil for
    /// any other import. Such an import always copies: the calibre library is left as
    /// it is.
    public let calibre: CalibreSource?

    /// What a calibre library said besides the books it gave to review.
    public struct CalibreSource: Equatable, Sendable {
        /// What calibre says of each book beyond its files, by the path of the book's
        /// folder in the calibre library.
        var extras: [String: CalibreExtras]
        /// How many books calibre lists that have no file the library keeps.
        public var withoutFiles: Int
        /// Kinds of file that were passed over, each with how many.
        public var formatsLeftOut: [String: Int]

        public init(extras: [URL: CalibreExtras], withoutFiles: Int, formatsLeftOut: [String: Int]) {
            self.extras = Dictionary(extras.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
            self.withoutFiles = withoutFiles
            self.formatsLeftOut = formatsLeftOut
        }

        private static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

        /// What calibre said of the books this candidate is made of. They are found by
        /// the calibre folders its files are in, and the folder it was read from: so a
        /// file moved out to be a book of its own keeps what was said of it, and books
        /// merged in the review bring what was said of each.
        public func extras(for candidate: CandidateBook) -> [CalibreExtras] {
            var folders = candidate.sourceFolder.map { [Self.key($0)] } ?? []
            for file in candidate.files {
                let folder = Self.key(file.url.deletingLastPathComponent())
                if !folders.contains(folder) { folders.append(folder) }
            }
            return folders.compactMap { extras[$0] }
        }
    }

    /// Said when the books come from watch folders that do not agree on Move or Copy.
    public static let mixedModesNote = "These books come from folders set to Move and to Copy, so Copy is ticked."

    public init(
        seeds: [ImportSeed], skipped: [URL], copyInsteadOfMove: Bool, moveOnly: Bool = false,
        isFromInbox: Bool = false, inboxNote: String? = nil, alreadyInLibrary: Int = 0,
        calibre: CalibreSource? = nil
    ) {
        self.calibre = calibre
        self.alreadyInLibrary = alreadyInLibrary
        self.isFromInbox = isFromInbox
        self.inboxNote = inboxNote
        entries = seeds.map { seed in
            var entry = Entry(
                id: UUID(), candidate: seed.candidate, included: true, cover: seed.cover,
                coverChanged: seed.coverIsFromBeside, existingMatch: seed.existingMatch,
                // IH1: a possible match is offered switched off.
                addToExisting: seed.existingMatch == nil || Entry.startsAdded(seed.matchStrength),
                measuredAudio: seed.measuredAudio,
                // The seed's match was looked up for the details it came with.
                matchedFor: MatchDetails(seed.candidate.metadata),
                matchStrength: seed.matchStrength, matchHasAudio: seed.matchHasAudio,
                matchHasPDFEbook: seed.matchHasPDFEbook, guessNotes: seed.candidate.guessNotes)
            // IH3
            entry.applyRoleGuess()
            return entry
        }
        self.skipped = skipped
        self.moveOnly = moveOnly
        self.copyInsteadOfMove = calibre != nil || (copyInsteadOfMove && !moveOnly)
    }

    /// Whether "copy, leave originals in place" is a choice the user has. It is none
    /// for books from a calibre library, which are always copied.
    public var offersCopy: Bool { !moveOnly && calibre == nil }

    // MARK: Readiness

    public func readiness(of id: UUID) -> Readiness {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return .blocked("Not in this import")
        }
        return readiness(of: entry)
    }

    private func readiness(of entry: Entry) -> Readiness {
        // The engine refuses an item with no files, whatever it is added to.
        guard !entry.candidate.files.isEmpty else { return .blocked("No files") }
        // Extras may join a book that is already there, and that book has its own details.
        guard !entry.isAddedToExisting else { return .ready }
        // The engine would file this as a book with nothing to listen to or read.
        guard entry.candidate.files.contains(where: { $0.role != .extra }) else {
            return .blocked("A book needs at least one audiobook or ebook file")
        }
        // Exactly the engine's test for a book it catalogues without filing.
        return PathBuilder.bookFolder(values: entry.patternValues, pattern: folderPattern) == nil
            ? .willNeedAttention : .ready
    }

    public var includedCount: Int {
        entries.filter(\.included).count
    }

    public var canImport: Bool {
        let included = entries.filter(\.included)
        return !included.isEmpty && !included.contains {
            if case .blocked = readiness(of: $0) { return true } else { return false }
        }
    }

    // MARK: Files

    public mutating func setRole(_ role: FileRole, file: URL, in id: UUID) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              let index = Self.index(of: file, in: entries[entry]),
              let format = FileFormat(url: file),
              FileRow.allowedRoles(for: format).contains(role)
        else { return }
        entries[entry].candidate.files[index].role = role
        // IH3: the owner's choice for a PDF that is offered to a library book, which
        // no guess about that changes afterwards.
        let path = file.standardizedFileURL.path
        if format == .pdf, entries[entry].existingMatch != nil { entries[entry].rolesChosen.insert(path) }
        entries[entry].guessedExtras.remove(path)
    }

    /// Takes one file out into a new entry placed directly after its old one.
    public mutating func detach(file: URL, from id: UUID) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              entries[entry].candidate.files.count > 1,
              let index = Self.index(of: file, in: entries[entry])
        else { return }
        var detached = entries[entry].candidate.files.remove(at: index)
        let path = detached.url.standardizedFileURL.path
        entries[entry].guessedExtras.remove(path)
        entries[entry].rolesChosen.remove(path)
        // An extra cannot be a book by itself.
        if detached.role == .extra, let format = FileFormat(url: detached.url) {
            detached.role = format.defaultRole
        }
        // Same details, so the folder already worked out for them holds for the new book too.
        let source = entries[entry]
        entries.insert(
            Entry(
                id: UUID(),
                candidate: CandidateBook(files: [detached], metadata: source.candidate.metadata),
                included: true, cover: nil, coverChanged: false, existingMatch: nil, addToExisting: true,
                computedDestination: source.computedDestination, computedFor: source.computedFor,
                destinationRefusal: source.destinationRefusal,
                // Moved out to be a book of its own: it is not offered to the library's
                // book again unless its title or author is changed.
                matchedFor: MatchDetails(source.candidate.metadata),
                // IH4: its details are the same guesses.
                guessNotes: source.guessNotes),
            at: entry + 1)
    }

    /// Merges the entries into the first of them (in list order).
    public mutating func merge(_ ids: Set<UUID>) {
        let merging = entries.filter { ids.contains($0.id) }
        guard merging.count >= 2, let survivor = entries.firstIndex(where: { ids.contains($0.id) }) else {
            return
        }

        var seen = Set<String>()
        let files = merging.flatMap(\.candidate.files).filter {
            seen.insert($0.url.standardizedFileURL.path).inserted
        }
        entries[survivor].candidate.files = [FileRole.audio, .ebook, .extra].flatMap { role in
            files.filter { $0.role == role }
        }
        // A cover the user chose for the other entry must still be sent, so it comes
        // with its flag.
        if entries[survivor].cover == nil, let other = merging.dropFirst().first(where: { $0.cover != nil }) {
            entries[survivor].cover = other.cover
            entries[survivor].coverChanged = other.coverChanged
        }
        // IH3: what is known of each file's role comes with it.
        for other in merging.dropFirst() {
            entries[survivor].guessedExtras.formUnion(other.guessedExtras)
            entries[survivor].rolesChosen.formUnion(other.rolesChosen)
        }
        entries[survivor].applyRoleGuess()
        let survivorId = entries[survivor].id
        entries.removeAll { ids.contains($0.id) && $0.id != survivorId }
    }

    private static func index(of file: URL, in entry: Entry) -> Int? {
        let path = file.standardizedFileURL.path
        return entry.candidate.files.firstIndex { $0.url.standardizedFileURL.path == path }
    }

    // MARK: Destinations

    /// Entries whose details changed since `destination` was computed.
    public var entriesNeedingDestination: [UUID] {
        entries.filter { $0.needsDestination(under: folderPattern) }.map(\.id)
    }

    /// Records where a new book would be filed. Ignored when the details that decide
    /// the folder are no longer the ones the answer was worked out for, and for an
    /// entry that is added to an existing book.
    /// - Parameters:
    ///   - hasAudio: Whether the answer was worked out for a book with audio; nil when
    ///     it was worked out for the entry's files as they are now.
    ///   - refusal: FP41: why the import would refuse to file the book there, when it
    ///     would: the folder is another book's. The folder is then not named.
    public mutating func setDestination(
        _ folder: String?, for id: UUID, matchingMetadata: BookMetadata, hasAudio: Bool? = nil,
        refusal: String? = nil
    ) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              !entries[entry].isAddedToExisting
        else { return }
        let current = entries[entry].hasAudio
        let details = DestinationDetails(matchingMetadata, hasAudio: hasAudio ?? current, pattern: folderPattern)
        guard details == DestinationDetails(
            entries[entry].candidate.metadata, hasAudio: current, pattern: folderPattern)
        else { return }
        entries[entry].computedDestination = refusal == nil ? folder : nil
        entries[entry].computedFor = details
        entries[entry].destinationRefusal = refusal
    }

    /// R9: entries that join a book with no files, whose folder has not been worked out
    /// for that book as it is now.
    public var entriesNeedingMatchDestination: [UUID] {
        entries.filter(\.needsMatchDestination).map(\.id)
    }

    /// R9: records where a matched book that has no files will be filed (nil when it
    /// cannot be: it has no author). FL14: `refusal` says why the import would refuse
    /// to file it there, when it would: the folder is another book's. Ignored when `matchedBook` is no longer the entry's
    /// match as it is now, and for a match that has files.
    public mutating func setMatchDestination(
        _ folder: String?, for id: UUID, matchedBook: Book, refusal: String? = nil
    ) {
        guard let entry = entries.firstIndex(where: { $0.id == id }),
              entries[entry].matchHasNoFiles, entries[entry].existingMatch == matchedBook
        else { return }
        entries[entry].matchDestination = folder
        entries[entry].matchDestinationFor = matchedBook
        entries[entry].matchRefusal = folder == nil ? refusal : nil
    }

    // MARK: The book already in the library

    /// Entries whose title, first author or Audible ID changed since `existingMatch`
    /// was looked up.
    public var entriesNeedingMatch: [UUID] {
        entries.filter { $0.matchedFor != MatchDetails($0.candidate.metadata) }.map(\.id)
    }

    /// Records which library book an entry's details (its Audible ID, else its title and
    /// first author) surely match, or that none does: `setMatch` for a sure match.
    public mutating func setExistingMatch(_ book: Book?, for id: UUID, matchingMetadata: BookMetadata) {
        setMatch(book.map { ImportMatch(book: $0, strength: .sure) }, for: id, matchingMetadata: matchingMetadata)
    }

    /// IH2: records which library book an entry's details match and how surely, or that
    /// none does. Ignored when they are no longer the ones the answer was looked up for.
    ///
    /// IH1: the switch is set on for a sure match and one by Audible ID and off for a
    /// possible one, unless the owner has set it by hand for that same book: then it is
    /// as they left it, also when the book is offered again after another was. IH3: the
    /// roles of the entry's PDFs follow.
    public mutating func setMatch(_ match: ImportMatch?, for id: UUID, matchingMetadata: BookMetadata) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let details = MatchDetails(matchingMetadata)
        guard details == MatchDetails(entries[index].candidate.metadata) else { return }
        var entry = entries[index]
        // A choice made for the book offered until now stays with that book.
        let offered = entry.existingMatch?.id
        if let offered, entry.ownerSetSwitch { entry.switchChoices[offered] = entry.addToExisting }
        entry.existingMatch = match?.book
        entry.matchStrength = match?.strength ?? .sure
        entry.matchHasAudio = match?.hasAudio ?? false
        entry.matchHasPDFEbook = match?.hasPDFEbook ?? false
        if let now = match?.book.id {
            entry.addToExisting = entry.switchChoices[now] ?? Entry.startsAdded(entry.matchStrength)
        } else if offered != nil {
            // No book to join: the switch means nothing, and stands as it began.
            entry.addToExisting = true
        }
        entry.matchedFor = details
        entry.applyRoleGuess()
        entries[index] = entry
    }

    // MARK: Importing

    /// The details as they are sent: text without the spaces around it, nothing where
    /// there is only space, and no empty names.
    private static func tidied(_ metadata: BookMetadata) -> BookMetadata {
        var tidy = metadata
        tidy.title = metadata.title.trimmed
        tidy.subtitle = metadata.subtitle?.trimmedOrNil
        tidy.authors = metadata.authors.compactMap(\.trimmedOrNil)
        tidy.narrators = metadata.narrators.compactMap(\.trimmedOrNil)
        tidy.series = metadata.series?.trimmedOrNil
        tidy.seriesNumber = metadata.seriesNumber?.trimmedOrNil
        tidy.genres = metadata.genres.compactMap(\.trimmedOrNil)
        tidy.publisher = metadata.publisher?.trimmedOrNil
        tidy.summary = metadata.summary?.trimmedOrNil
        tidy.language = metadata.language?.trimmedOrNil
        tidy.isbn = metadata.isbn?.trimmedOrNil
        tidy.asin = metadata.asin?.trimmedOrNil
        return tidy
    }

    public func items() -> [ImportItem] {
        entries.filter(\.included).map { entry in
            var target = ImportTarget.newBook
            if entry.isAddedToExisting, let bookId = entry.existingMatch?.id {
                target = .existing(bookId: bookId)
            } else if entry.isImportedAsEdition, let bookId = entry.existingMatch?.id {
                target = .edition(of: bookId)
            }
            var cover = CoverChange.keep
            if entry.coverChanged, let image = entry.cover { cover = .set(image) }
            var candidate = entry.candidate
            candidate.metadata = Self.tidied(candidate.metadata)
            return ImportItem(candidate: candidate, target: target, cover: cover)
        }
    }

    public var options: ImportOptions {
        // Books from a calibre library are copied whatever else is set: nothing of
        // calibre's is ever moved out of it.
        if calibre != nil { return ImportOptions(mode: .copy) }
        return ImportOptions(mode: copyInsteadOfMove && !moveOnly ? .copy : .move)
    }
}

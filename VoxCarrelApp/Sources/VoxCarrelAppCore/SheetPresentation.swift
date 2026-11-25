/// Which sheet the window has up, given the one the model wants shown.
///
/// A sheet of one kind is never turned into a sheet of another kind in place: the window
/// that holds a sheet keeps the size it was opened at, so a large sheet shown in the place
/// of a small one would be cut off. The sheet that is up is closed first, and the other is
/// shown when it has gone.
///
/// The view calls `want` whenever what the model wants shown changes, shows `presented`,
/// and calls `didDismiss` when the sheet it was showing has closed.
public struct SheetPresentation<Sheet: Identifiable> {
    public init() {}

    /// The sheet to have up; nil for none.
    public private(set) var presented: Sheet?
    /// True from taking a sheet down until it has closed.
    private var isClosing = false

    /// True when no sheet is up, and none is on its way out.
    public var isIdle: Bool {
        presented == nil && !isClosing
    }

    /// The model wants this sheet shown now; nil for none.
    public mutating func want(_ wanted: Sheet?) {
        // Whatever is wanted when the sheet has closed is shown then.
        if isClosing { return }
        guard let presented else {
            self.presented = wanted
            return
        }
        if let wanted, wanted.id == presented.id {
            // The same sheet, with what it shows now.
            self.presented = wanted
        } else {
            self.presented = nil
            isClosing = true
        }
    }

    /// The sheet that was up has closed; `wanted` is what the model wants shown now.
    public mutating func didDismiss(wanted: Sheet?) {
        isClosing = false
        presented = wanted
    }
}

/// V5: a sheet of the library window. Sheets of one kind have one id, whatever they show.
public enum WindowSheet: Identifiable, Equatable, Sendable {
    case progress(String)
    case review(ImportReview)
    case result(ResultSummary)
    case check(LibraryCheckSummary)
    case layoutPreview(LayoutPreview)
    case seriesChoice([SeriesChoice])
    case lookup(LookupSession)
    case sendToPhone(SendSheetState)
    case mergeBooks(MergeSheetState)
    /// G23: Manage Genres.
    case manageGenres(SheetObject<GenreManager>)
    /// G14: the preview of "Update files…".
    case genreFiles(SheetObject<GenreFilesUpdate>)
    /// G29: Fill in Genres.
    case genreFill(SheetObject<GenreFillSession>)
    /// A smart shelf being made or changed.
    case shelfEditor(SheetObject<ShelfEditor>)
    /// Link Audible Account.
    case audibleLink(SheetObject<AudibleLinkSession>)
    /// Import Audible Library.
    case audibleImport(SheetObject<AudibleImportSession>)
    /// Import Kindle Library.
    case kindleImport(SheetObject<KindleImportSession>)
    /// The highlights of one book.
    case highlights(SheetObject<HighlightsSession>)
    /// Import Highlights.
    case highlightsImport(SheetObject<HighlightsImportSession>)

    public var id: String {
        switch self {
        case .progress: "progress"
        case .review: "review"
        case .result: "result"
        case .check: "check"
        case .layoutPreview: "layoutPreview"
        case .seriesChoice: "seriesChoice"
        case .lookup: "lookup"
        case .sendToPhone: "sendToPhone"
        case .mergeBooks: "mergeBooks"
        case .manageGenres: "manageGenres"
        case .genreFiles: "genreFiles"
        case .genreFill: "genreFill"
        case .shelfEditor: "shelfEditor"
        case .audibleLink: "audibleLink"
        case .audibleImport: "audibleImport"
        case .kindleImport: "kindleImport"
        case .highlights: "highlights"
        case .highlightsImport: "highlightsImport"
        }
    }
}

/// A sheet's state that is an object, which the sheet watches for itself: two are the
/// same when they are the same object.
public struct SheetObject<State: AnyObject & Sendable>: Equatable, Sendable {
    public let state: State

    public init(_ state: State) {
        self.state = state
    }

    public static func == (a: SheetObject, b: SheetObject) -> Bool {
        a.state === b.state
    }
}

extension AppModel {
    /// V5: the one sheet the window should have up now; nil for none. When several are
    /// wanted, the first of: progress, the import review, a result, the launch check,
    /// the preview of a change of folder layout, the choice between Audible series, a lookup (for the inspected book, or to
    /// add an Audible book), Send to Phone, Merge Books, Manage Genres, the preview of
    /// "Update files…", Fill in Genres, the editor of a smart shelf, Link Audible
    /// Account, Import Audible Library, Import Kindle Library, the highlights of a book,
    /// and Import Highlights.
    ///
    /// PH28: while Send to Phone is open, what it is doing is shown in its own sheet,
    /// which stays up: the progress sheet does not take its place. MG7: the same for
    /// Merge Books. G23: and for Manage Genres, whose changes are made under it, and
    /// for the editor of a smart shelf while it saves, and for the sheet of a book's
    /// highlights, whose changes are made under it.
    ///
    /// - Parameter progressDue: Whether the operation that is running has run long
    ///   enough for its progress to be shown: a short one shows no sheet.
    public func windowSheet(progressDue: Bool) -> WindowSheet? {
        if progressDue, sendSession == nil, mergeSession == nil, genreManager == nil, shelfEditor == nil,
           highlights == nil, let label = progressSheetLabel
        {
            return .progress(label)
        }
        if let review { return .review(review) }
        if let result { return .result(result) }
        if let check = libraryCheckSummary { return .check(check) }
        // FL8
        if let layoutPreview { return .layoutPreview(layoutPreview) }
        if let choices = seriesChoices { return .seriesChoice(choices) }
        if let lookup = inspectorLookup { return .lookup(lookup) }
        if let lookup = addAudibleLookup { return .lookup(lookup) }
        if let sheet = sendSheet { return .sendToPhone(sheet) }
        if let sheet = mergeSheet { return .mergeBooks(sheet) }
        if let genreManager { return .manageGenres(SheetObject(genreManager)) }
        if let genreFilesUpdate { return .genreFiles(SheetObject(genreFilesUpdate)) }
        if let genreFill { return .genreFill(SheetObject(genreFill)) }
        if let shelfEditor { return .shelfEditor(SheetObject(shelfEditor)) }
        if let audibleLink { return .audibleLink(SheetObject(audibleLink)) }
        if let audibleImport { return .audibleImport(SheetObject(audibleImport)) }
        if let kindleImport { return .kindleImport(SheetObject(kindleImport)) }
        if let highlights { return .highlights(SheetObject(highlights)) }
        if let highlightsImport { return .highlightsImport(SheetObject(highlightsImport)) }
        return nil
    }
}

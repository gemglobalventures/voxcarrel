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
    case seriesChoice([SeriesChoice])
    case lookup(LookupSession)

    public var id: String {
        switch self {
        case .progress: "progress"
        case .review: "review"
        case .result: "result"
        case .check: "check"
        case .seriesChoice: "seriesChoice"
        case .lookup: "lookup"
        }
    }
}

extension AppModel {
    /// V5: the one sheet the window should have up now; nil for none. When several are
    /// wanted, the first of: progress, the import review, a result, the launch check,
    /// the choice between Audible series, and a lookup (for the inspected book, or to
    /// add an Audible book).
    ///
    /// - Parameter progressDue: Whether the operation that is running has run long
    ///   enough for its progress to be shown: a short one shows no sheet.
    public func windowSheet(progressDue: Bool) -> WindowSheet? {
        if progressDue, let label = progressSheetLabel { return .progress(label) }
        if let review { return .review(review) }
        if let result { return .result(result) }
        if let check = libraryCheckSummary { return .check(check) }
        if let choices = seriesChoices { return .seriesChoice(choices) }
        if let lookup = inspectorLookup { return .lookup(lookup) }
        if let lookup = addAudibleLookup { return .lookup(lookup) }
        return nil
    }
}

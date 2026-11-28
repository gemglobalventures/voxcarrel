import Foundation
import VoxCarrelCore

// The Tidy list: what is untidy about the library, found across all of it. Each check
// that finds something is a line of the sidebar; choosing it lists its books in the
// ordinary list, where every command for books applies to them. A book that is fine
// as it is can be let off a check, and is then no longer listed under it.

/// What is said above the books of one check.
public struct TidyHeader: Equatable, Sendable {
    public var title: String
    /// What the check means and what can be done about it.
    public var explanation: String
    /// "12 books", or "1 book".
    public var countText: String
    /// Whether the selected books can be let off the check now.
    public var canMarkFine: Bool
    public let markFineTitle = "These Are Fine as They Are"
    public let markFineHelp = "Stop listing the selected books under this check"
    /// The commands the explanation points at, for the selected books: each is one the
    /// Book menu already has, put where the check is read. Empty for a check whose
    /// answer is an edit in the inspector.
    public var commands: [TidyCommand] = []
    /// "List the 3 Let Off Again", "List the 1 Let Off Again"; nil when none was let off.
    public var putBackTitle: String?
    public let putBackHelp = "List again the books that were marked fine as they are under this check"
    /// What extensions offer to do about all the check's books; empty when nothing is offered.
    public var actions: [ExtensionCommandItem] = []
}

/// One command above the books of a check.
public struct TidyCommand: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case merge, lookUp, showSeries, linkEditions, bringInCopy, bringInMove, convert
    }
    public var kind: Kind
    public var title: String
    public var help: String
    /// Whether it applies to the selected books now.
    public var isEnabled: Bool
    public var id: String { kind.rawValue }
}

extension AppModel {
    /// Which commands answer a check, in the order they are shown.
    static func tidyCommandKinds(for check: TidyCheck) -> [TidyCommand.Kind] {
        switch check {
        case .noAuthor, .noYear, .noDescription, .noCover, .smallCover: [.lookUp]
        case .seriesNoNumber, .seriesGap: [.showSeries]
        case .seriesSameNumber: [.showSeries, .linkEditions]
        case .sameBookTwice, .formsApart: [.merge]
        case .editionsNotLinked: [.linkEditions]
        case .outsideLibrary: [.bringInCopy, .bringInMove]
        case .oldFormat: [.convert]
        // Answered by an edit in the inspector, which is already beside the list.
        case .nameSpellings, .titleExtras: []
        }
    }

    /// The series of the one selected book, as the sidebar names it; nil when more or
    /// fewer than one book is selected, or it is in no series.
    private func seriesOfTheOne(_ chosen: Set<Int64>) -> String? {
        guard chosen.count == 1, let id = chosen.first,
              let name = rows.first(where: { $0.id == id })?.book.series, !name.isEmpty
        else { return nil }
        return name
    }

    func tidyCommands(for check: TidyCheck, chosen: Set<Int64>) -> [TidyCommand] {
        Self.tidyCommandKinds(for: check).map { kind in
            switch kind {
            case .merge:
                TidyCommand(kind: kind, title: "Merge Books…",
                            help: "Select the entries that are one book, then merge them into one",
                            isEnabled: canMergeBooks(chosen))
            case .lookUp:
                TidyCommand(kind: kind, title: "Look Up…",
                            help: chosen.count == 1 ? lookUpHelp : "Select one book to look it up",
                            isEnabled: chosen.count == 1 && canLookUp)
            case .showSeries:
                TidyCommand(kind: kind, title: "Show the Series",
                            help: "Select one book to see its whole series, where Check Series compares it with a list",
                            isEnabled: seriesOfTheOne(chosen) != nil && busyLabel == nil)
            case .linkEditions:
                TidyCommand(kind: kind, title: Self.linkEditionsTitle,
                            help: "Select the entries that are editions of one book, then link them",
                            isEnabled: canLinkEditions(chosen))
            case .bringInCopy:
                TidyCommand(kind: kind, title: Self.bringInCopyTitle,
                            help: "Copy the selected books into the library folder; the originals stay where they are",
                            isEnabled: canBringIntoLibrary(chosen))
            case .bringInMove:
                TidyCommand(kind: kind, title: Self.bringInMoveTitle,
                            help: "Move the selected books into the library folder",
                            isEnabled: canBringIntoLibrary(chosen))
            case .convert:
                TidyCommand(kind: kind, title: ConversionText.commandTitle,
                            help: "Add an EPUB beside the older ebook of each selected book",
                            isEnabled: !chosen.isEmpty && commands(for: chosen).convertToEPUB)
            }
        }
    }

    /// Does what a command above the books of a check says, for the selected books.
    public func runTidyCommand(_ kind: TidyCommand.Kind) async {
        guard let header = tidyHeader,
              header.commands.first(where: { $0.kind == kind })?.isEnabled == true else { return }
        let chosen = selection.filter { $0 > 0 }
        switch kind {
        case .merge: await beginMergeBooks(for: chosen)
        case .lookUp: beginLookup()
        case .showSeries:
            if let name = seriesOfTheOne(chosen) { sidebarSelection = .browse(.series, name) }
        case .linkEditions: await linkEditions(for: chosen)
        case .bringInCopy: await bringIntoLibrary(chosen, copying: true)
        case .bringInMove: await bringIntoLibrary(chosen, copying: false)
        case .convert: await convertToEPUB(for: chosen)
        }
    }

    /// The check the sidebar shows; nil when it shows anything else.
    var selectedTidyCheck: TidyCheck? {
        if case .tidy(let check) = sidebarSelection { return check }
        return nil
    }

    /// Whether the sidebar has anything to list under Tidy.
    public var showsTidy: Bool { !sidebar.tidy.isEmpty }

    /// How many books all the checks find between them, a book counted once for each
    /// check that finds it.
    public var tidyCount: Int { sidebar.tidy.reduce(0) { $0 + $1.count } }

    /// What is said above the books while a check is what the sidebar shows.
    public var tidyHeader: TidyHeader? {
        guard let check = selectedTidyCheck else { return nil }
        let count = rows.count
        let chosen = selection.filter { $0 > 0 }
        return TidyHeader(
            title: check.title, explanation: check.explanation,
            countText: count == 1 ? "1 book" : "\(count) books",
            canMarkFine: !chosen.isEmpty && busyLabel == nil && isLibraryOpen,
            commands: tidyCommands(for: check, chosen: chosen),
            putBackTitle: letOffCount(check) > 0 ? "List the \(letOffCount(check)) Let Off Again" : nil,
            actions: count > 0 ? tidyActions(for: check) : [])
    }

    private func letOffCount(_ check: TidyCheck) -> Int {
        sidebar.tidy.first { $0.check == check }?.letOff ?? 0
    }

    /// Lists again, under the check shown, the books that were let off it.
    public func putBackLetOff() async {
        guard let check = selectedTidyCheck, letOffCount(check) > 0, busyLabel == nil else { return }
        await perform("Updating…") { worker in
            try await worker.putBackTidy(check: check)
        }
    }

    /// Lets the selected books off the check shown: they are no longer listed under
    /// it. Nothing about the books changes.
    public func markSelectionFine() async {
        guard let check = selectedTidyCheck, tidyHeader?.canMarkFine == true else { return }
        let ids = selection.filter { $0 > 0 }.sorted()
        await perform("Updating…") { worker in
            try await worker.setTidyIgnored(true, check: check, bookIds: ids)
        }
        // A check that finds nothing more has no line to stay on.
        if !sidebar.tidy.contains(where: { $0.check == check }) { sidebarSelection = .allBooks }
    }
}

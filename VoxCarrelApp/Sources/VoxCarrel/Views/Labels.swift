import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// The words and symbols the views show for the model's values.

extension SidebarItem {
    var symbol: String {
        switch self {
        case .allBooks: "books.vertical"
        case .audiobooks: "headphones"
        case .ebooks: "book"
        case .onAudible: ExternalKind.audible.symbol
        case .onKindle: ExternalKind.kindle.symbol
        case .highlights: "highlighter"
        case .unread: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .finished: "checkmark.circle"
        case .needsAttention: "exclamationmark.triangle"
        case .browse(let field, _): field.symbol
        case .genreGroup: "tag"
        case .noGenre: "tag.slash"
        case .collection: "rectangle.stack"
        case .inbox: "tray"
        case .hidden: "eye.slash"
        case .upNext: "text.line.first.and.arrowtriangle.forward"
        case .shelf: "line.3.horizontal.decrease.circle"
        }
    }
}

extension ExternalKind {
    /// What stands for a book owned there: a cloud for Audible, the pages of a book
    /// for Kindle, which the ebook's own closed book is not mistaken for.
    var symbol: String {
        switch self {
        case .audible: "cloud"
        case .kindle: "book.pages"
        }
    }
}

extension BrowseField {
    var symbol: String {
        switch self {
        case .authors: "person.2"
        case .series: "square.stack"
        case .narrators: "waveform"
        case .genre: "tag"
        }
    }
}

extension BookSortKey {
    var title: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .series: "Series"
        case .formats: "Formats"
        case .length: "Length"
        case .dateAdded: "Date Added"
        case .status: "Status"
        case .edition: "Edition"
        case .genre: "Genre"
        }
    }
}

extension EmptyState {
    var symbol: String {
        switch self {
        case .emptyLibrary: "books.vertical"
        case .noMatches: "magnifyingglass"
        case .noAudibleBooks: "cloud"
        case .nothingUpNext: SidebarItem.upNext.symbol
        case .noHiddenBooks: SidebarItem.hidden.symbol
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .emptyLibrary: "books.empty.library"
        case .noMatches: "books.empty.noMatches"
        case .noAudibleBooks: "books.empty.onAudible"
        case .nothingUpNext: "books.empty.upNext"
        case .noHiddenBooks: "books.empty.hidden"
        }
    }
}

extension BookRow {
    /// For the button that opens the audiobook: headphones, or an arrow out of the app
    /// when it opens the book's page on the Audible website.
    var listenSymbol: String {
        opensOnAudible ? "arrow.up.right.square" : "headphones"
    }
}

extension BookRow {
    /// For the button that opens the ebook: a book, or an arrow out of the app when it
    /// opens the book in Kindle on the web.
    var readSymbol: String {
        opensOnKindle ? "arrow.up.right.square" : "book"
    }

    /// For the inspector's line that says where the book is owned: the symbol of the
    /// first place it is.
    var ownershipSymbol: String {
        (ownedKinds.first ?? .audible).symbol
    }
}

extension FileRole {
    var symbol: String {
        switch self {
        case .audio: "headphones"
        case .ebook: "book.closed"
        case .extra: "paperclip"
        }
    }
}

extension LookupSource {
    /// For a lookup result's row: where it was found.
    var symbol: String {
        switch self {
        case .openLibrary: "books.vertical"
        case .audible: "headphones"
        case .libraryOfCongress: "building.columns"
        }
    }
}

extension EditionVerdict {
    /// The colour of a lookup result's badge: green for the book's own edition, orange
    /// for another.
    var badgeTint: Color {
        switch self {
        case .sameEdition: .green
        case .differentEdition, .unknown: .orange
        }
    }

    var badgeSymbol: String {
        switch self {
        case .sameEdition: "checkmark.circle.fill"
        case .differentEdition, .unknown: "exclamationmark.circle.fill"
        }
    }
}

extension EditionKind {
    /// For a book's edition label where there is no room for its words.
    var symbol: String {
        switch self {
        case .unabridged: "text.book.closed"
        case .abridged: "scissors"
        case .dramatised: "theatermasks"
        case .notKnown: "questionmark"
        }
    }
}

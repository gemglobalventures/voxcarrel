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
        case .unread: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .finished: "checkmark.circle"
        case .needsAttention: "exclamationmark.triangle"
        case .browse(let field, _): field.symbol
        case .collection: "rectangle.stack"
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
        }
    }
}

extension EmptyState {
    var symbol: String {
        switch self {
        case .emptyLibrary: "books.vertical"
        case .noMatches: "magnifyingglass"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .emptyLibrary: "books.empty.library"
        case .noMatches: "books.empty.noMatches"
        }
    }
}

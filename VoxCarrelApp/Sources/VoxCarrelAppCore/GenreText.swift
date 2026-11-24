import Foundation
import VoxCarrelCore

/// A book's genres as the one line of text the genre field shows and takes.
///
/// A stand-in: it goes when the field holds one chip for each genre, chosen from the
/// library's list.
enum GenreText {
    /// The genres as they are shown: joined with ", ".
    static func shown(_ genres: [String]) -> String {
        genres.joined(separator: ", ")
    }

    /// The genres that typed text comes to. Text made only of the built-in names, as
    /// `shown` joins them, is those names in that order; anything else is read by the
    /// mapping, whole, as a file's genre tag is.
    static func genres(typed text: String) -> [String] {
        let pieces = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { String($0).trimmed }.filter { !$0.isEmpty }
        let builtIn = pieces.compactMap { BuiltInGenre.named($0)?.name }
        if !pieces.isEmpty, builtIn.count == pieces.count { return GenreName.distinct(builtIn) }
        return GenreMapping.map(.text(text)).names
    }
}

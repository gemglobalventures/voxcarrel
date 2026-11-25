import Foundation
import VoxCarrelCore

/// What converting one book to EPUB came to.
public struct EPUBConversionOutcome: Equatable, Sendable {
    public var bookId: Int64
    public var result: Result

    public enum Result: Equatable, Sendable {
        /// An EPUB was added to the book; the name of its file.
        case converted(fileName: String)
        /// The converter could not make one, and why.
        case notConverted(ConversionError)
        /// Something else stood in the way, as a sentence to show.
        case problem(String)
    }

    public init(bookId: Int64, result: Result) {
        self.bookId = bookId
        self.result = result
    }
}

/// Every sentence Convert to EPUB shows.
public enum ConversionText {
    /// The command, in the Book menu and a book's context menu.
    public static let commandTitle = "Convert to EPUB"

    /// Said in place of converting when calibre's converter is not on this Mac.
    public static let needsCalibre =
        "Converting needs calibre installed on this Mac. VoxCarrel uses calibre's own converter, and has none "
        + "of its own. Get calibre from calibre-ebook.com, then try again."

    /// What the window says while these books are converted.
    public static func busy(titles: [String]) -> String {
        titles.count == 1 ? "Converting “\(titles[0])” to EPUB…" : "Converting \(titles.count) books to EPUB…"
    }

    /// How converting went, for each book that was tried, by its title. Nil when no
    /// book was tried, which leaves nothing to say.
    public static func result(_ outcomes: [(title: String, result: EPUBConversionOutcome.Result)]) -> String? {
        guard let first = outcomes.first else { return nil }
        if outcomes.count == 1 {
            switch first.result {
            case .converted(let fileName):
                return "Added “\(fileName)” to the book. The original file is still there."
            case .notConverted(let error):
                return "“\(first.title)” could not be converted: \(reason(error, alone: true))."
            case .problem(let said):
                return "“\(first.title)” could not be converted. \(said)"
            }
        }
        let failed = outcomes.filter { outcome in
            if case .converted = outcome.result { return false }
            return true
        }
        let total = outcomes.count
        guard !failed.isEmpty else {
            return "Converted \(total) books to EPUB. The original files are still there."
        }
        let list = failed.map { "“\($0.title)” (\(shortReason($0.result)))" }.joined(separator: ", ")
        let converted = total - failed.count
        guard converted > 0 else { return "None of the \(total) books was converted to EPUB. Not converted: \(list)." }
        return "Converted \(converted) of \(total) books to EPUB. Not converted: \(list)."
    }

    /// Why a book among several was not converted, short enough to stand in brackets.
    private static func shortReason(_ result: EPUBConversionOutcome.Result) -> String {
        switch result {
        case .converted: ""
        case .notConverted(let error): reason(error, alone: false)
        case .problem(let said): unstopped(said)
        }
    }

    /// Why the converter made no EPUB, as the end of a sentence with no full stop.
    /// - Parameter alone: The book is the only one, so there is room to say more.
    private static func reason(_ error: ConversionError, alone: Bool) -> String {
        switch error {
        case .protected:
            alone
                ? "it is protected against copying, which calibre's converter cannot read"
                : "it is protected against copying"
        case .failed(let said): "the converter stopped: \(unstopped(said))"
        case .tookTooLong: "the converter took too long"
        case .notAnEPUB: "what the converter made is not an EPUB that can be read"
        case .noConverter: "calibre's converter was not found on this Mac"
        case .nothingToConvert: "it has no ebook an EPUB can be made of"
        }
    }

    /// What was said, without the space and full stops it ends with: the sentence it
    /// goes into ends with a full stop of its own.
    private static func unstopped(_ said: String) -> String {
        var text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

extension AppModel {
    /// Makes an EPUB of the ebook of each selected book that has one to convert.
    public func convertToEPUB() async {
        await convertToEPUB(for: selection)
    }

    /// The same for these books, which need not be the selection. A book among them
    /// that has nothing to convert is passed over, and nothing is said of it. Does
    /// nothing when none has. Without calibre's converter nothing is converted, and
    /// the alert says what is needed.
    public func convertToEPUB(for ids: Set<Int64>) async {
        // SV7, FL12, and as the command is offered: not while something else runs.
        guard commands(for: ids).convertToEPUB, filesCanChange else { return }
        let offered = rows.filter { ids.contains($0.id) && $0.canConvertToEPUB }
        guard !offered.isEmpty else { return }
        let converter = ebookConverter
        guard converter.isAvailable else {
            alert = ConversionText.needsCalibre
            return
        }
        let bookIds = offered.map(\.id)
        let titles = Dictionary(offered.map { ($0.id, $0.book.title) }) { first, _ in first }
        await perform(ConversionText.busy(titles: offered.map(\.book.title))) { worker in
            let outcomes = await worker.convertToEPUB(bookIds: bookIds, with: converter)
            if let text = ConversionText.result(outcomes.map { (titles[$0.bookId] ?? "", $0.result) }) {
                self.alert = text
            }
        }
    }
}

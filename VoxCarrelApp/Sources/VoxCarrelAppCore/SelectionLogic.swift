import Foundation

/// How clicking a book in the grid changes the selection.
public enum SelectionLogic {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
    }

    /// The selection and anchor after clicking `id` in a list shown in `order`.
    ///
    /// A plain click selects only that book and makes it the anchor. A command-click adds
    /// or removes it and makes it the anchor. A shift-click selects everything from the
    /// anchor to it, in place of what was selected, and keeps the anchor; with command
    /// held as well, the range is added to what was selected. A shift-click with no
    /// anchor, or with an anchor or a book that is not in `order`, is a plain click.
    public static func click(
        _ id: Int64, modifiers: Modifiers, order: [Int64],
        selection: Set<Int64>, anchor: Int64?
    ) -> (selection: Set<Int64>, anchor: Int64?) {
        if modifiers.contains(.shift), let anchor,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = Set(order[min(from, to)...max(from, to)])
            return (modifiers.contains(.command) ? selection.union(range) : range, anchor)
        }
        if modifiers.contains(.command), !modifiers.contains(.shift) {
            return (selection.symmetricDifference([id]), id)
        }
        return ([id], id)
    }
}

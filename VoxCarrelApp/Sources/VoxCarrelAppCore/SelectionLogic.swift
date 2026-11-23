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
        clicked(id, modifiers: modifiers, order: order, selection: selection, anchor: anchor)
    }

    /// The same among the items of a list that is grouped by series, where an item is
    /// a book or a series group.
    public static func click(
        _ id: ItemID, modifiers: Modifiers, among order: [ItemID],
        selection: Set<ItemID>, anchor: ItemID?
    ) -> (selection: Set<ItemID>, anchor: ItemID?) {
        clicked(id, modifiers: modifiers, order: order, selection: selection, anchor: anchor)
    }

    private static func clicked<ID: Hashable>(
        _ id: ID, modifiers: Modifiers, order: [ID],
        selection: Set<ID>, anchor: ID?
    ) -> (selection: Set<ID>, anchor: ID?) {
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

    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// The book an arrow key moves to, in a grid of `columns` columns that shows the
    /// books in `order`, row after row. Nil only when there are no books.
    ///
    /// The move starts from the anchor when it is one of the selected books; otherwise
    /// from the selected book furthest the way the arrow points. Left and right step
    /// along the order, up and down by a whole row. At an edge the book stays the same,
    /// except that down from above a short last row goes to the last book. With nothing
    /// selected, right and down give the first book, left and up the last.
    public static func move(
        _ direction: Direction, columns: Int, order: [Int64], selection: Set<Int64>, anchor: Int64?
    ) -> Int64? {
        moved(direction, columns: columns, order: order, selection: selection, anchor: anchor)
    }

    /// The same among the items of a list that is grouped by series: a group is one cell.
    public static func move(
        _ direction: Direction, columns: Int, among order: [ItemID], selection: Set<ItemID>, anchor: ItemID?
    ) -> ItemID? {
        moved(direction, columns: columns, order: order, selection: selection, anchor: anchor)
    }

    private static func moved<ID: Hashable>(
        _ direction: Direction, columns: Int, order: [ID], selection: Set<ID>, anchor: ID?
    ) -> ID? {
        guard let first = order.first, let last = order.last else { return nil }
        let forwards = direction == .right || direction == .down

        var start = anchor.flatMap { selection.contains($0) ? order.firstIndex(of: $0) : nil }
        if start == nil {
            start = forwards ? order.lastIndex(where: selection.contains) : order.firstIndex(where: selection.contains)
        }
        guard let start else { return forwards ? first : last }

        let columns = max(1, columns)
        let end = order.count - 1
        let target: Int
        switch direction {
        case .left:
            target = max(start - 1, 0)
        case .right:
            target = min(start + 1, end)
        case .up:
            target = start >= columns ? start - columns : start
        case .down:
            if start + columns <= end {
                target = start + columns
            } else {
                target = start / columns < end / columns ? end : start
            }
        }
        return order[target]
    }
}

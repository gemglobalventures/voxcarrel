import Foundation
import VoxCarrelCore

// Group by Series in the model (plan 10, Task 2). GS10–GS24.
//
// `rows` and `selection` are what they always were: books, and book ids. `items` is the
// rows as the list and the grid draw them, and the selection is translated to and from
// the ids of items only where the table and the grid need it. Every command still acts
// on book ids, so a selected group is its books selected.
//
// One thing is never allowed: a selected book out of sight in a closed group, part of
// its group selected and part not. A closed group is selected whole or not at all
// (GS13a), so no command acts on a book the owner cannot see is selected. In the grid,
// where a group is one stack, a stack only some of whose books are selected is drawn as
// selected in part (`isPartlySelected`); the model never selects the rest itself.

/// GS19: where Back goes from a series that was opened from its group.
struct SeriesReturn: Equatable {
    /// The list that was shown, and the search text it was shown with.
    var item: SidebarItem
    var search: String
    /// The series that was opened: its group is what is selected on the way back.
    var series: String
    /// GS13: whether its group was open in the list, which is how it is left on the
    /// way back.
    var wasOpen: Bool
}

extension AppModel {
    // MARK: GS11 Items

    /// GS11: whether a list of these books may be grouped: not a single series' own
    /// view, not the Inbox, and not the results of a search.
    static func allowsGrouping(_ item: SidebarItem, search: String) -> Bool {
        switch item {
        case .browse(.series, _), .inbox: false
        default: search.trimmed.isEmpty
        }
    }

    /// The series groups among the items; none unless `isGrouping`.
    var groups: [SeriesGroup] {
        items.compactMap { item in
            if case .series(let group) = item { return group }
            return nil
        }
    }

    func group(named name: String) -> SeriesGroup? {
        for case .series(let group) in items where group.name == name { return group }
        return nil
    }

    /// The group this book is shown in; nil for a book that is an item of its own.
    private func group(holding id: Int64) -> SeriesGroup? {
        groups.first { $0.books.contains { $0.id == id } }
    }

    /// The items as the list shows them, top to bottom: an open group lies before its
    /// own books, and a closed group's books are not there.
    private var listOrder: [ItemID] {
        items.flatMap { item -> [ItemID] in
            switch item {
            case .book(let row): [.book(row.id)]
            case .series(let group):
                [group.id] + (openGroups.contains(group.name) ? group.books.map { .book($0.id) } : [])
            }
        }
    }

    /// The books these items stand for: the books named, and every book of the groups named.
    public func bookIds(of ids: Set<ItemID>) -> Set<Int64> {
        var books = Set<Int64>()
        for id in ids {
            switch id {
            case .book(let book): books.insert(book)
            case .series(let name): books.formUnion(group(named: name)?.books.map(\.id) ?? [])
            }
        }
        return books
    }

    private func selectedCount(in group: SeriesGroup) -> Int {
        group.books.filter { selection.contains($0.id) }.count
    }

    /// Whether some of the group's books are selected and some are not. Never true of
    /// a closed group in the list (GS13a). The grid draws a group as one stack, open or
    /// not, and shows with this a stack only some of whose books are selected: the
    /// model never selects the rest on its own account; a click on the stack does.
    public func isPartlySelected(_ group: SeriesGroup) -> Bool {
        let count = selectedCount(in: group)
        return count > 0 && count < group.books.count
    }

    // MARK: GS13 Open groups

    /// GS13: opens or closes the group of this name. A name no group has is not kept.
    ///
    /// GS13a: closing a group only some of whose books are selected selects them all,
    /// as `select(_:)` would: with unsaved changes that asks first, nothing is selected
    /// meanwhile, and the group stays open.
    public func setGroup(_ name: String, open: Bool) {
        guard let group = group(named: name) else { return }
        if open {
            openGroups.insert(name)
            return
        }
        guard openGroups.contains(name) else { return }
        if isPartlySelected(group) {
            select(selection.union(group.books.map(\.id)))
            guard !isPartlySelected(group) else { return }
        }
        openGroups.remove(name)
    }

    /// GS13a: opens every closed group that holds some selected books and not all of
    /// its books selected. Run whenever the items or the selection change.
    func openPartlySelectedGroups() {
        guard isGrouping, !selection.isEmpty else { return }
        for group in groups where !openGroups.contains(group.name) && isPartlySelected(group) {
            openGroups.insert(group.name)
        }
    }

    // MARK: GS14, GS15 The selection as items

    /// GS14: the selection as the table and the grid know it. A selected book that is
    /// not inside a closed group is itself; a group all of whose books are selected is
    /// the group, and, when it is open, each of its books as well.
    public var itemSelection: Set<ItemID> {
        var ids = Set(selection.map(ItemID.book))
        guard isGrouping else { return ids }
        for group in groups {
            let count = selectedCount(in: group)
            guard count > 0 else { continue }
            if count == group.books.count { ids.insert(group.id) }
            if !openGroups.contains(group.name) {
                // Never only some of them: `openPartlySelectedGroups`.
                for book in group.books { ids.remove(.book(book.id)) }
            }
        }
        return ids
    }

    /// GS15: selects the books named and every book of the groups named, as
    /// `select(_:)` does: the unsaved-changes rules are its own.
    ///
    /// What is given is compared with `itemSelection` as it was, because a table that
    /// shows an open group selected whole names the group and its books, and takes one
    /// name away to deselect:
    /// - a group no longer named loses its books, except those still named themselves;
    ///   and loses them all when nothing else changed, which is a click that
    ///   deselects the group's own row;
    /// - a group still named, some of whose books were named and are not now, is left
    ///   with the books that still are: one of its books was deselected.
    public func selectItems(_ ids: Set<ItemID>) {
        let previous = itemSelection
        var named = Set<Int64>()
        var names = Set<String>()
        for id in ids {
            switch id {
            case .book(let book): named.insert(book)
            case .series(let name): names.insert(name)
            }
        }
        let removed = previous.subtracting(ids)
        let onlyGroupsRemoved = ids.isSubset(of: previous) && removed.allSatisfy { id in
            if case .series = id { true } else { false }
        }
        var books = named
        for group in groups {
            let own = Set(group.books.map(\.id))
            if names.contains(group.name) {
                let dropped = own.filter { previous.contains(.book($0)) && !named.contains($0) }
                if previous.contains(group.id), !dropped.isEmpty, dropped.count < own.count { continue }
                books.formUnion(own)
            } else if onlyGroupsRemoved, previous.contains(group.id) {
                books.subtract(own)
            }
        }
        select(books)
    }

    // MARK: GS16 Clicks

    /// Where a shift-click among the items starts: the group that was clicked last, or
    /// the book; a book that is out of sight in a closed group is its group.
    private var itemAnchor: ItemID? {
        guard let anchor else { return nil }
        if let groupAnchor, groupAnchor.book == anchor, group(named: groupAnchor.name) != nil {
            return .series(groupAnchor.name)
        }
        if let group = group(holding: anchor), !openGroups.contains(group.name) { return group.id }
        return .book(anchor)
    }

    /// Asks for these books to be the selection, with the group as where a
    /// shift-click starts: its first book stands for it as the anchor.
    private func requestSelection(_ ids: Set<Int64>, anchoredAt group: SeriesGroup) {
        guard let first = group.books.first?.id else { return }
        groupAnchor = (group.name, first)
        requestSelection(ids, anchor: first)
    }

    /// GS16: a click in the grid on a book or on a series' stack.
    ///
    /// On a book it is `click(_:modifiers:)`. On a group, a plain click selects exactly
    /// its books and a Command-click adds them all, or takes them all away when all
    /// were selected. A Shift-click, on either, selects the items from the anchor to
    /// the one clicked, in the order the list shows them (an open group before its own
    /// books), each group standing for all its books; with Command as well the range
    /// is added to what was selected. With no anchor it is a plain click.
    public func clickItem(_ id: ItemID, modifiers: SelectionLogic.Modifiers) {
        let order = listOrder
        if modifiers.contains(.shift), let from = itemAnchor, order.contains(from), order.contains(id) {
            let range = SelectionLogic.click(id, modifiers: .shift, among: order, selection: [], anchor: from)
            let books = bookIds(of: range.selection)
            requestSelection(modifiers.contains(.command) ? selection.union(books) : books, anchor: anchor)
            return
        }
        switch id {
        case .book(let book):
            // A shift-click that has nowhere to start from is a plain click.
            click(book, modifiers: modifiers.contains(.shift) ? [] : modifiers)
        case .series(let name):
            guard let group = group(named: name) else { return }
            let own = Set(group.books.map(\.id))
            if modifiers.contains(.command), !modifiers.contains(.shift) {
                let all = own.isSubset(of: selection)
                requestSelection(all ? selection.subtracting(own) : selection.union(own), anchoredAt: group)
            } else {
                requestSelection(own, anchoredAt: group)
            }
        }
    }

    // MARK: GS17 Opening

    /// GS17: a double-click, or Return. One book is opened, as ever. One group, named
    /// alone or with books of its own, opens its series (`openSeries`). Anything else
    /// is several books, which are not opened at once.
    public func openItems(_ ids: Set<ItemID>) {
        var names: [String] = []
        var books = Set<Int64>()
        for id in ids {
            switch id {
            case .book(let book): books.insert(book)
            case .series(let name): names.append(name)
            }
        }
        if names.count == 1, let group = group(named: names[0]), books.isSubset(of: group.books.map(\.id)) {
            openSeries(group.name)
        } else {
            openOne(of: bookIds(of: ids))
        }
    }

    // MARK: GS18 Arrow keys

    /// GS18: an arrow key among the items, which are shown in `columns` columns: as
    /// `moveSelection`, with a group as one cell. Selects only the item the arrow
    /// leads to and returns it; nil when there are no items, or the move is waiting
    /// for an answer about unsaved changes.
    ///
    /// In one column of the list, an open group's books are steps between the group
    /// and the item after it. In the grid a group is one cell, open or not, however
    /// few columns the grid has.
    @discardableResult
    public func moveItemSelection(_ direction: SelectionLogic.Direction, columns: Int) -> ItemID? {
        let asList = columns <= 1 && viewMode != .grid
        let order = asList ? listOrder : items.map(\.id)
        var from = itemAnchor
        // A book of an open group is not a cell of the grid: its group is.
        if let start = from, case .book(let book) = start, !order.contains(start) {
            from = group(holding: book)?.id
        }
        var selected = itemSelection
        if !asList {
            // A stack that is selected only in part is a selected cell all the same.
            for group in groups where isPartlySelected(group) { selected.insert(group.id) }
        }
        guard
            let target = SelectionLogic.move(
                direction, columns: columns, among: order, selection: selected, anchor: from)
        else { return nil }
        let wanted: Set<Int64>
        switch target {
        case .book(let book):
            wanted = [book]
            requestSelection(wanted, anchor: book)
        case .series(let name):
            guard let group = group(named: name) else { return nil }
            wanted = Set(group.books.map(\.id))
            requestSelection(wanted, anchoredAt: group)
        }
        return selection == wanted ? target : nil
    }

    // MARK: GS22 Context menus

    /// The books a context menu opened on this item is for: the selection when the
    /// book, or the whole of the group, is part of it; otherwise the book alone, or
    /// the group's books.
    public func contextTarget(forItem id: ItemID) -> Set<Int64> {
        switch id {
        case .book(let book):
            return contextTarget(for: book)
        case .series:
            let own = bookIds(of: [id])
            return !own.isEmpty && own.isSubset(of: selection) ? selection : own
        }
    }

    /// GS22: a context menu is being opened on this item. On a book it is
    /// `contextClick`. A group that is not selected whole becomes the selection, so
    /// that what the menu acts on is what is seen to be selected. While there are
    /// unsaved changes the selection is left alone, and no question is asked; the menu
    /// still acts on `contextTarget(forItem:)`.
    public func contextClickItem(_ id: ItemID) {
        switch id {
        case .book(let book):
            contextClick(book)
        case .series(let name):
            guard let group = group(named: name), let first = group.books.first?.id else { return }
            let own = Set(group.books.map(\.id))
            guard !own.isSubset(of: selection), !hasUnsavedChanges else { return }
            groupAnchor = (name, first)
            applySelection(own, anchor: first)
        }
    }

    // MARK: GS20, GS21

    /// GS20: what the list should scroll to when it has been made again
    /// (`itemsVersion`): the book `scrollTarget` names, or its group when the book is
    /// out of sight in a closed group, when the whole group is selected, and in the
    /// grid, where the group is one stack; nil when there is none.
    public var itemScrollTarget: ItemID? {
        guard let book = scrollTarget else { return nil }
        if isGrouping, let group = group(holding: book),
           viewMode == .grid || !openGroups.contains(group.name) || !isPartlySelected(group) {
            return group.id
        }
        return .book(book)
    }

    /// GS21: whether any book of the group has edits not yet saved.
    public func editedMark(for group: SeriesGroup) -> Bool {
        let edited = editedBookIds
        return !edited.isEmpty && group.books.contains { edited.contains($0.id) }
    }

    // MARK: GS19 Opening a series, and going back

    /// GS19: shows the series under Browse ▸ Series, as choosing it in the sidebar
    /// does (the same question about unsaved changes is asked), with no search in the
    /// way, and remembers the list it was opened from for `goBackFromSeries`.
    public func openSeries(_ name: String) {
        let target = SidebarItem.browse(.series, name)
        guard sidebarSelection != target, sidebar.contains(target) else { return }
        let from = SeriesReturn(
            item: sidebarSelection, search: searchText, series: name, wasOpen: openGroups.contains(name))
        searchText = ""
        sidebarSelection = target
        seriesReturn = from
    }

    /// The way back, while the series it leads from is what the sidebar shows.
    private var currentReturn: SeriesReturn? {
        guard let seriesReturn, sidebarSelection == .browse(.series, seriesReturn.series) else { return nil }
        return seriesReturn
    }

    /// The list Back leads to: the one remembered, or All Books when that is no
    /// longer in the sidebar.
    private func destination(of back: SeriesReturn) -> SidebarItem {
        sidebar.contains(back.item) ? back.item : .allBooks
    }

    /// GS19: what the Back button above a series says: the name of the list the
    /// series was opened from, "All Books". Nil when the series shown was not opened
    /// from a group, or the owner has chosen in the sidebar since.
    public var seriesBackTitle: String? {
        currentReturn.map { title(of: destination(of: $0)) }
    }

    /// GS19: goes back to the list the series was opened from, with the search text
    /// it had, as choosing that list in the sidebar does: the same question about
    /// unsaved changes is asked, and Cancel leaves the series, and the way back, as
    /// they are. When the list is shown the series' group is selected, so it is what
    /// the list scrolls to; with unsaved changes the selection is left as it is.
    /// Does nothing unless `seriesBackTitle` is not nil.
    public func goBackFromSeries() {
        guard let back = currentReturn else { return }
        let item = destination(of: back)
        isGoingBack = true
        searchText = back.search
        sidebarSelection = item
        isGoingBack = false
        returnSelection = SeriesReturn(item: item, search: back.search, series: back.series, wasOpen: back.wasOpen)
    }

    /// GS19: the owner has chosen in the sidebar: there is no way back, and nothing
    /// waiting to be selected.
    func forgetSeriesReturn() {
        seriesReturn = nil
        returnSelection = nil
    }

    /// GS19: the rows have been read. When they are those of the list that was gone
    /// back to, the books of the series that are among them are selected: its group,
    /// closed, where the list is grouped. With unsaved changes the selection is left
    /// as it is; `orWait` then keeps the series waiting for the next time the rows are
    /// read, which is when a save that was asked for on the way back has ended.
    /// GS13: the group is open or closed as it was left.
    func selectReturnedSeries(orWait: Bool = false) {
        guard let back = returnSelection else { return }
        guard shown.item == back.item, shown.search == back.search else {
            returnSelection = nil
            return
        }
        seriesReturn = nil
        guard !hasUnsavedChanges else {
            if !orWait { returnSelection = nil }
            return
        }
        returnSelection = nil
        let books = rows.filter { !$0.isMissing && $0.book.series == back.series }.map(\.id)
        guard let first = books.first else { return }
        if let group = group(named: back.series), let leading = group.books.first?.id {
            groupAnchor = (group.name, leading)
            applySelection(Set(books), anchor: leading)
            // GS13: as it was left. Whatever was selected in the series' own view may
            // have opened it meanwhile (GS13a); all of it is selected now.
            if !back.wasOpen { openGroups.remove(group.name) }
        } else {
            applySelection(Set(books), anchor: first)
        }
        seriesReturnCount += 1
    }
}

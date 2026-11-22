import SwiftUI
import VoxCarrelAppCore

/// G5: the Book menu's commands, for the books a context menu was opened on. Plan 9: for
/// a book the library does not have, that book's three actions and nothing else.
struct BookContextMenu: View {
    let model: AppModel
    /// From `AppModel.contextTarget(for:)` in the grid; the rows the table names in the list.
    let ids: Set<Int64>

    var body: some View {
        if let actions = model.missingActions(for: ids) {
            MissingBookMenuItems(model: model, actions: actions, ids: ids)
        } else {
            BookCommandItems(model: model, ids: ids, showsShortcuts: false)
        }
    }
}

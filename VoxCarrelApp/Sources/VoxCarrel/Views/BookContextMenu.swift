import SwiftUI
import VoxCarrelAppCore

/// G5: the Book menu's commands, for the books a context menu was opened on.
struct BookContextMenu: View {
    let model: AppModel
    /// From `AppModel.contextTarget(for:)` in the grid; the rows the table names in the list.
    let ids: Set<Int64>

    var body: some View {
        BookCommandItems(model: model, ids: ids, showsShortcuts: false)
    }
}

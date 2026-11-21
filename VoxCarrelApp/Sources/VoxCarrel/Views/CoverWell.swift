import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxCarrelAppCore

/// I5: the draft's cover. An image dropped on it becomes the cover; its context menu
/// chooses one from a file, or removes it. Nothing is written until Save.
struct CoverWell: View {
    /// The tallest the cover is shown, in points.
    static let side: CGFloat = 180
    private static let cornerRadius: CGFloat = 6

    @Environment(AppModel.self) private var model
    let row: BookRow
    let cover: DraftCover
    @State private var isTargeted = false

    var body: some View {
        Group {
            switch cover {
            case .stored:
                CoverView(row: row, maxSide: Self.side, cornerRadius: Self.cornerRadius)
            case .chosen(let data):
                DataCover(data: data, maxSide: Self.side, cornerRadius: Self.cornerRadius)
                    .equatable()
            case .none:
                CoverPlaceholder(row: row, side: Self.side, cornerRadius: Self.cornerRadius)
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .frame(maxWidth: .infinity)
        .frame(height: Self.side)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .png, .jpeg, .image], isTargeted: $isTargeted) { providers in
            take(providers)
        }
        .contextMenu {
            Button("Choose Image…") {
                Panels.chooseCover(for: model)
            }
            .accessibilityIdentifier("inspector.cover.choose")
            Button("Remove Cover") {
                model.removeCover()
            }
            .disabled(!model.canRemoveCover)
            .accessibilityIdentifier("inspector.cover.remove")
        }
        .help("Drop a JPEG or PNG image here to change the cover, or Control-click for more.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cover")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("inspector.cover")
    }

    /// Hands what was dropped to the model: files (which decides whether one of them
    /// is a cover or they are books to import), or an image's data.
    private func take(_ providers: [NSItemProvider]) -> Bool {
        let model = model
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in files {
                    if let url = await Self.fileURL(from: provider) { urls.append(url) }
                }
                await model.dropOnCover(urls)
            }
            return true
        }
        let types: [UTType] = [.png, .jpeg, .image]
        guard let provider = providers.first,
              let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })
        else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in model.setCover(data: data) }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

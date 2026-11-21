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
                ChosenCover(data: data, cornerRadius: Self.cornerRadius)
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
        .help("Drop an image here to change the cover, or Control-click for more.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cover")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("inspector.cover")
    }

    /// Hands the first dropped thing to the model: a file, or an image's data.
    private func take(_ providers: [NSItemProvider]) -> Bool {
        let model = model
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in model.setCover(from: url) }
            }
            return true
        }
        let types: [UTType] = [.png, .jpeg, .image]
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return false
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in model.setCover(data: data) }
        }
        return true
    }
}

/// A cover chosen and not yet saved, drawn from its data.
private struct ChosenCover: View, Equatable {
    let data: Data
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
        } else {
            shape.fill(.quaternary)
                .aspectRatio(CoverPlaceholder.aspectRatio, contentMode: .fit)
        }
    }
}

import SwiftUI

/// A book's genres, one to a line, each with a button that takes it away, and a box to
/// add one by name. A plain stand-in until the field shows chips with suggestions: it
/// is handed everything it shows, and asks the model nothing itself.
struct GenreChipsField: View {
    struct Chip: Identifiable {
        var name: String
        /// Said after the name: "2 of 3 books" for a genre only some books have.
        var detail: String?

        var id: String { name }
    }

    let chips: [Chip]
    /// Said under the genres: the wording they came in, when it differs.
    let note: String?
    let identifier: String
    let add: (String) -> Void
    let remove: (String) -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(chips) { chip in
                HStack(spacing: 4) {
                    Text(chip.detail.map { "\(chip.name) (\($0))" } ?? chip.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        remove(chip.name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(chip.name)")
                    .accessibilityIdentifier("\(identifier).remove.\(chip.name)")
                }
            }
            TextField(text: $typed, prompt: Text("Add a genre")) {
                Text("Add a genre")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                add(typed)
                typed = ""
            }
            .accessibilityIdentifier("\(identifier).add")
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

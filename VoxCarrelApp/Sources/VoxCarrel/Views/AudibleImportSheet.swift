import SwiftUI
import VoxCarrelAppCore

// Import Audible Library: the account's library as it is read, and what bringing it in
// would do. Nothing in the library changes until Import. Everything said and every
// "can" is the session's; it closes the sheet itself.

/// The sheet, by the session's phase.
struct AudibleImportSheet: View {
    let session: AudibleImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("audible.import.heading")

            switch session.phase {
            case .reading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("audible.import.spinner")
                    Text(session.readingText)
                        .accessibilityIdentifier("audible.import.reading")
                }
            case .review:
                review
            case .failed:
                if let problem = session.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("audible.import.problem")
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(session.closeTitle) {
                    session.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("audible.import.cancel")
                if session.phase == .review {
                    Button(session.importTitle) {
                        Task { await session.apply() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canImport)
                    .accessibilityIdentifier("audible.import.apply")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }

    // MARK: The review

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = session.summary {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("audible.import.summary")
            }
            ForEach(Array(session.lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("audible.import.line.\(index)")
            }
        }
        if !session.titlesToAdd.isEmpty {
            AudibleTitleList(
                heading: session.addTitle, titles: session.titlesToAdd, more: session.moreToAdd,
                identifier: "audible.import.toAdd")
        }
        if !session.titlesToMark.isEmpty {
            AudibleTitleList(
                heading: session.markTitle, titles: session.titlesToMark, more: session.moreToMark,
                identifier: "audible.import.toMark")
        }
        if session.canImport {
            Text(session.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("audible.import.note")
        }
    }
}

/// A list of titles that scrolls, under its heading: handed what it shows.
private struct AudibleTitleList: View {
    let heading: String
    let titles: [String]
    /// "and 120 more" when the list was cut short.
    let more: String?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                        Text(title)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let more {
                        Text(more)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            // A short list is as tall as it is; a long one scrolls.
            .frame(height: min(CGFloat(titles.count + (more == nil ? 0 : 1)) * 20 + 16, 150))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .accessibilityIdentifier(identifier)
        }
    }
}

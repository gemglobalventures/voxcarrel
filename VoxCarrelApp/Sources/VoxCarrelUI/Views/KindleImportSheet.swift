import SwiftUI
import VoxCarrelAppCore

// Import Kindle Library: the account's Kindle library as it is read, and what bringing
// it in would do. Nothing in the library changes until Import. Everything said and
// every "can" is the session's; it closes the sheet itself.

/// The sheet, by the session's phase.
struct KindleImportSheet: View {
    let session: KindleImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("kindle.import.heading")
                Text(session.source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kindle.import.source")
            }

            switch session.phase {
            case .reading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("kindle.import.spinner")
                    Text(session.readingText)
                        .accessibilityIdentifier("kindle.import.reading")
                }
            case .review:
                review
            case .failed:
                if let problem = session.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kindle.import.problem")
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(session.closeTitle) {
                    session.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("kindle.import.cancel")
                if session.phase == .review {
                    Button(session.importTitle) {
                        Task { await session.apply() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canImport)
                    .accessibilityIdentifier("kindle.import.apply")
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
                    .accessibilityIdentifier("kindle.import.summary")
            }
            ForEach(Array(session.lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kindle.import.line.\(index)")
            }
        }
        if !session.titlesToAdd.isEmpty {
            AudibleTitleList(
                heading: session.addTitle, titles: session.titlesToAdd, more: session.moreToAdd,
                identifier: "kindle.import.toAdd")
        }
        if !session.titlesToMark.isEmpty {
            AudibleTitleList(
                heading: session.markTitle, titles: session.titlesToMark, more: session.moreToMark,
                identifier: "kindle.import.toMark")
        }
        if session.canImport {
            Text(session.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kindle.import.note")
        }
    }
}

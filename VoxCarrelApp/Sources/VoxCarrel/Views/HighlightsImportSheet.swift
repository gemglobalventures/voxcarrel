import SwiftUI
import VoxCarrelAppCore

// Import Highlights: what will be read, the reading as it goes, and what bringing the
// highlights in would do. Nothing in the library changes until Import. Everything said
// and every "can" is the session's; it closes the sheet itself.

/// The sheet, by the session's phase.
struct HighlightsImportSheet: View {
    let session: HighlightsImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("highlights.import.heading")

            switch session.phase {
            case .ready:
                ready
            case .reading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("highlights.import.spinner")
                    if let progress = session.progressText {
                        Text(progress)
                            .monospacedDigit()
                            .accessibilityIdentifier("highlights.import.reading")
                    }
                }
            case .review:
                review
            case .failed:
                problem
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(session.closeTitle) {
                    session.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("highlights.import.cancel")
                if session.phase == .ready {
                    Button(session.startTitle) {
                        session.start()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canStart)
                    .accessibilityIdentifier("highlights.import.start")
                }
                if session.phase == .review {
                    Button(session.importTitle) {
                        Task { await session.apply() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canImport)
                    .accessibilityIdentifier("highlights.import.apply")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }

    // MARK: Before reading

    @ViewBuilder private var ready: some View {
        if session.sources.isEmpty {
            problem
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.sourcesTitle)
                ForEach(Array(session.sources.enumerated()), id: \.offset) { index, source in
                    Label(source, systemImage: "checkmark")
                        .font(.callout)
                        .accessibilityIdentifier("highlights.import.source.\(index)")
                }
            }
            Text(session.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("highlights.import.note")
        }
    }

    @ViewBuilder private var problem: some View {
        if let problem = session.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("highlights.import.problem")
        }
    }

    // MARK: The review

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = session.summary {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("highlights.import.summary")
            }
            ForEach(Array(session.lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("highlights.import.line.\(index)")
            }
        }
        if !session.titlesToAdd.isEmpty {
            AudibleTitleList(
                heading: session.addTitle, titles: session.titlesToAdd, more: session.moreToAdd,
                identifier: "highlights.import.toAdd")
        }
        if session.canImport {
            Text(session.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("highlights.import.note")
        }
    }
}

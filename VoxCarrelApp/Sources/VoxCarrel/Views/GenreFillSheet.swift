import SwiftUI
import VoxCarrelAppCore

// Fill in Genres (G29–G33): which books to look up, the lookups as they run, and the
// review of what was found. Nothing in the library changes until Apply. Everything
// said, every "can" and every tick is the session's; it closes the sheet itself.

/// The sheet, by the session's phase.
struct GenreFillSheet: View {
    let session: GenreFillSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("genres.fill.heading")

            switch session.phase {
            case .ready:
                ready
            case .lookingUp:
                lookingUp
            case .review, .applying:
                review
            }
        }
        .padding(20)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }

    // MARK: Before the lookups

    @ViewBuilder private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.candidateText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("genres.fill.candidates")
            // G29: off to begin with.
            Toggle(session.includesGeneralTitle, isOn: includesGeneral)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("genres.fill.includesGeneral")
            if let problem = session.problem {
                problemLabel(problem)
            }
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            cancelButton
            Button(session.startTitle) {
                session.start()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!session.canStart)
            .accessibilityIdentifier("genres.fill.start")
        }
    }

    // MARK: While looking up

    @ViewBuilder private var lookingUp: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("genres.fill.spinner")
            Text(session.progressText ?? "")
                .monospacedDigit()
                .accessibilityIdentifier("genres.fill.progress")
        }
        rows(canChange: false)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            cancelButton
            // G33: what was found so far is then shown.
            Button(session.stopTitle) {
                session.stop()
            }
            .disabled(!session.canStop)
            .accessibilityIdentifier("genres.fill.stop")
        }
    }

    // MARK: The review

    @ViewBuilder private var review: some View {
        let isApplying = session.phase == .applying
        if let summary = session.summary {
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("genres.fill.summary")
        }
        if let problem = session.problem {
            problemLabel(problem)
        }
        rows(canChange: !isApplying)
        HStack(spacing: 8) {
            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("genres.fill.applying")
            }
            Spacer(minLength: 0)
            cancelButton
                .disabled(isApplying)
            Button(session.applyTitle) {
                Task { await session.apply() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!session.canApply)
            .accessibilityIdentifier("genres.fill.apply")
        }
    }

    // MARK: Shared

    /// G32: the books looked up so far, each with what was found.
    private func rows(canChange: Bool) -> some View {
        let session = session
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(session.rows) { row in
                    // A row of a list: handed what it shows and what to call.
                    GenreFillRowView(
                        row: row, canChange: canChange,
                        setTicked: { session.setTicked($0, for: row.id) },
                        removeGenre: { session.removeGenre($0, from: row.id) })
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
        }
        .frame(height: 320)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityIdentifier("genres.fill.rows")
    }

    private var cancelButton: some View {
        Button("Cancel") {
            session.cancel()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("genres.fill.cancel")
    }

    private func problemLabel(_ problem: String) -> some View {
        Label(problem, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("genres.fill.problem")
    }

    private var includesGeneral: Binding<Bool> {
        let session = session
        return Binding(get: { session.includesGeneral }, set: { session.includesGeneral = $0 })
    }
}

/// G32: one book: its tick, its title and author, the genres proposed as chips that
/// can be taken away, where they were found, and what there is to say about it.
private struct GenreFillRowView: View {
    let row: GenreFillRow
    /// False while the lookups run, and while the genres are applied.
    let canChange: Bool
    let setTicked: (Bool) -> Void
    let removeGenre: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Give \(row.title) these genres", isOn: Binding(get: { row.isTicked }, set: setTicked))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canChange || !row.canTick)
                .accessibilityIdentifier("genres.fill.row.\(row.id).ticked")
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.title)
                        .accessibilityIdentifier("genres.fill.row.\(row.id).title")
                    Text(row.author)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("genres.fill.row.\(row.id).author")
                    Spacer(minLength: 8)
                    if let source = row.sourceText {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityIdentifier("genres.fill.row.\(row.id).source")
                    }
                }
                if !row.genres.isEmpty {
                    GenreChipsRow(
                        names: row.genres, identifier: "genres.fill.row.\(row.id).genres",
                        remove: canChange ? removeGenre : nil)
                }
                if let note = row.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("genres.fill.row.\(row.id).note")
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

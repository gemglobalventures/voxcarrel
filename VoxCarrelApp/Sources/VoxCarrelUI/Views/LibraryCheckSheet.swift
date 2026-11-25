import SwiftUI
import VoxCarrelAppCore

/// X6: what the check of the library folder found when the library was opened. Only
/// the sections with something in them are shown.
///
/// First, when there is one, a change of folder layout that was interrupted and could
/// not be put right: why, the folders in the way, and Try Again or Stop Trying….
struct LibraryCheckSheet: View {
    @Environment(AppModel.self) private var model
    let summary: LibraryCheckSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library Check")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(summary.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem = summary.layoutProblem {
                CheckSection(
                    section: problem.section, symbol: "exclamationmark.octagon", id: "layoutProblem", wrapsLines: true
                ) { line in
                    reveal(line, id: "layoutProblem")
                } action: {
                    HStack {
                        Button(problem.retryTitle) {
                            Task { await model.retryLibraryCheck() }
                        }
                        .accessibilityIdentifier("check.layoutProblem.retry")
                        Button(problem.stopTitle) {
                            model.requestStopLayoutRecovery()
                        }
                        .accessibilityIdentifier("check.layoutProblem.stop")
                    }
                }
            }

            if let missing = summary.missing {
                CheckSection(section: missing, symbol: "exclamationmark.triangle", id: "missing") { _ in
                    EmptyView()
                } action: {
                    Button("Show in Needs Attention") {
                        model.showNeedsAttention()
                    }
                    .accessibilityIdentifier("check.showNeedsAttention")
                }
            }

            if let untracked = summary.untracked {
                CheckSection(section: untracked, symbol: "doc.badge.plus", id: "untracked") { _ in
                    EmptyView()
                } action: {
                    Button("Import These…") {
                        Task { await model.importUntracked() }
                    }
                    .disabled(!model.canImport)
                    .accessibilityIdentifier("check.importUntracked")
                }
            }

            if let stranded = summary.stranded {
                CheckSection(section: stranded, symbol: "pause.circle", id: "stranded") { line in
                    reveal(line, id: "stranded")
                } action: {
                    EmptyView()
                }
            }

            if let setAside = summary.setAside {
                CheckSection(section: setAside, symbol: "folder.badge.questionmark", id: "setAside", wrapsLines: true) { line in
                    reveal(line, id: "setAside")
                } action: {
                    EmptyView()
                }
            }

            if summary.recoveredLayout != nil || summary.correctedLengths != nil || summary.wrongLengthFiles != nil {
                Divider()
            }
            if let recovered = summary.recoveredLayout {
                Label(recovered, systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("check.recoveredLayout")
            }
            if let corrected = summary.correctedLengths {
                Label(corrected, systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("check.correctedLengths")
            }
            if let wrong = summary.wrongLengthFiles {
                Label(wrong, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("check.wrongLengthFiles")
            }

            HStack {
                Spacer()
                Button("Done") {
                    model.dismissLibraryCheck()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("check.done")
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    /// Shows a line's file or folder in the Finder, when it has one that is there to show.
    @ViewBuilder private func reveal(_ line: LibraryCheckSummary.Line, id: String) -> some View {
        if let url = line.url {
            Button {
                model.revealInFinder(url)
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityIdentifier("check.\(id).\(line.id).reveal")
        }
    }
}

/// One thing the check found: what it is, the books or files, and what can be done.
private struct CheckSection<Accessory: View, Action: View>: View {
    let section: LibraryCheckSummary.Section
    let symbol: String
    let id: String
    /// Whether a long line is shown whole, on as many lines as it takes: for lines that
    /// are sentences, not names.
    var wrapsLines = false
    @ViewBuilder var accessory: (LibraryCheckSummary.Line) -> Accessory
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(section.heading, systemImage: symbol)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("check.\(id).heading")
            Text(section.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("check.\(id).detail")

            // A few lines are shown whole; a long list scrolls.
            if section.lines.count > 5 {
                ScrollView {
                    lines
                }
                .frame(height: 112)
            } else {
                lines
            }

            action
        }
    }

    private var lines: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(section.lines) { line in
                HStack(spacing: 6) {
                    Text(line.text)
                        .font(.callout)
                        .lineLimit(wrapsLines ? nil : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: wrapsLines)
                        .textSelection(.enabled)
                        .help(line.url?.path ?? line.text)
                        .accessibilityIdentifier("check.\(id).\(line.id)")
                    Spacer(minLength: 0)
                    accessory(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

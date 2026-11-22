import SwiftUI
import VoxCarrelAppCore

/// X6: what the check of the library folder found when the library was opened. Only
/// the sections with something in them are shown.
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
                    if let url = line.url {
                        Button {
                            model.revealInFinder(url)
                        } label: {
                            Label("Reveal in Finder", systemImage: "magnifyingglass.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                        .accessibilityIdentifier("check.stranded.\(line.id).reveal")
                    }
                } action: {
                    EmptyView()
                }
            }

            if let corrected = summary.correctedLengths {
                Divider()
                Label(corrected, systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("check.correctedLengths")
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
}

/// One thing the check found: what it is, the books or files, and what can be done.
private struct CheckSection<Accessory: View, Action: View>: View {
    let section: LibraryCheckSummary.Section
    let symbol: String
    let id: String
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
                        .lineLimit(1)
                        .truncationMode(.middle)
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

import SwiftUI
import VoxCarrelAppCore

/// V5: what an operation did, and each thing that went wrong.
struct ResultSheet: View {
    @Environment(AppModel.self) private var model
    let summary: ResultSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("result.headline")

            // A few problems are shown whole; a long list scrolls.
            if summary.problems.count > 4 {
                ScrollView {
                    problems
                }
                .frame(height: 280)
                .accessibilityIdentifier("result.problems")
            } else if !summary.problems.isEmpty {
                problems
                    .accessibilityIdentifier("result.problems")
            }

            HStack {
                Spacer()
                Button("Done") {
                    model.result = nil
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("result.done")
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(summary.problems.enumerated()), id: \.offset) { index, problem in
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title)
                        .fontWeight(.medium)
                    Text(problem.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("result.problem.\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

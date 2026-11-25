import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

// Link Audible Account: what linking does, the store, the sign-in in the browser, and
// the address copied back. Everything said, every "can" and every step is the
// session's; it closes the sheet itself.

/// The sheet, by the session's phase.
struct AudibleLinkSheet: View {
    let session: AudibleLinkSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("audible.link.heading")

            switch session.phase {
            case .start:
                start
            case .waitingForAddress, .registering:
                waiting
            case .done:
                done
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }

    // MARK: Before the sign-in

    @ViewBuilder private var start: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(session.explanation.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("audible.link.explanation")
        HStack(spacing: 8) {
            Text(session.storeTitle)
            Picker(session.storeTitle, selection: store) {
                ForEach(session.storeChoices) { choice in
                    Text(choice.title).tag(choice.store)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!session.canChooseStore)
            .accessibilityLabel(session.storeTitle)
            .accessibilityIdentifier("audible.link.store")
        }
        if let problem = session.problem {
            problemLabel(problem)
        }
        HStack(spacing: 8) {
            if session.offersExistingLink {
                Button(session.existingLinkTitle) {
                    session.useExistingLink()
                }
                .accessibilityIdentifier("audible.link.useExisting")
            }
            Spacer(minLength: 0)
            closeButton
            Button(session.openSignInTitle) {
                session.openSignIn()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!session.canOpenSignIn)
            .accessibilityIdentifier("audible.link.openSignIn")
        }
    }

    // MARK: While the owner signs in

    @ViewBuilder private var waiting: some View {
        let isRegistering = session.phase == .registering
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("audible.link.steps")
        if let problem = session.problem {
            problemLabel(problem)
        }
        HStack(spacing: 8) {
            if isRegistering {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("audible.link.spinner")
                Text(session.registeringText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("audible.link.registering")
            } else {
                Button(session.openAgainTitle) {
                    session.openSignIn()
                }
                .disabled(!session.canOpenSignIn)
                .accessibilityIdentifier("audible.link.openAgain")
            }
            Spacer(minLength: 0)
            closeButton
            Button(session.copiedTitle) {
                Task { await session.readCopiedAddress() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!session.canReadCopiedAddress)
            .accessibilityIdentifier("audible.link.copied")
        }
    }

    // MARK: Linked

    @ViewBuilder private var done: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(session.doneText ?? "", systemImage: "checkmark.circle")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("audible.link.done")
            Text(session.doneNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("audible.link.doneNote")
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(session.closeTitle) {
                session.cancel()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("audible.link.close")
        }
    }

    // MARK: Shared

    private var closeButton: some View {
        Button(session.closeTitle) {
            session.cancel()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(!session.canCancel)
        .accessibilityIdentifier("audible.link.cancel")
    }

    private func problemLabel(_ problem: String) -> some View {
        Label(problem, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("audible.link.problem")
    }

    private var store: Binding<AudibleStore> {
        let session = session
        return Binding(get: { session.store }, set: { session.store = $0 })
    }
}

import SwiftUI
import VoxCarrelAppCore

// Send to Phone (send to phone plan, Task 4): the sheet with the checks, the ways to
// send, and the link's QR code. Everything said and every "can" is the model's; the
// model closes the sheet.

/// The sheet. Shown with the model's state for it, which changes under it as a check, a
/// repair or a transfer goes on.
struct SendToPhoneSheet: View {
    let model: AppModel
    let state: SendSheetState
    /// Where the share picker opens.
    @State private var anchor = ShareAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send to Phone")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("send.heading")
                Text(state.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("send.title")
            }

            if !state.blockers.isEmpty {
                blockers
            } else if let link = state.link {
                // The link takes the place of the checks and the ways to send: what it
                // serves has been made, and nothing above could change it now.
                Divider()
                SendLinkView(model: model, link: link)
                if state.showsNetwork { network }
            } else {
                if !state.warnings.isEmpty { warnings }
                if !state.sizeText.isEmpty {
                    Text(state.sizeText)
                        .font(.callout)
                        .accessibilityIdentifier("send.size")
                }
                if state.showsSquareCover {
                    Toggle(SendText.squareCoverTitle, isOn: squareCover)
                        .toggleStyle(.checkbox)
                        .disabled(!state.canChangeSquareCover)
                        .help("Sends a copy whose cover has bars added to make it square. Your own file is not changed.")
                        .accessibilityIdentifier("send.squareCover")
                }
                if let note = state.coverNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("send.coverNote")
                }

                Divider()

                ways
                network
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if let busy = state.busyText {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("send.spinner")
                    Text(busy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("send.busy")
                } else if let note = state.shareNote {
                    Label(note, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("send.shareNote")
                }
                Spacer(minLength: 0)
                Button(state.closeTitle) {
                    Task { await model.cancelSendToPhone() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!state.canClose)
                .accessibilityIdentifier("send.close")
            }
        }
        .padding(20)
        // One size from the start, tall enough for the link and its code: the sheet
        // does not have to grow when they are shown.
        .frame(width: 500)
        .frame(minHeight: 520, alignment: .top)
        .interactiveDismissDisabled()
    }

    /// Why nothing can be sent, and Save where that is what is needed.
    private var blockers: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(state.blockers.enumerated()), id: \.offset) { index, blocker in
                Label(blocker, systemImage: "xmark.octagon")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("send.blocker.\(index)")
            }
            if let fix = state.blockerFix {
                Button(fix.title) {
                    run(fix)
                }
                .disabled(!state.canFix)
                .accessibilityIdentifier("send.blockerFix")
            }
        }
    }

    /// What to know before sending, each with what puts it right where the sheet can.
    private var warnings: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.warnings) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(warning.text, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("send.warning.\(warning.id)")
                    Spacer(minLength: 0)
                    if let fix = warning.fix {
                        Button(fix.title) {
                            run(fix)
                        }
                        .controlSize(.small)
                        .disabled(!state.canFix)
                        .accessibilityIdentifier("send.warning.\(warning.id).fix")
                    }
                }
            }
        }
    }

    /// The three ways to send.
    private var ways: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    ShareService.airDrop(for: model, from: anchor)
                } label: {
                    Label("AirDrop…", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!state.canShare)
                .help("Send the book to your phone by AirDrop")
                .accessibilityIdentifier("send.airDrop")

                Button {
                    ShareService.share(for: model, from: anchor)
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .background(ShareAnchorView(anchor: anchor))
                .disabled(!state.canShare)
                .help("Send the book another way the system offers")
                .accessibilityIdentifier("send.share")

                if state.linkUnavailableText == nil {
                    Button {
                        Task { await model.showPhoneLink() }
                    } label: {
                        Label("Show Link for BookPlayer", systemImage: "qrcode")
                    }
                    .disabled(!state.canShowLink)
                    .help("Show a code that BookPlayer on your phone downloads the book from")
                    .accessibilityIdentifier("send.showLink")
                }
            }
            if let unavailable = state.linkUnavailableText {
                Text(unavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("send.linkUnavailable")
            }
        }
    }

    /// The sentence about the network, and the tick that marks it as the owner's own.
    private var network: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.networkNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("send.networkNote")
            Toggle(SendText.ownNetworkTitle, isOn: ownNetwork)
                .toggleStyle(.checkbox)
                .disabled(!state.canMarkOwnNetwork)
                .accessibilityIdentifier("send.ownNetwork")
        }
    }

    private func run(_ fix: SendFix) {
        Task {
            switch fix {
            case .repair: await model.sendRepair()
            case .save: await model.sendSave()
            }
        }
    }

    private var squareCover: Binding<Bool> {
        let model = model
        return Binding(get: { model.sendSquareCover }, set: { model.sendSquareCover = $0 })
    }

    private var ownNetwork: Binding<Bool> {
        let model = model
        let isOwn = state.isOwnNetwork
        return Binding(get: { isOwn }, set: { model.setOwnNetwork($0) })
    }
}

/// The link, once one is showing: the QR code while it can be fetched from, what to do
/// with it, and how the phone is getting on.
private struct SendLinkView: View {
    let model: AppModel
    let link: SendLinkState

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            if link.isLive {
                // Drawn again only when the link is another one, not at every percent.
                QRCodeView(text: link.linkText)
                    .equatable()
                    .accessibilityLabel("QR code for BookPlayer")
                    .accessibilityIdentifier("send.qr")
                Text(SendText.scanHelp)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("send.scanHelp")
            }
            Text(link.statusText)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("send.status")
            if link.isLive {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.linkText, forType: .string)
                }
                .controlSize(.small)
                .help("Copy the link, to send it to your phone another way")
                .accessibilityIdentifier("send.copyLink")
            }
            if link.canMakeNewLink {
                Button(SendText.makeNewLink) {
                    Task { await model.showPhoneLink() }
                }
                .accessibilityIdentifier("send.newLink")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The QR code of a text, drawn large on white. Given a plain value.
private struct QRCodeView: View, Equatable {
    let text: String

    var body: some View {
        if let image = QRCode.image(for: text, pixels: 800) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
        } else {
            Text("The code could not be drawn. Use Copy Link.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

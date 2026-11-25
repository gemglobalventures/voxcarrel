import Foundation
import VoxCarrelCore

/// The sizes over which a book is not sent to a Kindle, in bytes.
public struct KindleLimits: Equatable, Sendable {
    /// The most Amazon accepts by any route.
    public var any: Int64
    /// The most Amazon accepts attached to a message.
    public var byEmail: Int64

    public init(any: Int64, byEmail: Int64) {
        self.any = any
        self.byEmail = byEmail
    }

    /// Amazon's own: 200 MB, and 50 MB by email.
    public static let amazons = KindleLimits(any: 200_000_000, byEmail: 50_000_000)
}

/// What of a book can be sent to a Kindle, and how large it is.
public struct KindleOffer: Equatable, Sendable {
    public var choice: KindleSendChoice
    /// The name of the library's file that would be sent; empty when there is none.
    public var fileName: String
    /// Its size.
    public var bytes: Int64

    public init(choice: KindleSendChoice, fileName: String = "", bytes: Int64 = 0) {
        self.choice = choice
        self.fileName = fileName
        self.bytes = bytes
    }
}

/// Every sentence Send to Kindle shows.
public enum KindleText {
    /// The command, in the Book menu and a book's context menu.
    public static let commandTitle = "Send to Kindle…"

    /// What the window says while the copy to send is made.
    public static let busy = "Preparing to send to Kindle…"

    public static let nothingToSend = "This book has no ebook on this Mac to send."

    public static let convertFirst =
        "Kindle takes EPUB and PDF. Convert this book to EPUB first (Book > Convert to EPUB), then send it."

    public static func tooLarge(name: String, bytes: Int64) -> String {
        "“\(name)” is \(SendText.size(bytes)), which is more than Amazon accepts (200 MB)."
    }

    public static func tooLargeForEmail(name: String, bytes: Int64) -> String {
        "“\(name)” is \(SendText.size(bytes)), which is more than Amazon accepts by email (50 MB). "
            + "Install Amazon's Send to Kindle app to send it."
    }

    public static let appDidNotOpen = "Amazon's Send to Kindle app could not be opened."

    public static let noMailProgram =
        "No mail program could be opened to send the book. Install Amazon's Send to Kindle app, or set up Mail."

    public static let noRoute =
        "To send to Kindle, install Amazon's Send to Kindle app, or enter your Kindle's email address in "
        + "Settings > General."

    /// Said when the copy to hand over could not be made.
    public static let couldNotCopy = "A copy of the book could not be made to send."

    // MARK: The setting

    public static let addressTitle = "Kindle email address"

    public static let addressHelp =
        "Used only when Amazon's Send to Kindle app is not installed. Find the address in your Amazon account "
        + "under Devices, and add the address you send from to its approved list."

    public static let addressProblem = "That does not look like an email address."

    /// What was typed as an address, without the space around it, when it could be
    /// one: it has an "@" and no space inside. Nil otherwise.
    public static func address(_ typed: String) -> String? {
        let text = typed.trimmed
        guard text.contains("@"), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }
}

extension AppModel {
    // MARK: The Kindle's address

    /// What the field in Settings holds. What is typed is kept, without the space
    /// around it, when it could be an address; nothing is kept when the field is
    /// emptied; anything else is not kept, and the address kept before stays.
    public var kindleAddress: String {
        get { kindleAddressText }
        set {
            kindleAddressText = newValue
            if newValue.trimmed.isEmpty {
                storedKindleAddress = ""
                defaults.removeObject(forKey: KindleKeys.address)
            } else if let address = KindleText.address(newValue) {
                storedKindleAddress = address
                defaults.set(address, forKey: KindleKeys.address)
            }
        }
    }

    /// What is wrong with what the field holds; nil when it is empty or could be an address.
    public var kindleAddressProblem: String? {
        kindleAddressText.trimmed.isEmpty || KindleText.address(kindleAddressText) != nil
            ? nil : KindleText.addressProblem
    }

    // MARK: Whether a book can be sent

    /// Whether Send to Kindle applies to these books: there is exactly one, it has files
    /// on this Mac with an ebook among them, and nothing else is running or open.
    ///
    /// Decided from the rows as they were last read: the library is not asked until the
    /// command is chosen, and says then exactly what there is to send.
    public func canSendToKindle(_ ids: Set<Int64>) -> Bool {
        guard ids.count == 1, let id = ids.first, id > 0, canSendToPhone(ids),
              let row = rows.first(where: { $0.id == id })
        else { return false }
        return row.hasFiles && row.hasEbookFile
    }

    // MARK: Sending

    /// Sends the one selected book to the Kindle.
    public func sendToKindle() async {
        await sendToKindle(for: selection)
    }

    /// Hands the book's ebook to Amazon's Send to Kindle app when it is installed, or
    /// otherwise opens a message to the Kindle's address with the ebook attached, for
    /// the owner to send. Does nothing unless `canSendToKindle`.
    ///
    /// What is handed over is a copy named by the book's title, in a temporary folder:
    /// never a file of the library. Nothing is said when it goes well, since Amazon's
    /// window, or the message, is then in front of the owner. `alert` says what stands
    /// in the way otherwise.
    public func sendToKindle(for ids: Set<Int64>) async {
        guard canSendToKindle(ids), let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
        let title = row.book.title
        guard let worker = await begin(KindleText.busy) else { return }
        // Reading and copying change nothing in the library, so there is nothing to read again.
        defer { busyLabel = nil }
        let offer: KindleOffer
        do {
            offer = try await worker.kindleOffer(ofBook: id)
        } catch {
            show(error)
            return
        }
        let file: BookFile
        switch offer.choice {
        case .nothing:
            alert = KindleText.nothingToSend
            return
        case .convertFirst:
            alert = KindleText.convertFirst
            return
        case .file(let chosen):
            file = chosen
        }
        guard offer.bytes <= kindleLimits.any else {
            alert = KindleText.tooLarge(name: offer.fileName, bytes: offer.bytes)
            return
        }
        let sender = kindleSender
        let usesApp = sender.isAppInstalled
        if !usesApp {
            guard !storedKindleAddress.isEmpty else {
                alert = KindleText.noRoute
                return
            }
            guard offer.bytes <= kindleLimits.byEmail else {
                alert = KindleText.tooLargeForEmail(name: offer.fileName, bytes: offer.bytes)
                return
            }
        }
        let copy: URL
        do {
            copy = try await worker.stageForKindle(file, title: title, under: sendTempRoot)
        } catch {
            // Said plainly, not as the system says it.
            alert = KindleText.couldNotCopy
            return
        }
        if usesApp {
            if !sender.sendWithApp(copy) { alert = KindleText.appDidNotOpen }
        } else if !sender.composeEmail(to: storedKindleAddress, subject: title, attaching: copy) {
            alert = KindleText.noMailProgram
        }
    }
}

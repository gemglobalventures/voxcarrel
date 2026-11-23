import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// The sentences of Send to Phone. PH21, PH24, PH27, PH29.
@Suite struct SendTextTests {
    static let london = TimeZone(identifier: "Europe/London")!
    static let british = Locale(identifier: "en_GB")

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func ph21_eachBlockerIsOnePlainSentence() {
        #expect(SendText.blocker(.noAudio) == "This book has no audiobook files to send.")
        #expect(SendText.blocker(.missingFile("Part 1.mp3")) == "\"Part 1.mp3\" cannot be found.")
        #expect(
            SendText.blocker(.unsupportedFormat("Book.flac"))
                == "\"Book.flac\" is not an M4B, M4A or MP3 file, so the phone's player cannot take it.")
        #expect(SendText.blocker(.notFiled) == "This book has not been filed in the library folder yet.")
        #expect(SendText.saveFirst == "Save your changes first.")
    }

    @Test func ph21_warningsAreWordedForOneAndForSeveral() {
        #expect(
            SendText.warning(.wrongLengthHeader(files: 1))
                == "1 file has a wrong length header. Some players will stop early.")
        #expect(
            SendText.warning(.wrongLengthHeader(files: 3))
                == "3 files have a wrong length header. Some players will stop early.")
        #expect(
            SendText.warning(.tagsNotWritten(files: 1))
                == "1 file does not hold the book's details: the last write to it failed.")
        #expect(
            SendText.warning(.tagsNotWritten(files: 2))
                == "2 files do not hold the book's details: the last write to them failed.")
        #expect(SendText.warning(.noCoverInFile) == "The audio has no cover inside it, so the phone will show none.")
        #expect(
            SendText.warning(.large(bytes: 1_240_000_000))
                == "This is a large book (1.2 GB). Sending it will take a while.")
    }

    @Test func ph21_anEarlierSendIsDatedWithTheYearOnlyWhenItIsNotThisYear() {
        let now = Self.date(2026, 11, 30)
        #expect(
            SendText.warning(
                .sentBefore(Self.date(2026, 11, 23)), now: now, locale: Self.british, timeZone: Self.london)
                == "This book was sent to the phone on 23 Nov.")
        #expect(
            SendText.warning(
                .sentBefore(Self.date(2025, 3, 2)), now: now, locale: Self.british, timeZone: Self.london)
                == "This book was sent to the phone on 2 Mar 2025.")
    }

    @Test func ph21_theSizeLineCountsFilesAndSaysWhenTheyGoAsAZip() {
        #expect(SendText.sizeLine(files: 1, bytes: 412_000_000, asZip: false) == "1 file, 412 MB")
        #expect(SendText.sizeLine(files: 4, bytes: 1_200_000_000, asZip: true) == "4 files, 1.2 GB, sent as one zip")
    }

    @Test func ph21_sizesAreWrittenTheSameEverywhere() {
        #expect(SendText.size(0) == "0 bytes")
        #expect(SendText.size(1) == "1 byte")
        #expect(SendText.size(999) == "999 bytes")
        #expect(SendText.size(1000) == "1 KB")
        #expect(SendText.size(12_400) == "12 KB")
        #expect(SendText.size(999_499) == "999 KB")
        // Never "1000 KB" or "1000 MB".
        #expect(SendText.size(999_500) == "1 MB")
        #expect(SendText.size(412_400_000) == "412 MB")
        #expect(SendText.size(999_600_000) == "1.0 GB")
        #expect(SendText.size(1_250_000_000) == "1.3 GB")
        #expect(SendText.size(23_960_000_000) == "24.0 GB")
        #expect(SendText.size(-5) == "0 bytes")
    }

    /// SP14, as the sheet says it.
    @Test func sp14_aCoverThatCouldNotBeMadeSquareIsSaidForOneFileAndForSeveral() {
        #expect(SendText.coverNotSquared(files: 0) == nil)
        #expect(SendText.coverNotSquared(files: 1) == "The cover could not be made square for one file.")
        #expect(SendText.coverNotSquared(files: 3) == "The cover could not be made square for 3 files.")
    }

    @Test func ph24_progressIsAWholePercentThatNeverPassesAHundred() {
        #expect(SendText.sending(bytesSent: 0, of: 1000) == "Sending… 0%")
        #expect(SendText.sending(bytesSent: 400, of: 1000) == "Sending… 40%")
        #expect(SendText.sending(bytesSent: 1, of: 3) == "Sending… 33%")
        #expect(SendText.sending(bytesSent: 999, of: 1000) == "Sending… 99%")
        #expect(SendText.sending(bytesSent: 1000, of: 1000) == "Sending… 100%")
        #expect(SendText.sending(bytesSent: 5000, of: 1000) == "Sending… 100%")
        #expect(SendText.sending(bytesSent: -1, of: 1000) == "Sending… 0%")
        // A size too large to multiply by a hundred as it stands.
        #expect(SendText.sending(bytesSent: Int64.max / 2, of: Int64.max) == "Sending… 49%")
        #expect(SendText.sending(bytesSent: 10, of: 0) == "Sending…")
    }

    @Test func ph24_theEndsOfALinkAreSaidPlainly() {
        #expect(SendText.waiting == "Waiting for the phone…")
        // Every byte was handed over; whether the phone kept them is not known here.
        #expect(SendText.sent == "Sent.")
        #expect(SendText.expired == "The link has expired.")
        #expect(SendText.failed("The link stopped working.") == "The book could not be sent. The link stopped working.")
        #expect(SendText.failed("  ") == "The book could not be sent.")
    }

    @Test func ph27_theNoteIsStrongerOnANetworkThatIsNotMarked() {
        #expect(SendText.networkNote(isOwn: true) == "Your phone must be on the same network as this Mac.")
        #expect(
            SendText.networkNote(isOwn: false)
                == "Your phone must be on the same network as this Mac. Anyone else on this network could see "
                + "the book being sent. Use the link only on a network you trust.")
    }

    @Test func ph29_theInspectorsLineGivesTheDay() {
        let now = Self.date(2026, 11, 30)
        #expect(
            SendText.sentLine(Self.date(2026, 11, 23), now: now, locale: Self.british, timeZone: Self.london)
                == "Sent to phone 23 Nov")
        #expect(
            SendText.sentLine(Self.date(2025, 11, 23), now: now, locale: Self.british, timeZone: Self.london)
                == "Sent to phone 23 Nov 2025")
    }

    // MARK: PH27 Telling networks apart

    @Test func ph27_aNetworkIsTheSameByItsRouterAndByItsNameWhereBothAreKnown() {
        let home = NetworkIdentity(router: "192.168.1.1", name: "Home")
        #expect(home.matches(NetworkIdentity(router: "192.168.1.1", name: "Home")))
        #expect(!home.matches(NetworkIdentity(router: "192.168.1.1", name: "Cafe")))
        #expect(!home.matches(NetworkIdentity(router: "10.0.0.1", name: "Home")))
        // A name that could not be read rules nothing out, either way round.
        #expect(home.matches(NetworkIdentity(router: "192.168.1.1")))
        #expect(NetworkIdentity(router: "192.168.1.1").matches(home))
    }

    @Test func ph27_aNetworkIsKeptAsTextAndReadBack() {
        let home = NetworkIdentity(router: "192.168.1.1", name: "Home\tWi-Fi")
        #expect(NetworkIdentity(stored: home.stored) == home)
        let wired = NetworkIdentity(router: "10.0.0.1")
        #expect(wired.stored == "10.0.0.1")
        #expect(NetworkIdentity(stored: wired.stored) == wired)
        #expect(NetworkIdentity(stored: "") == nil)
        #expect(NetworkIdentity(stored: "\tHome") == nil)
    }
}

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

    @Test func ph27_aNetworkIsTheSameByItsRoutersTwoAddressesAndByItsNameWhereBothAreKnown() {
        let home = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Home")
        #expect(home.matches(NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Home")))
        #expect(!home.matches(NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Cafe")))
        #expect(!home.matches(NetworkIdentity(router: "10.0.0.1", hardware: "a4:5e:60:c1:02:9f", name: "Home")))
        // Another router that has the same address, as most of one make do, is another network.
        #expect(!home.matches(NetworkIdentity(router: "192.168.1.1", hardware: "00:11:22:33:44:55", name: "Home")))
        #expect(!home.matches(NetworkIdentity(router: "192.168.1.1", hardware: "00:11:22:33:44:55")))
        // A name that could not be read rules nothing out, either way round.
        #expect(home.matches(NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f")))
        #expect(NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f").matches(home))
    }

    @Test func ph27_aNetworkIsKeptAsTextAndReadBack() {
        let home = NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Home\tWi-Fi")
        #expect(home.stored == "192.168.1.1\ta4:5e:60:c1:02:9f\tHome\tWi-Fi")
        #expect(NetworkIdentity(stored: home.stored) == home)
        let wired = NetworkIdentity(router: "10.0.0.1", hardware: "00:11:22:33:44:55")
        #expect(wired.stored == "10.0.0.1\t00:11:22:33:44:55")
        #expect(NetworkIdentity(stored: wired.stored) == wired)
        #expect(NetworkIdentity(stored: "") == nil)
        #expect(NetworkIdentity(stored: "\tHome") == nil)
        // What was kept before the router's hardware address was part of it says too
        // little to know a network by.
        #expect(NetworkIdentity(stored: "192.168.1.1") == nil)
        #expect(NetworkIdentity(stored: "192.168.1.1\tHome") == nil)
        #expect(NetworkIdentity(stored: "192.168.1.1\t\tHome") == nil)
        #expect(NetworkIdentity(stored: "192.168.1.1\ta4:5e:60:c1:02\tHome") == nil)
        #expect(NetworkIdentity(stored: "192.168.1.1\tzz:5e:60:c1:02:9f") == nil)
    }

    // MARK: PH27 The router's hardware address

    /// One message of the system's table of neighbours: a header, an IPv4 address and
    /// a link-level address, as the system lays them out.
    static func neighbour(
        _ address: [UInt8], _ hardware: [UInt8], interface: UInt8 = 4, interfaceName: String = ""
    ) -> [UInt8] {
        var internet = [UInt8](repeating: 0, count: 16)
        internet[0] = 16
        internet[1] = UInt8(AF_INET)
        internet.replaceSubrange(4..<8, with: address)
        var link: [UInt8] = [0, UInt8(AF_LINK), interface, 0, 6, UInt8(interfaceName.utf8.count), UInt8(hardware.count), 0]
        link += Array(interfaceName.utf8) + hardware
        while link.count < 20 || link.count % 4 != 0 { link.append(0) }
        link[0] = UInt8(link.count)
        var message = [UInt8](repeating: 0, count: NeighbourTable.headerBytes)
        let length = message.count + internet.count + link.count
        message[0] = UInt8(length & 0xFF)
        message[1] = UInt8(length >> 8)
        return message + internet + link
    }

    @Test func ph27_theTableOfNeighboursGivesEachOnesHardwareAddress() {
        let router = Self.neighbour([192, 168, 1, 1], [0xA4, 0x5E, 0x60, 0xC1, 0x02, 0x9F])
        let phone = Self.neighbour([192, 168, 1, 23], [0x00, 0x0B, 0xFF, 0x10, 0x20, 0x30], interface: 7, interfaceName: "en0")
        // One that has not answered yet has no hardware address, and one of all zeros is none.
        let silent = Self.neighbour([192, 168, 1, 40], [])
        let blank = Self.neighbour([192, 168, 1, 41], [0, 0, 0, 0, 0, 0])

        #expect(NeighbourTable.entries(in: router + silent + phone + blank) == [
            NeighbourTable.Entry(address: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", interface: 4),
            NeighbourTable.Entry(address: "192.168.1.23", hardware: "00:0b:ff:10:20:30", interface: 7),
        ])
        #expect(NeighbourTable.entries(in: []) == [])
    }

    @Test func ph27_aTableThatIsCutShortOrIsNotOneIsReadAsFarAsItGoes() {
        let router = Self.neighbour([192, 168, 1, 1], [0xA4, 0x5E, 0x60, 0xC1, 0x02, 0x9F])
        let expected = [NeighbourTable.Entry(address: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", interface: 4)]
        // Cut anywhere, it never reads past its end.
        for cut in 0..<router.count {
            #expect(NeighbourTable.entries(in: Array(router.prefix(cut))) == [])
            #expect(NeighbourTable.entries(in: router + Array(router.prefix(cut))) == expected)
        }
        // A length that is too small, or longer than what is there.
        var short = router
        short[0] = 4
        #expect(NeighbourTable.entries(in: short + router) == [])
        var long = router
        long[1] = 0x7F
        #expect(NeighbourTable.entries(in: router + long) == expected)
        // An address that says it is longer than its message, and one of another kind.
        var wide = router
        wide[NeighbourTable.headerBytes] = 252
        #expect(NeighbourTable.entries(in: wide + router) == expected)
        var other = router
        other[NeighbourTable.headerBytes + 1] = UInt8(AF_INET6)
        #expect(NeighbourTable.entries(in: other + router) == expected)
        var longAddress = router
        longAddress[NeighbourTable.headerBytes + 16 + 6] = 200
        #expect(NeighbourTable.entries(in: longAddress + router) == expected)
        // Bytes of no shape at all.
        for seed in 0..<50 {
            var noise = LinkProbe.contents(400 + seed)
            noise[0] = UInt8(truncatingIfNeeded: seed * 5)
            noise[1] = 0
            _ = NeighbourTable.entries(in: noise)
        }
    }

    @Test func ph27_theSystemsOwnTableCanBeRead() {
        for entry in NeighbourTable.system() {
            #expect(LocalAddress.ipv4Parts(entry.address) != nil)
            #expect(NetworkIdentity.isHardwareAddress(entry.hardware))
            #expect(entry.interface > 0)
        }
    }

    @Test func ph27_aNetworkIsKnownOnlyWhenItsRouterHasOneHardwareAddress() {
        typealias Entry = NeighbourTable.Entry
        let table = [
            Entry(address: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", interface: 4),
            Entry(address: "192.168.1.23", hardware: "00:0b:ff:10:20:30", interface: 4),
        ]
        func identity(_ router: String, _ interface: Int?, _ table: [Entry], name: String? = nil) -> NetworkIdentity? {
            SystemLocalNetwork.identity(router: router, interface: interface, neighbours: table, name: name)
        }
        #expect(
            identity("192.168.1.1", 4, table, name: "Home")
                == NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f", name: "Home"))
        #expect(identity("192.168.1.1", nil, table) == NetworkIdentity(router: "192.168.1.1", hardware: "a4:5e:60:c1:02:9f"))
        // A router the system has no hardware address for is not known: nor is the network.
        #expect(identity("192.168.1.254", 4, table) == nil)
        #expect(identity("192.168.1.1", 4, []) == nil)
        // Nor one known only on another interface than the one it is reached through.
        #expect(identity("192.168.1.1", 5, table) == nil)
        // Nor one that two different hardware addresses answer for.
        let two = table + [Entry(address: "192.168.1.1", hardware: "00:11:22:33:44:55", interface: 4)]
        #expect(identity("192.168.1.1", 4, two) == nil)
        // The same one listed twice is one.
        #expect(identity("192.168.1.1", 4, table + [table[0]]) != nil)
    }
}

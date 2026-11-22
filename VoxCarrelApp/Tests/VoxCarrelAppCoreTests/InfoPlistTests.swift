import Foundation
import Testing
import VoxCarrelCore

/// What the bundled app tells the system about itself.
@Suite struct InfoPlistTests {
    private func plist() throws -> [String: Any] {
        // Tests/VoxCarrelAppCoreTests/InfoPlistTests.swift -> Resources/Info.plist
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: file)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Plain http is let through for the Library of Congress catalogue's host and for
    /// nothing else: no subdomains, no other host, no general switch.
    @Test func plainHTTPIsAllowedForTheLibraryOfCongressCatalogueOnly() throws {
        let security = try #require(try plist()["NSAppTransportSecurity"] as? [String: Any])
        #expect(Set(security.keys) == ["NSExceptionDomains"])
        let domains = try #require(security["NSExceptionDomains"] as? [String: Any])
        #expect(Set(domains.keys) == ["lx2.loc.gov"])
        let catalogue = try #require(domains["lx2.loc.gov"] as? [String: Any])
        #expect(Set(catalogue.keys) == ["NSExceptionAllowsInsecureHTTPLoads", "NSIncludesSubdomains"])
        #expect(catalogue["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
        #expect(catalogue["NSIncludesSubdomains"] as? Bool == false)
    }

    /// The host the plist names is the one the lookup's only exception names.
    @Test func theHostIsTheOneTheLookupAsks() throws {
        let security = try #require(try plist()["NSAppTransportSecurity"] as? [String: Any])
        let domains = try #require(security["NSExceptionDomains"] as? [String: Any])
        #expect(Array(domains.keys) == [InsecureOrigin.libraryOfCongress.host])
    }
}

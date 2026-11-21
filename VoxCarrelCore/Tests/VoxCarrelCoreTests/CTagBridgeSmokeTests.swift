import CTagBridge
import Foundation
import Testing

@Suite struct CTagBridgeSmokeTests {
    @Test func readingAMissingFileThrowsRatherThanCrashing() {
        #expect(throws: (any Error).self) {
            _ = try CTBTagFile.readMP4(atPath: "/nonexistent/file.m4b")
        }
        #expect(throws: (any Error).self) {
            _ = try CTBTagFile.readMP3(atPath: "/nonexistent/file.mp3")
        }
    }

    /// `-[NSString fileSystemRepresentation]` raises an Objective-C exception for an empty
    /// path. It must come back as an error, not end the process.
    @Test func anExceptionInsideTheBridgeBecomesAnError() {
        #expect(throws: (any Error).self) { _ = try CTBTagFile.readMP4(atPath: "") }
        #expect(throws: (any Error).self) { _ = try CTBTagFile.readMP3(atPath: "") }
        #expect(throws: (any Error).self) { try CTBTagFile.writeMP4(atPath: "", changes: CTBChanges()) }
        #expect(throws: (any Error).self) { try CTBTagFile.writeMP3(atPath: "", changes: CTBChanges()) }
    }
}

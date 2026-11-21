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
}

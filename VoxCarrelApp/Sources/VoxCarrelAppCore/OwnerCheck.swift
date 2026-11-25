import Foundation
import LocalAuthentication

/// How a check that the person at the Mac is its owner came out.
public enum OwnerCheckResult: Equatable, Sendable {
    /// They proved it: with Touch ID, or with the Mac's password.
    case confirmed
    /// They did not: the check was cancelled, or it failed.
    case refused
    /// The Mac cannot check at all: it has no password set.
    case unavailable
}

/// Asks the person at the Mac to prove they are its owner. Tests give one that answers
/// by itself.
public protocol OwnerCheck: Sendable {
    /// - Parameter reason: What the check is for, as the system finishes the sentence
    ///   "VoxCarrel is trying to …".
    func confirm(reason: String) async -> OwnerCheckResult
}

/// The system's own check: Touch ID where the Mac has it, and the Mac's password
/// otherwise or when the finger is not known.
public struct SystemOwnerCheck: OwnerCheck {
    public init() {}

    public func confirm(reason: String) async -> OwnerCheckResult {
        let context = LAContext()
        var problem: NSError?
        // Nothing can be asked on a Mac that has no password.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else { return .unavailable }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .confirmed : .refused
        } catch {
            return .refused
        }
    }
}

import Foundation

/// The cancellable countdown shown before the Watch starts the microphone
/// again after a terminated process. See `docs/specs/recording-health.md`
/// §3.4: the microphone only starts after the countdown reaches zero in the
/// foreground.
public struct ResumeCountdown: Sendable, Equatable {
    public static let defaultSeconds = 3

    public let totalSeconds: Int
    public private(set) var remainingSeconds: Int?

    public init(totalSeconds: Int = ResumeCountdown.defaultSeconds) {
        self.totalSeconds = max(1, totalSeconds)
        self.remainingSeconds = nil
    }

    public var isActive: Bool {
        remainingSeconds != nil
    }

    public mutating func start() {
        remainingSeconds = totalSeconds
    }

    public mutating func cancel() {
        remainingSeconds = nil
    }

    /// Advances one second. Returns true when the countdown finished and the
    /// caller may start the microphone.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let remaining = remainingSeconds else {
            return false
        }
        if remaining <= 1 {
            remainingSeconds = nil
            return true
        }
        remainingSeconds = remaining - 1
        return false
    }
}

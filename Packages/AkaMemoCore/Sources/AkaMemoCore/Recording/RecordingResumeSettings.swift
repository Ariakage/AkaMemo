import Foundation

/// User-facing resume options from `docs/specs/recording-health.md` §3.4.
///
/// `silentResume` only suppresses app sounds and haptics. The system
/// microphone indicator stays visible and recovery is never attempted in the
/// background.
public struct RecordingResumeSettings: Sendable, Equatable {
    public static let standard = RecordingResumeSettings()

    public var autoResume: Bool
    public var silentResume: Bool

    public init(autoResume: Bool = true, silentResume: Bool = true) {
        self.autoResume = autoResume
        self.silentResume = silentResume
    }
}

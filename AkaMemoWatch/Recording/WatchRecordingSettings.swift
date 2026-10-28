import AkaMemoCore
import Foundation
import Observation

/// Persists the resume options from `docs/specs/recording-health.md` §3.4.
/// Both default to on; "silent" only mutes app sounds and haptics.
@MainActor
@Observable
final class WatchRecordingSettings {
    static let autoResumeKey = "recording.autoResume"
    static let silentResumeKey = "recording.silentResume"

    private let defaults: UserDefaults
    private(set) var values: RecordingResumeSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let autoResume =
            defaults.object(forKey: Self.autoResumeKey) as? Bool ?? true
        let silentResume =
            defaults.object(forKey: Self.silentResumeKey) as? Bool ?? true
        self.values = RecordingResumeSettings(
            autoResume: autoResume,
            silentResume: silentResume
        )
    }

    var autoResume: Bool { values.autoResume }
    var silentResume: Bool { values.silentResume }

    func setAutoResume(_ enabled: Bool) {
        values.autoResume = enabled
        defaults.set(enabled, forKey: Self.autoResumeKey)
    }

    func setSilentResume(_ enabled: Bool) {
        values.silentResume = enabled
        defaults.set(enabled, forKey: Self.silentResumeKey)
    }
}

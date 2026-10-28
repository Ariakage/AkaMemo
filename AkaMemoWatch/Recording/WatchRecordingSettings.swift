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
    static let updatedAtKey = "recording.resumeSettingsUpdatedAt"

    private let defaults: UserDefaults
    private(set) var values: RecordingResumeSettings
    private(set) var updatedAtMs: Int64

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
        self.updatedAtMs =
            (defaults.object(forKey: Self.updatedAtKey) as? NSNumber)?
            .int64Value ?? 0
    }

    var autoResume: Bool { values.autoResume }
    var silentResume: Bool { values.silentResume }

    var currentCommand: ResumeSettingsCommand {
        ResumeSettingsCommand(
            autoResume: values.autoResume,
            silentResume: values.silentResume,
            updatedAtMs: updatedAtMs
        )
    }

    func setAutoResume(_ enabled: Bool) {
        applyLocal(
            autoResume: enabled,
            silentResume: values.silentResume
        )
    }

    func setSilentResume(_ enabled: Bool) {
        applyLocal(
            autoResume: values.autoResume,
            silentResume: enabled
        )
    }

    /// Applies a setting received from the iPhone. Older writes are ignored.
    func apply(_ command: ResumeSettingsCommand) -> Bool {
        guard command.isNewer(than: currentCommand) else {
            return false
        }
        values = RecordingResumeSettings(
            autoResume: command.autoResume,
            silentResume: command.silentResume
        )
        updatedAtMs = command.updatedAtMs
        persist()
        return true
    }

    private func applyLocal(autoResume: Bool, silentResume: Bool) {
        let now = TimeMath.epochMs(Date())
        updatedAtMs = max(now, updatedAtMs + 1)
        values = RecordingResumeSettings(
            autoResume: autoResume,
            silentResume: silentResume
        )
        persist()
    }

    private func persist() {
        defaults.set(values.autoResume, forKey: Self.autoResumeKey)
        defaults.set(values.silentResume, forKey: Self.silentResumeKey)
        defaults.set(updatedAtMs, forKey: Self.updatedAtKey)
    }
}

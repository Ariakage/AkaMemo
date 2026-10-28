import AkaMemoCore
import Foundation
import Observation

protocol LocationSettingSending: AnyObject, Sendable {
    func sendLocationSetting(_ setting: LocationSetting) -> Bool
}

protocol ResumeSettingsSending: AnyObject, Sendable {
    func sendResumeSettings(_ command: ResumeSettingsCommand) -> Bool
}

/// iPhone-side copies of the Watch settings. The Watch reports its effective
/// values in health events; the newer timestamp wins so a change on either
/// device is not overwritten by a stale copy.
@MainActor
@Observable
final class PhoneSettingsModel {
    enum Keys {
        static let locationEnabled = "location.enabled"
        static let locationUpdatedAt = "location.enabledUpdatedAt"
        static let autoResume = "recording.autoResume"
        static let silentResume = "recording.silentResume"
        static let resumeUpdatedAt = "recording.resumeSettingsUpdatedAt"
    }

    private let defaults: UserDefaults
    private var locationSender: (any LocationSettingSending)?
    private var resumeSender: (any ResumeSettingsSending)?
    private(set) var locationSetting: LocationSetting
    private(set) var resumeSettings: ResumeSettingsCommand
    private(set) var watchLocationEnabled: Bool?
    private(set) var watchAuthorization: String?
    private(set) var watchTrackBytes: Int64?
    private(set) var watchAutoResume: Bool?
    private(set) var watchSilentResume: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled =
            defaults.object(forKey: Keys.locationEnabled) as? Bool ?? true
        let locationUpdatedAt =
            (defaults.object(forKey: Keys.locationUpdatedAt) as? NSNumber)?
            .int64Value ?? 0
        self.locationSetting = LocationSetting(
            enabled: enabled,
            updatedAtMs: locationUpdatedAt
        )

        let autoResume =
            defaults.object(forKey: Keys.autoResume) as? Bool ?? true
        let silentResume =
            defaults.object(forKey: Keys.silentResume) as? Bool ?? true
        let resumeUpdatedAt =
            (defaults.object(forKey: Keys.resumeUpdatedAt) as? NSNumber)?
            .int64Value ?? 0
        self.resumeSettings = ResumeSettingsCommand(
            autoResume: autoResume,
            silentResume: silentResume,
            updatedAtMs: resumeUpdatedAt
        )
    }

    var isLocationEnabled: Bool { locationSetting.enabled }
    var isAutoResumeEnabled: Bool { resumeSettings.autoResume }
    var isSilentResumeEnabled: Bool { resumeSettings.silentResume }

    func attach(sender: any LocationSettingSending) {
        self.locationSender = sender
    }

    func attachResumeSender(_ sender: any ResumeSettingsSending) {
        self.resumeSender = sender
    }

    /// Re-sends both persisted settings after activation or foregrounding.
    func publishSettings() {
        _ = locationSender?.sendLocationSetting(locationSetting)
        _ = resumeSender?.sendResumeSettings(resumeSettings)
    }

    func publishLocationSetting() {
        _ = locationSender?.sendLocationSetting(locationSetting)
    }

    func setLocationEnabled(_ enabled: Bool) {
        guard enabled != locationSetting.enabled else {
            return
        }
        let now = TimeMath.epochMs(Date())
        let next = LocationSetting(
            enabled: enabled,
            updatedAtMs: max(now, locationSetting.updatedAtMs + 1)
        )
        locationSetting = next
        persist(next)
        _ = locationSender?.sendLocationSetting(next)
    }

    func setAutoResumeEnabled(_ enabled: Bool) {
        guard enabled != resumeSettings.autoResume else {
            return
        }
        applyLocalResume(
            autoResume: enabled,
            silentResume: resumeSettings.silentResume
        )
    }

    func setSilentResumeEnabled(_ enabled: Bool) {
        guard enabled != resumeSettings.silentResume else {
            return
        }
        applyLocalResume(
            autoResume: resumeSettings.autoResume,
            silentResume: enabled
        )
    }

    func handle(_ event: RecordingHealthEvent) {
        if let enabled = event.locationEnabled {
            watchLocationEnabled = enabled
        }
        if let authorization = event.locationAuthorization {
            watchAuthorization = authorization
        }
        if let bytes = event.locationTrackBytes {
            watchTrackBytes = bytes
        }
        if let enabled = event.locationEnabled,
            let updatedAtMs = event.locationSettingUpdatedAtMs
        {
            let reported = LocationSetting(
                enabled: enabled,
                updatedAtMs: updatedAtMs
            )
            if reported.isNewer(than: locationSetting) {
                locationSetting = reported
                persist(reported)
            }
        }

        if let autoResume = event.autoResume {
            watchAutoResume = autoResume
        }
        if let silentResume = event.silentResume {
            watchSilentResume = silentResume
        }
        if let autoResume = event.autoResume,
            let silentResume = event.silentResume,
            let updatedAtMs = event.resumeSettingsUpdatedAtMs
        {
            let reported = ResumeSettingsCommand(
                autoResume: autoResume,
                silentResume: silentResume,
                updatedAtMs: updatedAtMs
            )
            if reported.isNewer(than: resumeSettings) {
                resumeSettings = reported
                persist(reported)
            }
        }
    }

    private func applyLocalResume(
        autoResume: Bool,
        silentResume: Bool
    ) {
        let now = TimeMath.epochMs(Date())
        let next = ResumeSettingsCommand(
            autoResume: autoResume,
            silentResume: silentResume,
            updatedAtMs: max(now, resumeSettings.updatedAtMs + 1)
        )
        resumeSettings = next
        persist(next)
        _ = resumeSender?.sendResumeSettings(next)
    }

    private func persist(_ setting: LocationSetting) {
        defaults.set(setting.enabled, forKey: Keys.locationEnabled)
        defaults.set(setting.updatedAtMs, forKey: Keys.locationUpdatedAt)
    }

    private func persist(_ command: ResumeSettingsCommand) {
        defaults.set(command.autoResume, forKey: Keys.autoResume)
        defaults.set(command.silentResume, forKey: Keys.silentResume)
        defaults.set(command.updatedAtMs, forKey: Keys.resumeUpdatedAt)
    }
}

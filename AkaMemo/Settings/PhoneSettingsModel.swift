import AkaMemoCore
import Foundation
import Observation

protocol LocationSettingSending: AnyObject, Sendable {
    func sendLocationSetting(_ setting: LocationSetting) -> Bool
}

/// iPhone-side copy of the global location switch. The Watch reports its
/// effective setting in health events; the newer timestamp wins so a toggle on
/// either device is not overwritten by a stale copy.
@MainActor
@Observable
final class PhoneSettingsModel {
    enum Keys {
        static let locationEnabled = "location.enabled"
        static let locationUpdatedAt = "location.enabledUpdatedAt"
    }

    private let defaults: UserDefaults
    private var sender: (any LocationSettingSending)?
    private(set) var locationSetting: LocationSetting
    private(set) var watchLocationEnabled: Bool?
    private(set) var watchAuthorization: String?
    private(set) var watchTrackBytes: Int64?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled =
            defaults.object(forKey: Keys.locationEnabled) as? Bool ?? true
        let updatedAt =
            (defaults.object(forKey: Keys.locationUpdatedAt) as? NSNumber)?
            .int64Value ?? 0
        self.locationSetting = LocationSetting(
            enabled: enabled,
            updatedAtMs: updatedAt
        )
    }

    var isLocationEnabled: Bool { locationSetting.enabled }

    func attach(sender: any LocationSettingSending) {
        self.sender = sender
    }

    /// Re-sends the persisted setting after activation or foregrounding.
    func publishLocationSetting() {
        _ = sender?.sendLocationSetting(locationSetting)
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
        _ = sender?.sendLocationSetting(next)
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
        guard let enabled = event.locationEnabled,
            let updatedAtMs = event.locationSettingUpdatedAtMs
        else {
            return
        }
        let reported = LocationSetting(
            enabled: enabled,
            updatedAtMs: updatedAtMs
        )
        guard reported.isNewer(than: locationSetting) else {
            return
        }
        locationSetting = reported
        persist(reported)
    }

    private func persist(_ setting: LocationSetting) {
        defaults.set(setting.enabled, forKey: Keys.locationEnabled)
        defaults.set(setting.updatedAtMs, forKey: Keys.locationUpdatedAt)
    }
}

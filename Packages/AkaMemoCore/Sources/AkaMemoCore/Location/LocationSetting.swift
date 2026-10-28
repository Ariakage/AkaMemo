import Foundation

/// The global "record location with recording" switch from FR-024.
///
/// Both the Watch and the iPhone persist a copy. The timestamp makes the last
/// explicit change win when the two devices are briefly out of sync; it is the
/// only conflict metadata exchanged, never a coordinate.
public struct LocationSetting: Codable, Sendable, Equatable {
    public static let metadataKey = "akamemo.locationSetting"

    public let enabled: Bool
    public let updatedAtMs: Int64

    public init(enabled: Bool, updatedAtMs: Int64) {
        self.enabled = enabled
        self.updatedAtMs = updatedAtMs
    }

    public func isNewer(than other: LocationSetting?) -> Bool {
        guard let other else { return true }
        return updatedAtMs > other.updatedAtMs
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocationSettingError.invalidEncoding
        }
        return string
    }

    public static func decode(fromJSON string: String) throws -> LocationSetting {
        guard let data = string.data(using: .utf8) else {
            throw LocationSettingError.invalidEncoding
        }
        return try JSONDecoder().decode(LocationSetting.self, from: data)
    }
}

public enum LocationSettingError: Error, Equatable, Sendable {
    case invalidEncoding
}

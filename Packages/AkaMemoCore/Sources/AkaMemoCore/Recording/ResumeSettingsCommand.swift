import Foundation

/// The iPhone copy of the Watch's "自动恢复 / 静默恢复" switches. A single
/// timestamp makes the last explicit change win on both devices.
public struct ResumeSettingsCommand: Codable, Sendable, Equatable {
    public static let metadataKey = "akamemo.resumeSettings"

    public let autoResume: Bool
    public let silentResume: Bool
    public let updatedAtMs: Int64

    public init(
        autoResume: Bool,
        silentResume: Bool,
        updatedAtMs: Int64
    ) {
        self.autoResume = autoResume
        self.silentResume = silentResume
        self.updatedAtMs = updatedAtMs
    }

    public func isNewer(than other: ResumeSettingsCommand?) -> Bool {
        guard let other else { return true }
        return updatedAtMs > other.updatedAtMs
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ResumeSettingsCommandError.invalidEncoding
        }
        return string
    }

    public static func decode(
        fromJSON string: String
    ) throws -> ResumeSettingsCommand {
        guard let data = string.data(using: .utf8) else {
            throw ResumeSettingsCommandError.invalidEncoding
        }
        return try JSONDecoder().decode(ResumeSettingsCommand.self, from: data)
    }
}

public enum ResumeSettingsCommandError: Error, Equatable, Sendable {
    case invalidEncoding
}

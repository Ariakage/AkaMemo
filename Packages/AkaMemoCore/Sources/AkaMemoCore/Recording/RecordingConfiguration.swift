import Foundation

/// Recording defaults shared by the watch recorder and the phone importer.
///
/// Values follow `docs/specs/recording.md` and ADR-0011. Changing audio
/// parameters is a compatibility change and requires a new `formatVersion`.
public enum RecordingConfiguration {
    public static let audioFormatVersion = 1
    public static let sampleRate = 44_100
    public static let defaultChannelCount = 2
    public static let bitRatePerChannel = 96_000

    public static let chunkDuration: TimeInterval = 60
    public static let maximumChunkBytes = 2 * 1024 * 1024

    public static let heartbeatInterval: TimeInterval = 10
    public static let watchdogCheckInterval: TimeInterval = 5
    public static let audioBufferWarningThreshold: TimeInterval = 10
    public static let audioBufferInterruptionThreshold: TimeInterval = 30
    public static let recoveryDelays: [TimeInterval] = [1, 5, 15]

    public static let storageWarningBytes: Int64 = 1024 * 1024 * 1024
    public static let storageStopBytes: Int64 = 500 * 1024 * 1024

    public static let phoneHeartbeatAlertThreshold: TimeInterval = 45
    public static let phoneDeadManThreshold: TimeInterval = 90
    public static let notificationDedupWindow: TimeInterval = 5 * 60
}

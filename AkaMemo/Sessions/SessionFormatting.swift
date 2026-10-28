import Foundation

enum SessionFormatting {
    static func durationText(_ milliseconds: Int64) -> String {
        let clamped = max(0, milliseconds)
        return Duration.milliseconds(clamped)
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    static func clockText(_ seconds: TimeInterval) -> String {
        let milliseconds = Int64((max(0, seconds) * 1000).rounded())
        return Duration.milliseconds(milliseconds)
            .formatted(.time(pattern: .minuteSecond))
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}

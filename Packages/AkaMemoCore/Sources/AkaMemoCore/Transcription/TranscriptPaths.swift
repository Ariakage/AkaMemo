import Foundation

public enum TranscriptPaths {
    /// `transcripts/YYYY/MM/DD/<chunkID>/<transcriptID>.json` in UTC.
    public static func relativePath(
        chunkStartedAtMs: Int64,
        chunkID: UUID,
        transcriptID: UUID
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = TimeMath.date(epochMs: chunkStartedAtMs)
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return
            "transcripts/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))/\(chunkID.uuidString)/\(transcriptID.uuidString).json"
    }

    public static func relativePath(
        chunkStartedAt: Date,
        chunkID: UUID,
        transcriptID: UUID
    ) -> String {
        relativePath(
            chunkStartedAtMs: TimeMath.epochMs(chunkStartedAt),
            chunkID: chunkID,
            transcriptID: transcriptID
        )
    }
}

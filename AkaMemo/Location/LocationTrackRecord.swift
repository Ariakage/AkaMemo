import AkaMemoCore
import Foundation
import SwiftData

/// iPhone-side metadata for an imported Watch track. JSONL stays on disk.
@Model
final class LocationTrackRecord {
    var trackID: UUID
    var sessionID: UUID
    var sessionStartedAt: Date
    var startedAt: Date
    var endedAt: Date
    var pointCount: Int
    var distanceMeters: Double?
    var stateRaw: String
    var relativePath: String
    var checksumSHA256: String
    var importedAt: Date

    init(
        trackID: UUID,
        sessionID: UUID,
        sessionStartedAt: Date,
        startedAt: Date,
        endedAt: Date,
        pointCount: Int,
        distanceMeters: Double?,
        stateRaw: String = "completed",
        relativePath: String,
        checksumSHA256: String,
        importedAt: Date
    ) {
        self.trackID = trackID
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pointCount = pointCount
        self.distanceMeters = distanceMeters
        self.stateRaw = stateRaw
        self.relativePath = relativePath
        self.checksumSHA256 = checksumSHA256
        self.importedAt = importedAt
    }
}

enum TrackPaths {
    static func relativePath(
        sessionStartedAtMs: Int64,
        sessionID: UUID
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = TimeMath.date(epochMs: sessionStartedAtMs)
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return
            "location/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))/\(sessionID.uuidString).jsonl"
    }
}

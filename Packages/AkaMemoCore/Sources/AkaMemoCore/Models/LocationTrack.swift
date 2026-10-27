import Foundation

public enum TrackState: String, Codable, Sendable {
    case recording
    case completed
    case degraded
    case unavailable
    case interrupted
    case failed
}

public struct LocationTrack: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let sessionStartedAt: Date
    public var startedAt: Date
    public var endedAt: Date?
    public var source: String
    public var state: TrackState
    public var pointCount: Int
    public var distanceMeters: Double?
    public var relativePath: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sessionStartedAt: Date,
        startedAt: Date,
        endedAt: Date? = nil,
        source: String = "watch",
        state: TrackState = .recording,
        pointCount: Int = 0,
        distanceMeters: Double? = nil,
        relativePath: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.state = state
        self.pointCount = pointCount
        self.distanceMeters = distanceMeters
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LocationPoint: Codable, Sendable, Equatable {
    public let timestampMs: Int64
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double?
    public let speed: Double?
    public let course: Double?

    public init(
        timestampMs: Int64,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double,
        verticalAccuracy: Double? = nil,
        speed: Double? = nil,
        course: Double? = nil
    ) {
        self.timestampMs = timestampMs
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
    }
}

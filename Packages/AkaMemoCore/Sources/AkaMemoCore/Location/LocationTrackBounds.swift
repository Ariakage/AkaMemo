import Foundation

/// The coordinate envelope of a track, padded for a map camera.
///
/// Invalid or non-finite points are ignored. A single point still yields a
/// usable region with the minimum span.
public struct LocationTrackBounds: Sendable, Equatable {
    public static let minimumSpan = 0.002

    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    public init?(points: [LocationPoint]) {
        var minLatitude = Double.infinity
        var maxLatitude = -Double.infinity
        var minLongitude = Double.infinity
        var maxLongitude = -Double.infinity
        var found = false

        for point in points where Self.isUsable(point) {
            found = true
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        guard found else {
            return nil
        }
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    public var centerLatitude: Double {
        (minLatitude + maxLatitude) / 2
    }

    public var centerLongitude: Double {
        (minLongitude + maxLongitude) / 2
    }

    public var latitudeSpan: Double {
        max((maxLatitude - minLatitude) * 1.4, Self.minimumSpan)
    }

    public var longitudeSpan: Double {
        max((maxLongitude - minLongitude) * 1.4, Self.minimumSpan)
    }

    private static func isUsable(_ point: LocationPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }
}

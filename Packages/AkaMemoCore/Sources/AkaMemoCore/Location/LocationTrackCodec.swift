import Foundation

/// Sampling rules from `docs/specs/gps-tracking.md` §3.
public struct LocationSamplingPolicy: Sendable, Equatable {
    public static let standard = LocationSamplingPolicy()

    public let intervalMs: Int64
    public let maximumHorizontalAccuracy: Double
    public let lowConfidenceAccuracy: Double

    public init(
        intervalMs: Int64 = 5 * 60 * 1_000,
        maximumHorizontalAccuracy: Double = 100,
        lowConfidenceAccuracy: Double = 50
    ) {
        self.intervalMs = intervalMs
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
        self.lowConfidenceAccuracy = lowConfidenceAccuracy
    }

    public func isValid(_ point: LocationPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy.isFinite
            && point.horizontalAccuracy >= 0
            && point.horizontalAccuracy <= maximumHorizontalAccuracy
            && point.timestampMs > 0
    }

    public func isLowConfidence(_ point: LocationPoint) -> Bool {
        point.horizontalAccuracy > lowConfidenceAccuracy
    }

    public func shouldRecord(
        _ point: LocationPoint,
        lastRecordedAtMs: Int64?
    ) -> Bool {
        guard isValid(point) else {
            return false
        }
        guard let lastRecordedAtMs else {
            return true
        }
        return point.timestampMs - lastRecordedAtMs >= intervalMs
    }
}

/// JSONL line format with the short keys documented in the GPS spec.
public enum LocationTrackCodec {
    public struct DecodeResult: Sendable, Equatable {
        public let points: [LocationPoint]
        public let invalidLineCount: Int
    }

    private struct CodedPoint: Codable {
        let t: Int64
        let lat: Double
        let lon: Double
        let alt: Double?
        let hAcc: Double
        let vAcc: Double?
        let speed: Double?
        let course: Double?
    }

    public static func encodeLine(_ point: LocationPoint) throws -> Data {
        let coded = CodedPoint(
            t: point.timestampMs,
            lat: point.latitude,
            lon: point.longitude,
            alt: point.altitude,
            hAcc: point.horizontalAccuracy,
            vAcc: point.verticalAccuracy,
            speed: point.speed,
            course: point.course
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(coded)
        data.append(0x0A)
        return data
    }

    /// Decodes all parseable lines and reports how many lines were dropped.
    public static func decode(_ data: Data) -> DecodeResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return DecodeResult(points: [], invalidLineCount: 1)
        }
        var points: [LocationPoint] = []
        var invalid = 0
        for line in text.split(separator: "\n") {
            guard !line.isEmpty else {
                continue
            }
            guard let lineData = line.data(using: .utf8),
                let coded = try? JSONDecoder().decode(
                    CodedPoint.self,
                    from: lineData
                )
            else {
                invalid += 1
                continue
            }
            let point = LocationPoint(
                timestampMs: coded.t,
                latitude: coded.lat,
                longitude: coded.lon,
                altitude: coded.alt,
                horizontalAccuracy: coded.hAcc,
                verticalAccuracy: coded.vAcc,
                speed: coded.speed,
                course: coded.course
            )
            if LocationSamplingPolicy.standard.isValid(point) {
                points.append(point)
            } else {
                invalid += 1
            }
        }
        return DecodeResult(points: points, invalidLineCount: invalid)
    }

    /// Total distance using the haversine formula. Returns nil for <2 points.
    public static func distanceMeters(_ points: [LocationPoint]) -> Double? {
        guard points.count >= 2 else {
            return nil
        }
        var total = 0.0
        for index in 1..<points.count {
            total += haversine(points[index - 1], points[index])
        }
        return total
    }

    /// Keeps only points inside the session time range.
    public static func trim(
        _ points: [LocationPoint],
        sessionStartedAtMs: Int64,
        endedAtMs: Int64?
    ) -> [LocationPoint] {
        points.filter { point in
            guard point.timestampMs >= sessionStartedAtMs else {
                return false
            }
            if let endedAtMs, point.timestampMs > endedAtMs {
                return false
            }
            return true
        }
    }

    private static func haversine(
        _ first: LocationPoint,
        _ second: LocationPoint
    ) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let deltaLat = (second.latitude - first.latitude) * .pi / 180
        let deltaLon = (second.longitude - first.longitude) * .pi / 180
        let a =
            sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}

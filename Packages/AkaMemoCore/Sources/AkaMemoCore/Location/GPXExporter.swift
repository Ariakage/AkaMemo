import Foundation

public enum GPXExporter {
    /// Builds GPX 1.1 from points inside the session time range.
    /// Returns nil when no point remains (callers must show "no track").
    public static func gpx(
        points: [LocationPoint],
        sessionStartedAtMs: Int64,
        endedAtMs: Int64?
    ) -> String? {
        let trimmed = LocationTrackCodec.trim(
            sorted(points),
            sessionStartedAtMs: sessionStartedAtMs,
            endedAtMs: endedAtMs
        )
        guard !trimmed.isEmpty else {
            return nil
        }
        let sessionDate = TimeMath.date(epochMs: sessionStartedAtMs)
        let name = "AkaMemo \(nameString(sessionDate))"
        let firstTime = isoString(
            TimeMath.date(epochMs: trimmed[0].timestampMs)
        )

        var output = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="AkaMemo" xmlns="http://www.topografix.com/GPX/1/1">
              <metadata>
                <name>\(name)</name>
                <time>\(firstTime)</time>
              </metadata>
              <trk>
                <name>\(name)</name>
                <trkseg>

            """
        for point in trimmed {
            let time = isoString(
                TimeMath.date(epochMs: point.timestampMs)
            )
            output +=
                "      <trkpt lat=\"\(coordinate(point.latitude))\" lon=\"\(coordinate(point.longitude))\">\n"
            if let altitude = point.altitude, altitude.isFinite {
                output += "        <ele>\(coordinate(altitude))</ele>\n"
            }
            output += "        <time>\(time)</time>\n"
            output += "      </trkpt>\n"
        }
        output += """
                </trkseg>
              </trk>
            </gpx>

            """
        return output
    }

    public static func fileName(
        sessionStartedAtMs: Int64,
        sessionID: UUID
    ) -> String {
        let date = TimeMath.date(epochMs: sessionStartedAtMs)
        let shortID = String(sessionID.uuidString.prefix(8))
        return "AkaMemo-\(fileString(date))-\(shortID).gpx"
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .gmt
        return formatter.string(from: date)
    }

    private static func nameString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func fileString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func sorted(_ points: [LocationPoint]) -> [LocationPoint] {
        points.sorted { $0.timestampMs < $1.timestampMs }
    }
}

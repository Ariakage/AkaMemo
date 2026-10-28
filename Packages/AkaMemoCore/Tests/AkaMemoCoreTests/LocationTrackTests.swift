import XCTest

@testable import AkaMemoCore

final class LocationTrackTests: XCTestCase {
    private func point(
        timestampMs: Int64,
        latitude: Double = 31.2304,
        longitude: Double = 121.4737,
        accuracy: Double = 8.5
    ) -> LocationPoint {
        LocationPoint(
            timestampMs: timestampMs,
            latitude: latitude,
            longitude: longitude,
            altitude: 12.3,
            horizontalAccuracy: accuracy
        )
    }

    func testSamplingPolicyRejectsInvalidAccuracyAndEnforcesInterval() {
        let policy = LocationSamplingPolicy.standard
        XCTAssertTrue(policy.isValid(point(timestampMs: 1_000)))
        XCTAssertFalse(policy.isValid(point(timestampMs: 1_000, accuracy: 150)))
        XCTAssertFalse(
            policy.isValid(
                point(timestampMs: 1_000, latitude: 120, longitude: 200)
            )
        )
        XCTAssertTrue(
            policy.shouldRecord(point(timestampMs: 1_000), lastRecordedAtMs: nil)
        )
        XCTAssertFalse(
            policy.shouldRecord(
                point(timestampMs: 100_000),
                lastRecordedAtMs: 1_000
            )
        )
        XCTAssertTrue(
            policy.shouldRecord(
                point(timestampMs: 301_000),
                lastRecordedAtMs: 1_000
            )
        )
    }

    func testJSONLRoundTripAndInvalidLineCount() throws {
        let first = point(timestampMs: 1_000)
        let second = point(timestampMs: 302_000, latitude: 31.2310)
        var data = try LocationTrackCodec.encodeLine(first)
        data.append(try LocationTrackCodec.encodeLine(second))
        data.append(Data("{not json}\n".utf8))

        let decoded = LocationTrackCodec.decode(data)

        XCTAssertEqual(decoded.points, [first, second])
        XCTAssertEqual(decoded.invalidLineCount, 1)
    }

    func testDistanceIsApproximate() {
        let first = point(timestampMs: 1_000, latitude: 31.2304, longitude: 121.4737)
        let second = point(timestampMs: 2_000, latitude: 31.2304, longitude: 121.4837)
        let distance = LocationTrackCodec.distanceMeters([first, second])

        XCTAssertNotNil(distance)
        XCTAssertEqual(distance ?? 0, 953, accuracy: 20)
    }

    func testTrimUsesSessionRange() {
        let points = [
            point(timestampMs: 500),
            point(timestampMs: 1_000),
            point(timestampMs: 2_000),
            point(timestampMs: 3_000),
        ]

        let trimmed = LocationTrackCodec.trim(
            points,
            sessionStartedAtMs: 1_000,
            endedAtMs: 2_000
        )

        XCTAssertEqual(trimmed.map(\.timestampMs), [1_000, 2_000])
    }

    func testGPXContainsTrimmedPointsAndMetadata() throws {
        let sessionStart: Int64 = 1_800_000_000_000
        let points = [
            point(timestampMs: sessionStart - 1_000),
            point(timestampMs: sessionStart + 1_000),
            point(
                timestampMs: sessionStart + 301_000,
                latitude: 31.2310
            ),
            point(timestampMs: sessionStart + 600_000),
        ]

        let gpx = try XCTUnwrap(
            GPXExporter.gpx(
                points: points,
                sessionStartedAtMs: sessionStart,
                endedAtMs: sessionStart + 400_000
            )
        )

        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\" creator=\"AkaMemo\""))
        XCTAssertEqual(
            gpx.components(separatedBy: "<trkpt").count - 1,
            2
        )
        XCTAssertTrue(gpx.contains("<time>2027-01-15T08:00:01Z</time>"))
        XCTAssertTrue(gpx.contains("lat=\"31.230400\""))
        XCTAssertTrue(gpx.contains("31.231000"))

        let empty = GPXExporter.gpx(
            points: [point(timestampMs: 500)],
            sessionStartedAtMs: sessionStart,
            endedAtMs: nil
        )
        XCTAssertNil(empty)
    }

    func testGPXFileNameHasNoLocationContent() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")
        )
        let name = GPXExporter.fileName(
            sessionStartedAtMs: 1_800_000_000_000,
            sessionID: id
        )

        XCTAssertTrue(name.hasPrefix("AkaMemo-20270115-"))
        XCTAssertTrue(name.hasSuffix("-12345678.gpx"))
        XCTAssertFalse(name.lowercased().contains("shanghai"))
    }

    func testTrackEnvelopeRoundTripsAndValidates() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")
        )
        let envelope = TrackTransferEnvelope(
            trackID: UUID(),
            sessionID: id,
            sessionStartedAtMs: 1_800_000_000_000,
            startedAtMs: 1_800_000_000_000,
            endedAtMs: 1_800_000_600_000,
            pointCount: 3,
            checksumSHA256: String(repeating: "a", count: 64),
            relativePath: "location/\(id.uuidString).jsonl"
        )

        let decoded = try TrackTransferEnvelope.decode(
            fromJSON: try envelope.jsonString()
        )
        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(envelope.isValid)
        XCTAssertFalse(
            TrackTransferEnvelope(
                trackID: UUID(),
                sessionID: id,
                sessionStartedAtMs: 1,
                startedAtMs: 1,
                endedAtMs: 2,
                pointCount: 0,
                checksumSHA256: String(repeating: "a", count: 64),
                relativePath: "location/a.jsonl"
            ).isValid
        )
    }
}

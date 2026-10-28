import XCTest

@testable import AkaMemoCore

final class LocationTrackBoundsTests: XCTestCase {
    private func point(
        _ latitude: Double,
        _ longitude: Double
    ) -> LocationPoint {
        LocationPoint(
            timestampMs: 1_000,
            latitude: latitude,
            longitude: longitude,
            altitude: nil,
            horizontalAccuracy: 8
        )
    }

    func testEmptyAndInvalidPointsYieldNil() {
        XCTAssertNil(LocationTrackBounds(points: []))
        XCTAssertNil(
            LocationTrackBounds(
                points: [
                    point(100, 0),
                    point(0, 200),
                    point(.nan, 0),
                ]
            )
        )
    }

    func testSinglePointUsesMinimumSpan() {
        let bounds = LocationTrackBounds(
            points: [point(0.001, 0.002)]
        )

        XCTAssertEqual(bounds?.centerLatitude, 0.001)
        XCTAssertEqual(bounds?.centerLongitude, 0.002)
        XCTAssertEqual(
            bounds?.latitudeSpan,
            LocationTrackBounds.minimumSpan
        )
        XCTAssertEqual(
            bounds?.longitudeSpan,
            LocationTrackBounds.minimumSpan
        )
    }

    func testMultiplePointsPadTheEnvelope() {
        let bounds = LocationTrackBounds(
            points: [
                point(0.001, 0.001),
                point(0.003, 0.004),
            ]
        )

        XCTAssertEqual(bounds?.minLatitude, 0.001)
        XCTAssertEqual(bounds?.maxLatitude, 0.003)
        XCTAssertEqual(bounds?.centerLatitude, 0.002)
        XCTAssertEqual(bounds?.latitudeSpan ?? 0, 0.0028, accuracy: 0.0001)
        XCTAssertEqual(bounds?.longitudeSpan ?? 0, 0.0042, accuracy: 0.0001)
    }
}

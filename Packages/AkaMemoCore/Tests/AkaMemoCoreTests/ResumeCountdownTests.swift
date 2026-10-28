import XCTest

@testable import AkaMemoCore

final class ResumeCountdownTests: XCTestCase {
    func testCountdownFinishesAfterThreeSeconds() {
        var countdown = ResumeCountdown()
        XCTAssertFalse(countdown.isActive)

        countdown.start()
        XCTAssertTrue(countdown.isActive)
        XCTAssertEqual(countdown.remainingSeconds, 3)

        XCTAssertFalse(countdown.advance())
        XCTAssertEqual(countdown.remainingSeconds, 2)
        XCTAssertFalse(countdown.advance())
        XCTAssertEqual(countdown.remainingSeconds, 1)
        XCTAssertTrue(countdown.advance())
        XCTAssertFalse(countdown.isActive)
        XCTAssertNil(countdown.remainingSeconds)
    }

    func testCancelStopsTheCountdown() {
        var countdown = ResumeCountdown()
        countdown.start()
        countdown.cancel()

        XCTAssertFalse(countdown.isActive)
        XCTAssertFalse(countdown.advance())
    }

    func testAdvanceWithoutStartDoesNothing() {
        var countdown = ResumeCountdown()

        XCTAssertFalse(countdown.advance())
        XCTAssertNil(countdown.remainingSeconds)
    }

    func testTotalSecondsIsAtLeastOne() {
        let countdown = ResumeCountdown(totalSeconds: 0)

        XCTAssertEqual(countdown.totalSeconds, 1)
    }
}

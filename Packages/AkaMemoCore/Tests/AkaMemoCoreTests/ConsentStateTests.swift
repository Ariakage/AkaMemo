import XCTest

@testable import AkaMemoCore

final class ConsentStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AkaMemoConsentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testConsentStartsIncompleteAndPersists() {
        XCTAssertFalse(ConsentState.isCompleted(defaults: defaults))

        ConsentState.markCompleted(defaults: defaults)
        XCTAssertTrue(ConsentState.isCompleted(defaults: defaults))

        ConsentState.reset(defaults: defaults)
        XCTAssertFalse(ConsentState.isCompleted(defaults: defaults))
    }
}

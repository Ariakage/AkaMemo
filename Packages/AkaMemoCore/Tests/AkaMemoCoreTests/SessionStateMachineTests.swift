import XCTest

@testable import AkaMemoCore

final class SessionStateMachineTests: XCTestCase {
    private func next(
        _ state: RecordingSession.State,
        _ transition: SessionTransition,
        autoRecovery: Bool = true
    ) -> RecordingSession.State? {
        SessionStateMachine.nextState(
            from: state,
            on: transition,
            autoRecoveryEnabled: autoRecovery
        )
    }

    func testPauseAndResume() {
        XCTAssertEqual(next(.recording, .pause), .paused)
        XCTAssertEqual(next(.paused, .resume), .recording)
        XCTAssertNil(next(.recording, .resume))
    }

    func testInterruptionAndForegroundResume() {
        XCTAssertEqual(next(.recording, .interruption), .interrupted)
        XCTAssertEqual(next(.interrupted, .resume), .recording)
    }

    func testAutomaticRecoveryRequiresEnabledSetting() {
        XCTAssertEqual(next(.interrupted, .beginRecovery, autoRecovery: true), .recovering)
        XCTAssertNil(next(.interrupted, .beginRecovery, autoRecovery: false))
        XCTAssertNil(next(.paused, .beginRecovery))
    }

    func testRecoveryOutcome() {
        XCTAssertEqual(next(.recovering, .recoverySucceeded), .recording)
        XCTAssertEqual(next(.recovering, .recoveryFailed), .interrupted)
    }

    func testStopFromEveryActiveStateFinalizes() {
        let activeStates: [RecordingSession.State] = [
            .recording, .paused, .interrupted, .recovering,
        ]
        for state in activeStates {
            XCTAssertEqual(next(state, .stop), .finalizing, "state \(state)")
        }
    }

    func testFinalizeOutcome() {
        XCTAssertEqual(next(.finalizing, .finalizeSucceeded), .completed)
        XCTAssertEqual(next(.finalizing, .finalizeFailed), .failed)
    }

    func testFatalErrorFailsEveryNonTerminalState() {
        let states: [RecordingSession.State] = [
            .recording, .paused, .interrupted, .recovering, .finalizing,
        ]
        for state in states {
            XCTAssertEqual(next(state, .fatalError), .failed, "state \(state)")
        }
    }

    func testTerminalStatesHaveNoTransitions() {
        for state in [RecordingSession.State.completed, .failed] {
            for transition in SessionTransition.allCases {
                XCTAssertNil(next(state, transition), "\(state) -> \(transition)")
            }
        }
    }

    func testInvalidTransitionsAreRejected() {
        XCTAssertNil(next(.paused, .interruption))
        XCTAssertNil(next(.recovering, .pause))
        XCTAssertNil(next(.completed, .stop))
        XCTAssertNil(next(.recording, .finalizeSucceeded))
    }
}

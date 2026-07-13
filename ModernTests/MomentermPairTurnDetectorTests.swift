//
//  MomentermPairTurnDetectorTests.swift
//  ModernTests
//
//  Unit coverage for the pairing turn/sentinel detector. The load-bearing
//  case is that an injected instruction which mentions the literal sentinel
//  mid-sentence must NOT be mistaken for the agent actually ending its turn —
//  only a standalone sentinel line counts.
//

import XCTest
@testable import iTerm2SharedARC

final class MomentermPairTurnDetectorTests: XCTestCase {

    // MARK: - END_TURN sentinel

    func testEndTurnStandaloneLineMatches() {
        let tail = "Here is my change.\nI updated the parser.\n[[END_TURN]]"
        XCTAssertTrue(MomentermPairTurnDetector.tailContainsEndTurn(tail))
    }

    func testEndTurnInsideBoxMatches() {
        let tail = "│ done reviewing         │\n│ [[END_TURN]] │"
        XCTAssertTrue(MomentermPairTurnDetector.tailContainsEndTurn(tail))
    }

    func testEndTurnMidSentenceInstructionDoesNotMatch() {
        // This is the echoed orchestrator instruction — the token is embedded
        // in a sentence, not standing alone, so it must not trigger a turn end.
        let tail = "마지막 줄에 [[END_TURN]] 을 단독으로 출력하세요. 반영해 수정하세요."
        XCTAssertFalse(MomentermPairTurnDetector.tailContainsEndTurn(tail))
    }

    func testEndTurnAbsent() {
        XCTAssertFalse(MomentermPairTurnDetector.tailContainsEndTurn("still working on it"))
    }

    // MARK: - APPROVED sentinel

    func testApprovedStandaloneMatches() {
        let tail = "The diff addresses the task correctly.\n[[APPROVED]]\n[[END_TURN]]"
        XCTAssertTrue(MomentermPairTurnDetector.tailContainsApproved(tail))
    }

    func testApprovedMidSentenceDoesNotMatch() {
        let tail = "reply with [[APPROVED]] when satisfied, otherwise give feedback."
        XCTAssertFalse(MomentermPairTurnDetector.tailContainsApproved(tail))
    }

    func testApprovedAbsent() {
        XCTAssertFalse(MomentermPairTurnDetector.tailContainsApproved("needs more work"))
    }

    // MARK: - Heuristic fallback classification

    func testWorkingWhenSpinnerPresent() {
        let tail = "⣷ Generating response…"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .working)
    }

    func testWorkingWhenInterruptHintPresent() {
        let tail = "Thinking… (esc to interrupt)"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .working)
    }

    func testAwaitingConfirmationOnYesNoGate() {
        let tail = "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .awaitingConfirmation)
    }

    func testReadyOnIdleComposer() {
        let tail = "All set.\n\n>\n? for shortcuts"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .ready)
    }

    func testEmptyTailIsWorking() {
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: ""), .working)
    }

    // Regression: an editor (claude) that finishes its turn with a numbered
    // summary list — extremely common — must be classified as .ready so the
    // orchestrator's ready-composer fallback can fire. Two+ numbered lines were
    // previously mistaken for a selection menu (.awaitingConfirmation), which
    // wedged the first handoff forever.
    func testReadyWhenIdleComposerHasNumberedSummary() {
        let tail = """
        ● I made the following changes:

          1. Updated the parser to handle the edge case
          2. Added a regression test
          3. Fixed the off-by-one error

        All tests pass.

        ╭──────────────────────────────╮
        │ >                            │
        ╰──────────────────────────────╯
          ? for shortcuts
        """
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .ready)
    }
}

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

    // Claude Code v2.1.208 live progress line: no braille spinner, no “esc to
    // interrupt”, no “Thinking” token — captured verbatim from a stalled relay.
    func testWorkingOnClaudeV2SparkleProgressLine() {
        let tail = "⏺ Searching for 1 pattern, reading 4 files…\n✳ Frolicking… (2m 6s · ↓ 1.3k tokens · almost done thinking)"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .working)
    }

    // Short turns never grow the parenthesized counters — the live frame is
    // just “✳ Jitterbugging…” (captured at 0.4s intervals from a real pane).
    // Requiring the “(” made observedWorking miss every fast turn.
    func testWorkingOnBareSparkleProgressLine() {
        for glyph in ["·", "✢", "✳", "✶", "✻", "✽"] {
            let tail = "❯ 1 더하기 1은?\n\(glyph) Jitterbugging…"
            XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .working,
                           "glyph \(glyph) should read as working")
        }
    }

    func testReadyOnFinishedWorkedForLine() {
        let tail = "  [[END_TURN]]\n✻ Worked for 9s\n❯ "
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .ready)
    }

    // The FINISHED form of the same line has no parenthesized live counters
    // and must read as a ready composer, or a completed turn would never end.
    func testReadyOnClaudeV2FinishedSparkleLine() {
        let tail = "  [[END_TURN]]\n✻ Sautéed for 15s\n❯ "
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .ready)
        XCTAssertTrue(MomentermPairTurnDetector.tailContainsEndTurn(tail))
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
    // MARK: - Turn-boundary decision (stale-sentinel safety)

    private let sentinelGrace: TimeInterval = 2
    private let readyGrace: TimeInterval = 5

    // The load-bearing regression: a prior turn's [[END_TURN]] is still sitting
    // in the screen tail, but the speaker has NOT been observed working since
    // this turn began. A brief quiet moment must NOT be read as a turn end —
    // otherwise a leftover sentinel (e.g. from the previous editor/reviewer
    // turn) would trigger a premature transition before the peer even starts.
    func testLeftoverSentinelDoesNotEndTurnBeforeWorking() {
        let tail = "previous turn output\n[[END_TURN]]\n(new prompt echoed here)"
        XCTAssertFalse(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: false, idle: true, elapsed: 999,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    // Same guard for the ready-composer fallback: an idle ready composer with a
    // leftover screen cannot end a turn that never started working.
    func testReadyFallbackRequiresObservedWorking() {
        let tail = "All set.\n\n>\n? for shortcuts"
        XCTAssertFalse(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: false, idle: true, elapsed: 999,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    func testTurnEndsOnFreshSentinelAfterWorking() {
        let tail = "I made the change.\n[[END_TURN]]"
        XCTAssertTrue(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: true, elapsed: 3,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    // Sentinel present but still inside the response grace — this is our own
    // just-echoed instruction, not the reply, so the turn has not ended yet.
    func testSentinelWithinGraceDoesNotEndTurn() {
        let tail = "…마지막에 [[END_TURN]] 을 출력하세요\n[[END_TURN]]"
        XCTAssertFalse(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: true, elapsed: 1,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    func testReadyFallbackEndsTurnAfterWorkingWhenSentinelOmitted() {
        let tail = "Done.\n\n>\n? for shortcuts"
        XCTAssertTrue(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: true, elapsed: 6,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    // Regression (reviewer feedback): the user typing — or having queued —
    // their next message echoes keystrokes and keeps resetting the PTY idle
    // clock. An explicit fresh sentinel must hand the turn over anyway; only
    // screen content (no spinner) matters on this path.
    func testFreshSentinelEndsTurnEvenWhenNotIdle() {
        let tail = "I made the change.\n[[END_TURN]]"
        XCTAssertTrue(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: false, elapsed: 3,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    // But a sentinel on a pane that still LOOKS working (spinner / interrupt
    // hint in the tail) is a leftover above an active turn — not a turn end.
    func testSentinelOnStillWorkingPaneDoesNotEndTurn() {
        let tail = "[[END_TURN]]\n⣷ Thinking… (esc to interrupt)"
        XCTAssertFalse(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: false, elapsed: 999,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    // Regression (reviewer feedback): .awaitingConfirmation is defined as “not
    // a finished turn”. A prior turn's sentinel lingering above a y/N /
    // permission / plan-approval gate must not be read as a fresh turn end —
    // the sentinel path only fires on a ready composer.
    func testSentinelAboveInteractiveGateDoesNotEndTurn() {
        let tail = "[[END_TURN]]\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select"
        XCTAssertFalse(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: true, elapsed: 999,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    func testApprovalAboveInteractiveGateRejected() {
        let tail = "[[APPROVED]]\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select"
        XCTAssertFalse(MomentermPairTurnDetector.isApproval(
            observedWorking: true, elapsed: 999, tail: tail, grace: sentinelGrace))
    }

    // The no-sentinel fallback keeps the strict PTY-idle requirement — a ready
    // composer alone, on a pane that is still emitting output, proves nothing.
    func testReadyFallbackStillRequiresIdle() {
        let tail = "Done.\n\n>\n? for shortcuts"
        XCTAssertFalse(MomentermPairTurnDetector.isTurnEnd(
            observedWorking: true, idle: false, elapsed: 999,
            tail: tail, sentinelGrace: sentinelGrace, readyGrace: readyGrace))
    }

    // MARK: - Approval decision

    func testApprovalRequiresObservedWorking() {
        let tail = "Looks great.\n[[APPROVED]]"
        XCTAssertFalse(MomentermPairTurnDetector.isApproval(
            observedWorking: false, elapsed: 999, tail: tail, grace: sentinelGrace))
    }

    func testApprovalIgnoresIdleAndFiresOnFreshToken() {
        let tail = "Looks great.\n[[APPROVED]]"
        XCTAssertTrue(MomentermPairTurnDetector.isApproval(
            observedWorking: true, elapsed: 3, tail: tail, grace: sentinelGrace))
    }

    func testApprovalRejectedWhileStillWorking() {
        let tail = "[[APPROVED]]\n⣷ Generating… (esc to interrupt)"
        XCTAssertFalse(MomentermPairTurnDetector.isApproval(
            observedWorking: true, elapsed: 999, tail: tail, grace: sentinelGrace))
    }

    func testApprovalWithinGraceRejected() {
        let tail = "[[APPROVED]]"
        XCTAssertFalse(MomentermPairTurnDetector.isApproval(
            observedWorking: true, elapsed: 1, tail: tail, grace: sentinelGrace))
    }

    // MARK: - Heuristic classification

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

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
    // Requiring the “(” made observedWorking miss every fast turn. The ‘·’
    // frame is deliberately NOT matched (prose-bullet false positive).
    func testWorkingOnBareSparkleProgressLine() {
        for glyph in ["✢", "✳", "✶", "✻", "✽"] {
            let tail = "❯ 1 더하기 1은?\n\(glyph) Jitterbugging…"
            XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .working,
                           "glyph \(glyph) should read as working")
        }
    }

    func testReadyOnFinishedWorkedForLine() {
        let tail = "  [[END_TURN]]\n✻ Worked for 9s\n❯ "
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .ready)
    }

    // Prose lines must not pin the state at .working: a middle-dot bullet
    // with a trailing ellipsis, and a sparkle line whose ellipsis is NOT
    // glued to the first word, both read as ready (a bare composer prompt
    // is visible below them).
    func testReadyOnProseLinesResemblingProgress() {
        let bulletTail = "· 파일 로딩 작업 정리…\n❯ "
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: bulletTail), .ready)
        let sparkleProseTail = "✻ 파일 로딩… 완료\n❯ "
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: sparkleProseTail), .ready)
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

    // Regression (reviewer feedback): a screen we cannot classify must be
    // .unknown, NOT .ready — a novel CLI progress format (no braille spinner,
    // no known token, no sparkle-ellipsis shape) would otherwise be misread
    // as a finished turn by the fallback.
    func testUnknownOnNovelProgressFormat() {
        let tail = "◐ Munching bits (step 3 of 7)"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .unknown)
    }

    // A prompt glyph followed by text (queued input) is not an EMPTY composer;
    // without other composer evidence the screen stays .unknown.
    func testUnknownWhenPromptLineCarriesText() {
        let tail = "Some earlier output\n❯ fix the bug next"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .unknown)
    }

    func testReadyWhenIdleComposerHasNumberedSummary() {
        // An editor (claude) that finishes its turn with a numbered summary
        // list — extremely common — must be classified as .ready so the
        // orchestrator's fallback can fire (the boxed bare prompt below is the
        // composer evidence). Two+ numbered lines were once mistaken for a
        // selection menu (.awaitingConfirmation), which wedged the handoff.
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

    // MARK: - Turn-boundary decision (stale-sentinel safety)

    private let sentinelGrace: TimeInterval = 2
    private let readyGrace: TimeInterval = 5

    private func isTurnEnd(observedWorking: Bool,
                           screenChanged: Bool,
                           stableFor: TimeInterval,
                           elapsed: TimeInterval,
                           tail: String) -> Bool {
        return MomentermPairTurnDetector.isTurnEnd(
            observedWorking: observedWorking,
            screenChangedThisTurn: screenChanged,
            contentStableFor: stableFor,
            elapsed: elapsed,
            tail: tail,
            sentinelGrace: sentinelGrace,
            readyGrace: readyGrace)
    }

    // The load-bearing regression: a prior turn's [[END_TURN]] is still sitting
    // in the screen tail, but the speaker has NOT been observed working since
    // this turn began. A brief quiet moment must NOT be read as a turn end —
    // otherwise a leftover sentinel (e.g. from the previous editor/reviewer
    // turn) would trigger a premature transition before the peer even starts.
    func testLeftoverSentinelDoesNotEndTurnBeforeWorking() {
        let tail = "previous turn output\n[[END_TURN]]\n(new prompt echoed here)"
        XCTAssertFalse(isTurnEnd(observedWorking: false, screenChanged: true,
                                 stableFor: 999, elapsed: 999, tail: tail))
    }

    // Same guard for the ready-composer fallback: an idle ready composer with a
    // leftover screen cannot end a turn that never started working.
    func testReadyFallbackRequiresObservedWorking() {
        let tail = "All set.\n\n>\n? for shortcuts"
        XCTAssertFalse(isTurnEnd(observedWorking: false, screenChanged: true,
                                 stableFor: 999, elapsed: 999, tail: tail))
    }

    func testTurnEndsOnFreshSentinelAfterWorking() {
        let tail = "I made the change.\n[[END_TURN]]"
        XCTAssertTrue(isTurnEnd(observedWorking: true, screenChanged: true,
                                stableFor: 0, elapsed: 3, tail: tail))
    }

    // Sentinel present but still inside the response grace — this is our own
    // just-echoed instruction, not the reply, so the turn has not ended yet.
    func testSentinelWithinGraceDoesNotEndTurn() {
        let tail = "…마지막에 [[END_TURN]] 을 출력하세요\n[[END_TURN]]"
        XCTAssertFalse(isTurnEnd(observedWorking: true, screenChanged: true,
                                 stableFor: 999, elapsed: 1, tail: tail))
    }

    func testReadyFallbackEndsTurnAfterWorkingWhenSentinelOmitted() {
        let tail = "Done.\n\n>\n? for shortcuts"
        XCTAssertTrue(isTurnEnd(observedWorking: true, screenChanged: true,
                                stableFor: 6, elapsed: 6, tail: tail))
    }

    // Regression (reviewer feedback): the user typing — or a status line
    // repainting every second — keeps the PTY permanently busy, so PTY idle
    // is not part of this API at all. A fresh sentinel hands the turn over
    // even while the screen is still churning (contentStableFor 0).
    func testFreshSentinelEndsTurnWhileScreenStillChanging() {
        let tail = "I made the change.\n[[END_TURN]]"
        XCTAssertTrue(isTurnEnd(observedWorking: true, screenChanged: true,
                                stableFor: 0, elapsed: 3, tail: tail))
    }

    // But a sentinel on a pane that still LOOKS working (spinner / interrupt
    // hint in the tail) is a leftover above an active turn — not a turn end.
    func testSentinelOnStillWorkingPaneDoesNotEndTurn() {
        let tail = "[[END_TURN]]\n⣷ Thinking… (esc to interrupt)"
        XCTAssertFalse(isTurnEnd(observedWorking: true, screenChanged: true,
                                 stableFor: 999, elapsed: 999, tail: tail))
    }

    // Regression (reviewer feedback): .awaitingConfirmation is defined as “not
    // a finished turn”. A prior turn's sentinel lingering above a y/N /
    // permission / plan-approval gate must not be read as a fresh turn end —
    // the sentinel path only fires once the pane is no longer engaged.
    func testSentinelAboveInteractiveGateDoesNotEndTurn() {
        let tail = "[[END_TURN]]\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select"
        XCTAssertFalse(isTurnEnd(observedWorking: true, screenChanged: true,
                                 stableFor: 999, elapsed: 999, tail: tail))
    }

    // MARK: - Ready fallback (screen stability replaces PTY idle)

    // Requirement: PTY output may never pause (per-second status line), but
    // once the meaningful body has been stable for readyGrace on an explicit
    // ready composer, the fallback ends the turn. PTY idle is not an input to
    // this decision — there is deliberately no such parameter.
    func testFallbackEndsWhenBodyStableDespiteOngoingPTYOutput() {
        let tail = "Summary of the change.\n\n❯ \n⏰ 14:03:22 · 12.3k tokens"
        XCTAssertTrue(isTurnEnd(observedWorking: true, screenChanged: true,
                                stableFor: 6, elapsed: 20, tail: tail))
    }

    // The fallback must wait for the normalized content to be stable for the
    // full grace — a body that changed a moment ago is still streaming.
    func testFallbackRequiresStableContent() {
        let tail = "Done.\n\n>\n? for shortcuts"
        XCTAssertFalse(isTurnEnd(observedWorking: true, screenChanged: true,
                                 stableFor: 1, elapsed: 999, tail: tail))
    }

    // A turn during which the screen never meaningfully changed cannot end via
    // the fallback — a static leftover screen proves nothing about this turn.
    func testFallbackRequiresScreenChangeThisTurn() {
        let tail = "Done.\n\n>\n? for shortcuts"
        XCTAssertFalse(isTurnEnd(observedWorking: true, screenChanged: false,
                                 stableFor: 999, elapsed: 999, tail: tail))
    }

    // Requirement: an .unknown screen (no working evidence, no gate, no
    // explicit composer) must NEVER end a turn via the ready fallback, no
    // matter how stable it is — only an explicit sentinel can.
    func testUnknownScreenDoesNotEndTurnViaFallback() {
        let tail = "◐ Munching bits (step 3 of 7)"
        XCTAssertEqual(MomentermPairTurnDetector.turnState(tail: tail), .unknown)
        XCTAssertFalse(isTurnEnd(observedWorking: true, screenChanged: true,
                                 stableFor: 999, elapsed: 999, tail: tail))
    }

    // A fresh sentinel on an .unknown screen still ends the turn: the agent's
    // explicit signal must not depend on us recognizing its composer chrome.
    func testFreshSentinelEndsTurnOnUnknownScreen() {
        let tail = "◐ Munched all bits\n[[END_TURN]]"
        XCTAssertTrue(isTurnEnd(observedWorking: true, screenChanged: true,
                                stableFor: 0, elapsed: 3, tail: tail))
    }

    // MARK: - Stability signature

    // Requirement: two screens that differ only in the user status line's
    // per-second numbers (clock, token usage — rendered below the composer)
    // must share one signature, or stability would never be reached.
    func testStatusLineOnlyChangesShareSignature() {
        let a = "● Done.\n\n❯ \n⏰ 14:32:05 · 12.3k tokens"
        let b = "● Done.\n\n❯ \n⏰ 14:32:06 · 12.4k tokens"
        XCTAssertEqual(MomentermPairTurnDetector.stabilitySignature(forTail: a),
                       MomentermPairTurnDetector.stabilitySignature(forTail: b))
    }

    // Volatile counters ABOVE the composer (elapsed time, token counts in
    // progress chrome) are normalized in place rather than dropped.
    func testVolatileCountersAboveComposerAreNormalized() {
        let a = "✻ Worked for 9s (↓ 1.2k tokens)\n❯ "
        let b = "✻ Worked for 12s (↓ 1.3k tokens)\n❯ "
        XCTAssertEqual(MomentermPairTurnDetector.stabilitySignature(forTail: a),
                       MomentermPairTurnDetector.stabilitySignature(forTail: b))
    }

    // Requirement: a response-body change must yield a NEW signature (it
    // resets the stability clock); sentinels are preserved verbatim.
    func testBodyChangeChangesSignature() {
        let a = "● Parsing the config file now.\n❯ \n⏰ 14:32:05"
        let b = "● Wrote the regression test.\n❯ \n⏰ 14:32:05"
        XCTAssertNotEqual(MomentermPairTurnDetector.stabilitySignature(forTail: a),
                          MomentermPairTurnDetector.stabilitySignature(forTail: b))
        let withSentinel = "All done.\n[[END_TURN]]\n❯ "
        XCTAssertTrue(MomentermPairTurnDetector.stabilitySignature(forTail: withSentinel)
            .contains("[[END_TURN]]"))
    }

    // MARK: - Per-turn screen tracker

    // Requirement: a new turn must never reuse the previous turn's screen
    // stability, change latch, or warning state.
    func testTrackerResetClearsPerTurnState() {
        var tracker = MomentermPairTurnScreenTracker()
        tracker.resetForNewTurn(now: 100)
        tracker.observe(signature: "a", now: 101)   // baseline, not a change
        XCTAssertFalse(tracker.changedThisTurn)
        tracker.observe(signature: "b", now: 103)   // meaningful change
        tracker.markWarned()
        XCTAssertTrue(tracker.changedThisTurn)
        XCTAssertTrue(tracker.warnedThisTurn)
        XCTAssertEqual(tracker.stableFor(now: 108), 5)

        tracker.resetForNewTurn(now: 200)
        XCTAssertFalse(tracker.changedThisTurn)
        XCTAssertFalse(tracker.warnedThisTurn)
        XCTAssertEqual(tracker.stableFor(now: 206), 6)
        // The first screen after the reset is the new baseline — even though
        // it differs from the previous turn's last signature.
        tracker.observe(signature: "c", now: 201)
        XCTAssertFalse(tracker.changedThisTurn)
        XCTAssertEqual(tracker.stableFor(now: 204), 3)
    }

    func testTrackerUnchangedSignatureKeepsStabilityClock() {
        var tracker = MomentermPairTurnScreenTracker()
        tracker.resetForNewTurn(now: 0)
        tracker.observe(signature: "a", now: 1)
        tracker.observe(signature: "a", now: 5)     // same content — no reset
        XCTAssertEqual(tracker.stableFor(now: 7), 6)
        tracker.observe(signature: "b", now: 8)     // body changed — clock resets
        XCTAssertEqual(tracker.stableFor(now: 9), 1)
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

    func testApprovalAboveInteractiveGateRejected() {
        let tail = "[[APPROVED]]\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select"
        XCTAssertFalse(MomentermPairTurnDetector.isApproval(
            observedWorking: true, elapsed: 999, tail: tail, grace: sentinelGrace))
    }

    func testApprovalWithinGraceRejected() {
        let tail = "[[APPROVED]]"
        XCTAssertFalse(MomentermPairTurnDetector.isApproval(
            observedWorking: true, elapsed: 1, tail: tail, grace: sentinelGrace))
    }
}

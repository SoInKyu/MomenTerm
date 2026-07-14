//
//  MomentermPairTurnDetector.swift
//  iTerm2
//
//  Turn-state classifier for the Codex ⇄ Claude pairing orchestrator
//  (MomentermPairSession). Two jobs:
//
//    1. Sentinel detection — the relay protocol asks each agent to end a
//       turn with a standalone `[[END_TURN]]` line, and the reviewer to emit
//       `[[APPROVED]]` when it is satisfied. The orchestrator polls the
//       speaker pane's rendered screen tail for these tokens.
//
//    2. Fallback turn classification — if an agent forgets the sentinel, the
//       orchestrator falls back to a heuristic: is the pane still working, is
//       it blocked on a confirmation gate (NOT a finished turn), or is it back
//       at an idle ready-for-input composer (treat as turn end).
//
//  Critical subtlety: the orchestrator injects an instruction that itself
//  contains the literal `[[END_TURN]]` string, which the terminal echoes back
//  onto the screen. To avoid matching our own echoed instruction, the sentinel
//  is matched ONLY as a standalone line (optionally wrapped in TUI box glyphs),
//  never mid-sentence. The relay prompt therefore asks the agent to print the
//  token on its own final line.
//
//  Approval is never inferred from the heuristic — only an explicit
//  `[[APPROVED]]` line converges the loop. A false-positive "ready" merely
//  hands the turn over early; a false-positive approval would silently ship
//  unreviewed work, so we refuse to guess it.
//

import Foundation

@objc(MomentermPairTurnState)
enum MomentermPairTurnState: Int {
    case working = 0            // 스트리밍/스피너 등 아직 작업 중
    case awaitingConfirmation   // (y/N)·메뉴 등 권한 게이트 — 턴 종료가 아님
    case ready                  // 유휴 입력 컴포저로 복귀 — 폴백 턴 종료 신호
}

@objc(MomentermPairTurnDetector)
final class MomentermPairTurnDetector: NSObject {

    @objc static let endTurnToken = "[[END_TURN]]"
    @objc static let approvedToken = "[[APPROVED]]"

    // Standalone-line matchers. Leading/trailing box-drawing, quote, list, or
    // prompt glyphs are tolerated so the token is still found when an agent
    // renders it inside a bordered TUI panel (`│ [[END_TURN]] │`). The key
    // property is that the token must occupy its own line — our injected
    // instruction carries the same literal mid-sentence and must NOT match.
    private static func standaloneRegex(for token: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?m)^[\\s>│┃|┆┇╎╏*\\-]*\(escaped)[\\s│┃|┆┇╎╏]*$"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    private static let endTurnRegex = standaloneRegex(for: endTurnToken)
    private static let approvedRegex = standaloneRegex(for: approvedToken)

    private static func containsStandalone(_ regex: NSRegularExpression?, in tail: String) -> Bool {
        guard let regex, !tail.isEmpty else { return false }
        let range = NSRange(tail.startIndex..., in: tail)
        return regex.firstMatch(in: tail, options: [], range: range) != nil
    }

    /// True when the tail carries an `[[END_TURN]]` line the agent emitted
    /// (a standalone line, not our echoed instruction).
    @objc(tailContainsEndTurn:)
    static func tailContainsEndTurn(_ tail: String) -> Bool {
        return containsStandalone(endTurnRegex, in: tail)
    }

    /// True when the reviewer signalled convergence with a standalone
    /// `[[APPROVED]]` line.
    @objc(tailContainsApproved:)
    static func tailContainsApproved(_ tail: String) -> Bool {
        return containsStandalone(approvedRegex, in: tail)
    }

    /// Pure turn-boundary decision, factored out of the orchestrator so it can
    /// be unit-tested without a live pane.
    ///
    ///   • `observedWorking` — the speaker was seen working since this turn
    ///     began. This is the load-bearing guard against stale sentinels: a
    ///     prior turn's `[[END_TURN]]` can still sit in the screen tail, so its
    ///     mere presence must NOT end a turn the speaker never actually started.
    ///   • Sentinel path (primary): a standalone `[[END_TURN]]` line after
    ///     `sentinelGrace`, judged by screen CONTENT — the pane must have
    ///     returned to a ready composer (`.ready`; a spinner OR an interactive
    ///     y/N·permission gate both mean the turn is still in flight, so a
    ///     lingering sentinel above them must not count). PTY quiet time is
    ///     deliberately NOT required. The user may already be typing (or have
    ///     queued) their next message, and every keystroke echo resets the PTY
    ///     idle clock — an explicit sentinel must still hand the turn over.
    ///   • Ready fallback: a turn that omitted the sentinel ends only on a
    ///     truly `idle` pane showing a ready composer after `readyGrace`.
    ///
    /// `elapsed` is time since the turn began (the last injection); the graces
    /// keep our own just-echoed instruction from being read as the reply.
    @objc(isTurnEndObservedWorking:idle:elapsed:tail:sentinelGrace:readyGrace:)
    static func isTurnEnd(observedWorking: Bool,
                          idle: Bool,
                          elapsed: TimeInterval,
                          tail: String,
                          sentinelGrace: TimeInterval,
                          readyGrace: TimeInterval) -> Bool {
        guard observedWorking else { return false }
        let state = turnState(tail: tail)
        if elapsed >= sentinelGrace, state == .ready, tailContainsEndTurn(tail) {
            return true
        }
        if idle, elapsed >= readyGrace, state == .ready {
            return true
        }
        return false
    }

    /// Pure convergence decision, mirroring the sentinel path of `isTurnEnd`:
    /// approval is only ever the explicit standalone `[[APPROVED]]` line, from
    /// a reviewer that was seen working this turn and has returned to a ready
    /// composer (a working spinner or an interactive gate both mean the turn —
    /// and any lingering token above it — is not a fresh approval). PTY quiet
    /// time is NOT required, for the same keystroke-echo reason.
    @objc(isApprovalObservedWorking:elapsed:tail:grace:)
    static func isApproval(observedWorking: Bool,
                           elapsed: TimeInterval,
                           tail: String,
                           grace: TimeInterval) -> Bool {
        guard observedWorking, elapsed >= grace else { return false }
        guard turnState(tail: tail) == .ready else { return false }
        return tailContainsApproved(tail)
    }

    // Tokens that indicate the agent is actively producing output. In practice
    // the orchestrator only consults the heuristic after the pane has been
    // quiet for a while (an animating spinner keeps resetting the idle timer),
    // so this mainly guards against a spinner frame that happened to be the
    // last thing drawn before a stall.
    private static let workingTokens: [String] = [
        "esc to interrupt", "Esc to interrupt", "ESC to interrupt",
        "Thinking", "Working", "Generating", "Compacting", "Running…",
    ]

    // Braille spinner glyphs used by both CLIs' progress indicators.
    private static let spinnerScalars: Set<Character> = {
        let braille = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷"
        return Set(braille)
    }()

    // Claude Code v2's live progress line: a sparkle glyph, a gerund, and an
    // ellipsis — “✳ Jitterbugging…”, growing counters after a while:
    // “✳ Frolicking… (2m 6s · ↓ 1.3k tokens)”. The parenthesized part is NOT
    // reliable: short turns never grow it (captured live), so only the
    // sparkle + ellipsis shape is required. It shows neither braille spinners
    // nor “esc to interrupt”, so it needs its own matcher. The FINISHED form
    // (“✻ Worked for 9s”) has no ellipsis and must NOT match — the sparkle
    // glyphs alone are useless as a signal because they persist there.
    private static let sparkleProgressRegex = try? NSRegularExpression(
        pattern: "(?m)^\\s*[·✢✳✶✻✽]\\s+\\S[^\\n]*…", options: [])

    private static func looksWorking(_ tail: String) -> Bool {
        if tail.contains(where: { spinnerScalars.contains($0) }) {
            return true
        }
        for token in workingTokens where tail.contains(token) {
            return true
        }
        if let regex = sparkleProgressRegex {
            let range = NSRange(tail.startIndex..., in: tail)
            if regex.firstMatch(in: tail, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Heuristic fallback used when no sentinel is present. Ordering matters:
    /// an active spinner beats everything; a confirmation gate is explicitly
    /// NOT a finished turn; otherwise the pane is treated as an idle composer
    /// ready for the next message.
    @objc(turnStateForTail:)
    static func turnState(tail: String) -> MomentermPairTurnState {
        guard !tail.isEmpty else { return .working }
        if looksWorking(tail) {
            return .working
        }
        // Use the STRICT interactive-gate test, not the advisory attention-bar
        // one: a finished turn commonly ends in a numbered summary, and the
        // advisory detector treats 2+ numbered lines as a menu — which would
        // wedge the relay by masking a ready composer as a confirmation gate.
        if MomentermClaudePromptDetector.isBlockedOnInteractiveGate(tail: tail) {
            return .awaitingConfirmation
        }
        return .ready
    }
}

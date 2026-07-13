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

    private static func looksWorking(_ tail: String) -> Bool {
        if tail.contains(where: { spinnerScalars.contains($0) }) {
            return true
        }
        for token in workingTokens where tail.contains(token) {
            return true
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

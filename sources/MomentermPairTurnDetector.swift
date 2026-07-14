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
//       it blocked on a confirmation gate (NOT a finished turn), is it back at
//       an EXPLICIT ready-for-input composer (a bare `>`/`❯` prompt line or
//       the shortcuts footer — fallback turn end once the screen stabilizes),
//       or is it none of those (.unknown — never a turn end on its own; a
//       novel CLI progress format must not be misread as a finished turn).
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
    case ready                  // 명시적 입력 컴포저 복귀 — 폴백 턴 종료 신호
    case unknown                // 어느 패턴에도 안 걸림 — 폴백 종료 금지
}

/// Per-turn screen tracking for the pairing orchestrator. One instance per
/// pair session; MUST be reset at session start, on every injection, and on
/// every speaker switch — a new turn must never inherit the previous turn's
/// screen-change latch, stability clock, or stall-warning state.
struct MomentermPairTurnScreenTracker {
    /// A meaningful (normalized-signature) screen change was seen this turn.
    private(set) var changedThisTurn = false
    /// The stall warning has already been shown for this turn.
    private(set) var warnedThisTurn = false
    private var lastSignature: String?
    private var lastChangeAt: TimeInterval = 0

    mutating func resetForNewTurn(now: TimeInterval) {
        changedThisTurn = false
        warnedThisTurn = false
        lastSignature = nil
        lastChangeAt = now
    }

    /// Record one tick's normalized screen signature. The first observation
    /// after a reset is the turn's baseline (typically our own just-echoed
    /// injection), NOT a change — only later divergence counts as activity.
    mutating func observe(signature: String, now: TimeInterval) {
        guard signature != lastSignature else { return }
        if lastSignature != nil {
            changedThisTurn = true
        }
        lastSignature = signature
        lastChangeAt = now
    }

    mutating func markWarned() {
        warnedThisTurn = true
    }

    /// How long the normalized screen content has been stable.
    func stableFor(now: TimeInterval) -> TimeInterval {
        return now - lastChangeAt
    }
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
    ///     `sentinelGrace`, judged by screen CONTENT — the pane must not be
    ///     actively engaged (a spinner OR an interactive y/N·permission gate
    ///     both mean the turn is still in flight, so a lingering sentinel
    ///     above them must not count; `.ready` and `.unknown` both pass — a
    ///     fresh sentinel need not come with a recognizable composer). PTY
    ///     quiet time is deliberately NOT required. The user may already be
    ///     typing (or have queued) their next message, and every keystroke
    ///     echo resets the PTY idle clock — an explicit sentinel must still
    ///     hand the turn over.
    ///   • Ready fallback: a turn that omitted the sentinel ends only when a
    ///     meaningful screen change was ALSO observed this turn (so a static
    ///     leftover screen can never end a turn that never produced output),
    ///     an EXPLICIT ready composer is visible (`.ready` — `.unknown`
    ///     never ends a turn, so a novel progress format cannot be misread
    ///     as done), and the normalized screen content has been stable for
    ///     `readyGrace`. PTY idle is deliberately not consulted: the user's
    ///     per-second status line keeps the PTY permanently busy; that
    ///     chrome is excluded from the stability signature instead. A turn
    ///     that never satisfies either path stalls visibly (the orchestrator
    ///     surfaces an advisory) rather than being force-handed-over.
    ///
    /// `elapsed` is time since the turn began (the last injection); the graces
    /// keep our own just-echoed instruction from being read as the reply.
    @objc(isTurnEndObservedWorking:screenChangedThisTurn:contentStableFor:elapsed:tail:sentinelGrace:readyGrace:)
    static func isTurnEnd(observedWorking: Bool,
                          screenChangedThisTurn: Bool,
                          contentStableFor: TimeInterval,
                          elapsed: TimeInterval,
                          tail: String,
                          sentinelGrace: TimeInterval,
                          readyGrace: TimeInterval) -> Bool {
        guard observedWorking else { return false }
        let state = turnState(tail: tail)
        let activelyEngaged = state == .working || state == .awaitingConfirmation
        if elapsed >= sentinelGrace, !activelyEngaged, tailContainsEndTurn(tail) {
            return true
        }
        if screenChangedThisTurn, state == .ready,
           elapsed >= readyGrace, contentStableFor >= readyGrace {
            return true
        }
        return false
    }

    /// Pure convergence decision, mirroring the sentinel path of `isTurnEnd`:
    /// approval is only ever the explicit standalone `[[APPROVED]]` line, from
    /// a reviewer that was seen working this turn and is no longer actively
    /// engaged (a working spinner or an interactive gate both mean the turn —
    /// and any lingering token above it — is not a fresh approval; `.ready`
    /// and `.unknown` both pass, matching the sentinel path). PTY quiet time
    /// is NOT required, for the same keystroke-echo reason.
    @objc(isApprovalObservedWorking:elapsed:tail:grace:)
    static func isApproval(observedWorking: Bool,
                           elapsed: TimeInterval,
                           tail: String,
                           grace: TimeInterval) -> Bool {
        guard observedWorking, elapsed >= grace else { return false }
        let state = turnState(tail: tail)
        let activelyEngaged = state == .working || state == .awaitingConfirmation
        guard !activelyEngaged else { return false }
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

    // Claude Code v2's live progress line: a sparkle glyph, ONE gerund with
    // the ellipsis attached, optional counters after — “✳ Jitterbugging…”,
    // later “✳ Frolicking… (2m 6s · ↓ 1.3k tokens)”. The parenthesized part
    // is NOT reliable: short turns never grow it (captured live), so only the
    // sparkle + word-with-ellipsis shape is required. It shows neither
    // braille spinners nor “esc to interrupt”, so it needs its own matcher.
    // Deliberately strict about false positives, which pin the state at
    // .working and wedge the relay the other way:
    //   • the FINISHED form (“✻ Worked for 9s”) has no ellipsis — no match;
    //   • ‘·’ (middle dot) is excluded even though it is one of the animation
    //     frames — it doubles as a plain list bullet in prose, and losing one
    //     of six frames barely matters when the 1 Hz tick only needs to catch
    //     a single frame per turn;
    //   • the ellipsis must be glued to the first word, so a prose line like
    //     “✻ 파일 로딩… 완료” (word, space, word-with-ellipsis) cannot match.
    private static let sparkleProgressRegex = try? NSRegularExpression(
        pattern: "(?m)^\\s*[✢✳✶✻✽]\\s+\\S+…", options: [])

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
    /// NOT a finished turn; `.ready` requires EXPLICIT composer evidence; and
    /// anything else is `.unknown` — never a turn end on its own, so a novel
    /// CLI progress format we fail to recognize as working cannot be misread
    /// as a finished turn by the fallback.
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
        if looksReadyComposer(tail) {
            return .ready
        }
        return .unknown
    }

    // MARK: - Ready-composer evidence

    // Glyphs tolerated around a bare composer prompt: whitespace plus the TUI
    // box edges both CLIs draw around their input field (`│ > │`).
    private static let composerLineTrim: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.insert(charactersIn: "│┃|┆┇╎╏╭╮╰╯")
        return set
    }()

    /// A line that is nothing but the input prompt — an EMPTY composer waiting
    /// for the next message. A prompt followed by text (queued input, a gate's
    /// `❯ 1. Yes` selection row) is deliberately NOT composer evidence.
    private static func isBareComposerPromptLine(_ line: String) -> Bool {
        let core = line.trimmingCharacters(in: composerLineTrim)
        return core == ">" || core == "❯"
    }

    /// Explicit evidence that the pane is back at a ready-for-input composer:
    /// a bare prompt line, or the composer's own shortcuts footer.
    private static func looksReadyComposer(_ tail: String) -> Bool {
        if tail.contains("? for shortcuts") {
            return true
        }
        return tail.components(separatedBy: "\n").contains(where: isBareComposerPromptLine)
    }

    // MARK: - Stability signature

    // Counters that legitimately repaint every second without meaning new
    // content: wall clocks, elapsed durations, token counts, percentages.
    // Normalizing them (instead of hashing the raw screen) is what lets the
    // stability judgement survive a user status line that updates at 1 Hz.
    private static let volatileCounterRegexes: [NSRegularExpression] = {
        let patterns = [
            "\\b\\d{1,2}:\\d{2}(:\\d{2})?\\b",          // 14:32:05
            "\\b\\d+(\\.\\d+)?[kKmM]?\\s*tokens\\b",    // ↓ 1.3k tokens
            "\\b\\d+(\\.\\d+)?%",                       // 42%
            "\\b\\d+(\\.\\d+)?[hms]\\b",                // 2m 6s / 9s
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Signature of the visible screen used for the no-sentinel stability
    /// judgement. Two screens that differ only in per-second chrome (the
    /// user's status line, elapsed-time/token counters) map to the SAME
    /// signature; any response-body or sentinel change yields a new one.
    /// The user's status line renders below the composer, so everything
    /// under the last bare prompt line is dropped outright; volatile
    /// counters elsewhere are normalized in place, leaving the prose (and
    /// any `[[END_TURN]]`/`[[APPROVED]]` line) intact.
    @objc(stabilitySignatureForTail:)
    static func stabilitySignature(forTail tail: String) -> String {
        var lines = tail.components(separatedBy: "\n")
        if let promptIdx = lines.lastIndex(where: isBareComposerPromptLine) {
            lines = Array(lines[...promptIdx])
        }
        var signature = lines.joined(separator: "\n")
        for regex in volatileCounterRegexes {
            let range = NSRange(signature.startIndex..., in: signature)
            signature = regex.stringByReplacingMatches(in: signature,
                                                       options: [],
                                                       range: range,
                                                       withTemplate: "#")
        }
        return signature
    }
}

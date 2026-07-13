//
//  MomentermPairSession.swift
//  iTerm2
//
//  Orchestrator for the Codex ⇄ Claude pairing feature. Drives a relay between
//  two live CLI panes:
//
//    • editor (claude)   — edits files in the repo to implement the seeded task
//    • reviewer (codex)  — read-only; reviews the editor's git diff and either
//                          approves or returns actionable feedback
//
//  Flow: the user drives the editor (claude) pane directly — they type the
//  task into it, there is no seed sheet. The editor is launched with the turn
//  sentinel instruction folded into its `--append-system-prompt`, so every
//  turn (including the first, user-typed one) ends with a `[[END_TURN]]` line
//  without anything being injected into the input stream ahead of the user.
//  The orchestrator watches for the editor's first task turn to end, computes
//  the editor cwd's `git diff` and hands the *diff file path* to the reviewer
//  → reviewer critiques → orchestrator relays the critique back to the editor
//  → … until the reviewer emits `[[APPROVED]]` or the round cap is hit.
//
//  Turn boundaries never trust a sentinel that merely *exists* in the screen
//  tail — a prior turn's `[[END_TURN]]`/`[[APPROVED]]` can linger there. A turn
//  only ends after the orchestrator has observed the speaker actively working
//  (spinner / “esc to interrupt”) since that turn began, then STOP looking
//  working. That “observed working this turn” latch is what distinguishes a
//  genuine new turn end from a stale sentinel on a briefly-quiet screen.
//  Deliberately, sentinel detection does NOT require PTY quiet time: the user
//  may already be typing (or have queued) their next message into the editor,
//  and each keystroke echo resets the idle clock — that must not stall the
//  handoff. Only the no-sentinel ready-composer fallback requires true idle.
//
//  Two robustness pillars (see MomentermPairTurnDetector):
//    1. git diff as the review payload — never scrape the editor's TUI for the
//       code; read the repo directly. Only the reviewer's prose is scraped.
//    2. a sentinel protocol ([[END_TURN]] / [[APPROVED]]) for turn/convergence
//       boundaries, with an idle+composer heuristic as fallback.
//
//  Injection uses bracketed paste + a delayed carriage return so multi-line
//  messages land in the composer as one block instead of being submitted at
//  the first embedded newline.
//

import AppKit
import Foundation

@objc(MomentermPairRole)
enum MomentermPairRole: Int {
    case editor    // claude
    case reviewer  // codex
}

@objc(MomentermPairOutcome)
enum MomentermPairOutcome: Int {
    case approved         // reviewer emitted [[APPROVED]]
    case roundCapReached  // hit maxRounds without approval
    case stoppedByUser    // user pressed stop
    case sessionDied      // one of the panes exited
}

@objc(MomentermPairSessionDelegate)
protocol MomentermPairSessionDelegate: AnyObject {
    /// The relay has begun and `role` is the first/next speaker. Used to point
    /// the neon direction indicator at the active pane.
    @objc optional func pairSession(_ session: MomentermPairSession,
                                    activeSpeakerDidChange role: MomentermPairRole)
    /// Terminal state reached. Panes are left alive; show a completion banner.
    @objc optional func pairSession(_ session: MomentermPairSession,
                                    didFinishWith outcome: MomentermPairOutcome,
                                    roundCount: Int)
}

@objc(MomentermPairSession)
final class MomentermPairSession: NSObject {

    // MARK: Tunables
    private let idleThreshold: TimeInterval = 1.5   // pane quiet before we judge state
    private let bootGrace: TimeInterval = 4.0       // let the editor CLI draw its composer
    private let sentinelResponseGrace: TimeInterval = 2.0
    private let readyResponseGrace: TimeInterval = 5.0
    private let tickInterval: TimeInterval = 1.0
    private let editorTailLines = 40
    private let reviewerTailLines = 80

    @objc var maxRounds: Int = 12
    @objc private(set) var roundCount: Int = 0
    @objc private(set) var isRunning: Bool = false

    @objc weak var delegate: MomentermPairSessionDelegate?
    @objc private(set) weak var editorSession: PTYSession?
    @objc private(set) weak var reviewerSession: PTYSession?

    // MARK: State
    private enum Phase {
        case awaitingEditorFirstTurn
        case editorTurn
        case reviewerTurn
        case finished
    }
    private var phase: Phase = .awaitingEditorFirstTurn
    /// Set once the editor has settled into a ready composer at least once —
    /// i.e. the CLI finished booting. Only then do we start watching for the
    /// user's task work, so boot-time spinner output isn't mistaken for it.
    private var sawReadyComposer = false
    /// Set when the current speaker has been observed actively working
    /// (spinner / “esc to interrupt”) SINCE the current turn began. Reset on
    /// every turn boundary (each injection, and at session start). A turn is
    /// only allowed to end once this is true — otherwise a prior turn's
    /// sentinel lingering in the screen tail could trigger a premature
    /// transition on a brief quiet moment before the speaker has even started.
    private var observedWorkingThisTurn = false
    /// The editor's screen at the end of its first turn, cleaned and handed to
    /// the reviewer as context (carries the user's typed task + the editor's
    /// plan). Empty if it could not be captured.
    private var capturedTaskContext: String = ""
    private var startTime: TimeInterval = 0
    private var injectionTime: TimeInterval = 0
    private var startCommitSHA: String?
    private var editorCwd: String = ""
    private var scratchDir: URL?
    private var timer: Timer?

    private static let pasteStart = "\u{1b}[200~"
    private static let pasteEnd = "\u{1b}[201~"

    // MARK: - Lifecycle

    @objc func start(editor: PTYSession, reviewer: PTYSession) {
        editorSession = editor
        reviewerSession = reviewer
        isRunning = true
        phase = .awaitingEditorFirstTurn
        sawReadyComposer = false
        observedWorkingThisTurn = false
        startTime = nowRef()
        roundCount = 0

        // Resolve the editor's working directory + baseline commit so every
        // round can diff cumulative changes against the state at pairing start.
        if let cwd = editor.currentLocalWorkingDirectory, !cwd.isEmpty {
            editorCwd = cwd
            let sha = runGit(["rev-parse", "HEAD"], cwd: cwd)
            if sha.status == 0 {
                startCommitSHA = sha.out.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                DLog("MomentermPairSession: editor cwd \(cwd) is not a git repo with a HEAD commit; diffs will be limited")
            }
        } else {
            DLog("MomentermPairSession: could not resolve editor cwd")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MomentermPair-\(editor.guid ?? "session")", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDir = dir

        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // The user types into the editor first, so point the neon direction
        // indicator at it right away.
        delegate?.pairSession?(self, activeSpeakerDidChange: .editor)
    }

    @objc func stop() {
        finish(.stoppedByUser)
    }

    private func finish(_ outcome: MomentermPairOutcome) {
        guard isRunning else { return }
        isRunning = false
        phase = .finished
        timer?.invalidate()
        timer = nil
        DLog("MomentermPairSession finished: outcome=\(outcome.rawValue) rounds=\(roundCount)")
        delegate?.pairSession?(self, didFinishWith: outcome, roundCount: roundCount)
    }

    // MARK: - Poll loop

    private func tick() {
        guard isRunning else { return }
        guard let editor = editorSession, let reviewer = reviewerSession else {
            finish(.sessionDied); return
        }
        if editor.exited || reviewer.exited {
            finish(.sessionDied); return
        }

        switch phase {
        case .awaitingEditorFirstTurn:
            handleAwaitingEditorFirstTurn(editor: editor)
        case .editorTurn:
            handleEditorTurn(editor: editor)
        case .reviewerTurn:
            handleReviewerTurn(reviewer: reviewer)
        case .finished:
            break
        }
    }

    /// The user drives the editor pane directly — there is no seed sheet. We
    /// wait for them to submit a task (the pane leaves its idle composer and
    /// starts working), then treat the return to idle as the end of the
    /// editor's first turn and open the review relay.
    private func handleAwaitingEditorFirstTurn(editor: PTYSession) {
        // Separate boot noise from real task work: only begin watching for the
        // user's task once the composer has settled into a ready state at least
        // once (boot complete). `bootGrace` is a floor for the case where a
        // clean ready frame is never observed (e.g. input queued during boot).
        if !sawReadyComposer {
            if MomentermPairTurnDetector.turnState(tail: tail(editor, editorTailLines)) == .ready {
                sawReadyComposer = true
                DLog("MomentermPairSession: editor composer ready (boot complete)")
            } else if nowRef() - startTime < bootGrace {
                return
            }
        }

        // `turnEnded` requires having observed the editor working since start;
        // until the user submits a task there is nothing to relay.
        noteWorking(editor)
        guard turnEnded(editor, tailLines: editorTailLines) else { return }
        DLog("MomentermPairSession: first editor turn ended → relaying diff to reviewer")
        capturedTaskContext = captureEditorContext(editor)
        relayDiffToReviewer()
    }

    private func handleEditorTurn(editor: PTYSession) {
        noteWorking(editor)
        guard turnEnded(editor, tailLines: editorTailLines) else { return }
        relayDiffToReviewer()
    }

    /// Compute the editor cwd's diff and hand its file path to the reviewer.
    private func relayDiffToReviewer() {
        let diff = currentDiff()
        guard let path = writeDiffFile(diff) else {
            DLog("MomentermPairSession: failed to write diff file; stopping")
            finish(.sessionDied); return
        }
        guard let reviewer = reviewerSession else { finish(.sessionDied); return }
        inject(reviewerPrompt(diffPath: path, diffIsEmpty: diff.isEmpty), into: reviewer)
        enter(.reviewerTurn, speaker: .reviewer)
    }

    private func handleReviewerTurn(reviewer: PTYSession) {
        noteWorking(reviewer)
        let reviewerTail = tail(reviewer, reviewerTailLines)

        // Convergence is ONLY ever the explicit token — never inferred — and
        // never from a stale `[[APPROVED]]` left over from a prior reviewer
        // turn: it only counts once we've seen the reviewer work this turn.
        if MomentermPairTurnDetector.isApproval(
            observedWorking: observedWorkingThisTurn,
            elapsed: nowRef() - injectionTime,
            tail: reviewerTail,
            grace: sentinelResponseGrace) {
            finish(.approved); return
        }

        guard turnEnded(reviewer, tailLines: reviewerTailLines) else { return }

        // Not approved: relay the critique back to the editor (or hit the cap).
        roundCount += 1
        if roundCount > maxRounds {
            finish(.roundCapReached); return
        }
        guard let editor = editorSession else { finish(.sessionDied); return }
        let comments = extractReviewerComments(fromTail: reviewerTail)
        inject(editorFeedbackPrompt(comments: comments), into: editor)
        enter(.editorTurn, speaker: .editor)
    }

    private func enter(_ newPhase: Phase, speaker: MomentermPairRole) {
        phase = newPhase
        delegate?.pairSession?(self, activeSpeakerDidChange: speaker)
    }

    // MARK: - Turn detection

    private func isIdle(_ session: PTYSession) -> Bool {
        let last = session.momentermLastOutputAt
        guard last > 0 else { return false }
        return nowRef() - last >= idleThreshold
    }

    /// Latch that the current speaker has been seen working since this turn
    /// began. Called every tick for the active pane.
    private func noteWorking(_ session: PTYSession) {
        guard !observedWorkingThisTurn else { return }
        if MomentermPairTurnDetector.turnState(tail: tail(session, editorTailLines)) == .working {
            observedWorkingThisTurn = true
            DLog("MomentermPairSession: observed speaker working this turn")
        }
    }

    /// True when the current speaker has finished a turn. The decision itself
    /// lives in a pure, unit-tested function; the key guard is that we must
    /// have observed the speaker working THIS turn, so a prior turn's sentinel
    /// still on screen cannot end a turn that never really started.
    private func turnEnded(_ session: PTYSession, tailLines: Int) -> Bool {
        return MomentermPairTurnDetector.isTurnEnd(
            observedWorking: observedWorkingThisTurn,
            idle: isIdle(session),
            elapsed: nowRef() - injectionTime,
            tail: tail(session, tailLines),
            sentinelGrace: sentinelResponseGrace,
            readyGrace: readyResponseGrace)
    }

    private func tail(_ session: PTYSession, _ lines: Int) -> String {
        return session.momentermScreenTailString(lines)
    }

    private func nowRef() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    // MARK: - git diff

    private func currentDiff() -> String {
        guard !editorCwd.isEmpty else { return "" }
        let args: [String]
        if let sha = startCommitSHA {
            args = ["diff", sha]                // cumulative: committed + uncommitted
        } else {
            args = ["diff"]                      // best effort when no HEAD baseline
        }
        let r = runGit(args, cwd: editorCwd)
        if r.status != 0 {
            DLog("MomentermPairSession: git \(args.joined(separator: " ")) failed (\(r.status))")
        }
        return r.out
    }

    private func writeDiffFile(_ diff: String) -> String? {
        guard let dir = scratchDir else { return nil }
        let url = dir.appendingPathComponent("diff-round-\(roundCount).patch")
        let body = diff.isEmpty ? "(변경 사항이 없습니다)\n" : diff
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            DLog("MomentermPairSession: wrote diff (\(body.count) chars) to \(url.path)")
            return url.path
        } catch {
            return nil
        }
    }

    private func runGit(_ args: [String], cwd: String) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return (-1, "")
        }
        // Read to EOF (child closes pipe on exit) before waiting — safe for the
        // modest sizes a diff produces.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Injection (bracketed paste + delayed submit)

    private func inject(_ text: String, into session: PTYSession) {
        injectionTime = nowRef()
        // A fresh injection starts a new turn for the receiving pane: it must
        // be seen working again before that turn can be considered ended, so a
        // sentinel lingering from the previous turn can't fire immediately.
        observedWorkingThisTurn = false
        session.writeTask(Self.pasteStart + text + Self.pasteEnd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak session] in
            session?.writeTask("\r")
        }
        DLog("MomentermPairSession: injected \(text.count) chars into \(session.guid ?? "?")")
    }

    // MARK: - Prompts (curly quotes per project convention)

    /// Capture the editor pane's screen at the end of its first turn, lightly
    /// cleaned of TUI box glyphs and footer chrome. This is prose (the user's
    /// task + the editor's plan), not code — the code always travels as the
    /// git diff, never scraped from the TUI.
    private func captureEditorContext(_ editor: PTYSession) -> String {
        let cleaned = tail(editor, editorTailLines)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: MomentermPairSession.boxTrim) }
            .filter { !$0.contains("shortcuts") && !$0.contains("esc to interrupt") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private func reviewerPrompt(diffPath: String, diffIsEmpty: Bool) -> String {
        let diffNote = diffIsEmpty
            ? "편집자가 아직 변경한 내용이 없습니다. 다음에 무엇을 구현해야 하는지 구체적으로 안내하세요."
            : "편집자의 현재 변경사항 diff가 다음 경로에 있습니다. 파일을 열어 검토하세요:\n\(diffPath)"
        let contextNote = capturedTaskContext.isEmpty
            ? "편집자에게 주어진 과제 원문은 확보하지 못했습니다. diff 자체에서 의도를 추론해 검토하세요."
            : "다음은 편집자 세션의 최근 화면입니다(사용자 과제와 진행 상황이 담겨 있습니다):\n\(capturedTaskContext)"
        return """
        당신은 두 AI 페어링에서 ‘검토자’(읽기 전용)입니다. 아래 맥락을 기준으로 편집자의 변경을 검토하세요. 충분히 충족하면 마지막에 [[APPROVED]] 를 단독 줄로 출력하고, 그렇지 않으면 구체적이고 실행 가능한 피드백을 준 뒤 마지막에 [[END_TURN]] 을 단독 줄로 출력하세요.

        [맥락]
        \(contextNote)

        \(diffNote)
        """
    }

    private func editorFeedbackPrompt(comments: String) -> String {
        return """
        검토자 피드백입니다:

        \(comments)

        반영해 수정하세요. 매 턴이 끝나면 마지막에 [[END_TURN]] 을 단독 줄로 출력하세요.
        """
    }

    // MARK: - Reviewer comment extraction (heuristic)

    private static let boxTrim = CharacterSet(charactersIn: " \t│┃|┆┇╎╏╭╮╰╯─━┄┅═║╔╗╚╝▏▕>❯•*")

    private func extractReviewerComments(fromTail tail: String) -> String {
        let rawLines = tail.components(separatedBy: "\n")
        // Strip TUI box/prompt glyphs from each line edge.
        var lines = rawLines.map {
            $0.trimmingCharacters(in: MomentermPairSession.boxTrim)
        }

        // Drop everything up to and including the echoed injected prompt: the
        // reviewer's own text begins after the diff-path line we sent it.
        if let pathIdx = lines.lastIndex(where: { $0.contains(".patch") || $0.contains("[과제]") }) {
            lines = Array(lines[(pathIdx + 1)...])
        }

        // Drop the sentinel line and common footer chrome.
        lines = lines.filter { line in
            if line.isEmpty { return true }
            if line.contains(MomentermPairTurnDetector.endTurnToken) { return false }
            if line.contains(MomentermPairTurnDetector.approvedToken) { return false }
            if line.contains("shortcuts") || line.contains("esc to interrupt") { return false }
            return true
        }

        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty {
            // Fallback: hand back the whole cleaned tail minus sentinels.
            return rawLines
                .filter { !$0.contains(MomentermPairTurnDetector.endTurnToken) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joined
    }
}

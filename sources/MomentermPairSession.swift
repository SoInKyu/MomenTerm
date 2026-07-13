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
//  task into it, there is no seed sheet. Because the user's own first message
//  can't carry a turn sentinel, the orchestrator first *primes* the editor
//  with a one-time standing instruction to end every turn with `[[END_TURN]]`,
//  waits for its ack, then watches for the editor's first task turn to end,
//  computes the editor cwd's `git diff` and hands the *diff file path* to the
//  reviewer → reviewer critiques → orchestrator relays the critique back to
//  the editor → … until the reviewer emits `[[APPROVED]]` or the round cap is
//  hit.
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
        case primingEditor            // inject the standing sentinel instruction, await ack
        case awaitingEditorFirstTurn
        case editorTurn
        case reviewerTurn
        case finished
    }
    private var phase: Phase = .primingEditor
    /// Set once the standing `[[END_TURN]]` instruction has been injected into
    /// the editor so the priming turn is only awaited, not re-sent.
    private var primingSent = false
    /// Set once the editor pane leaves its idle composer and starts working —
    /// i.e. the user has submitted the first task. Until then there is nothing
    /// to relay.
    private var editorEngaged = false
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
        phase = .primingEditor
        primingSent = false
        editorEngaged = false
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
        case .primingEditor:
            handlePrimingEditor(editor: editor)
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

    /// Before the user types anything, prime the editor once with a standing
    /// instruction to end every turn with `[[END_TURN]]`. The user can't carry
    /// the sentinel in their own first message, so without this the first real
    /// task turn would fall back to the fragile idle-composer heuristic. We
    /// wait for the editor's composer to be ready (booted), inject the standing
    /// instruction, then await its short ack turn before opening the relay.
    private func handlePrimingEditor(editor: PTYSession) {
        guard nowRef() - startTime >= bootGrace else { return }

        if !primingSent {
            // Only inject once the CLI has drawn its idle composer — injecting
            // into a still-booting pane would drop the message.
            guard MomentermPairTurnDetector.turnState(tail: tail(editor, editorTailLines)) == .ready else { return }
            inject(editorPrimingPrompt(), into: editor)
            primingSent = true
            DLog("MomentermPairSession: primed editor with standing [[END_TURN]] instruction")
            return
        }

        // Await the editor's ack turn. The sentinel makes this reliable; the
        // ready fallback still covers a model that skips it.
        guard turnEnded(editor, tailLines: editorTailLines) else { return }
        DLog("MomentermPairSession: editor acked priming → awaiting user's first task")
        phase = .awaitingEditorFirstTurn
    }

    /// The user drives the editor pane directly — there is no seed sheet. We
    /// wait for them to submit a task (the pane leaves its idle composer and
    /// starts working), then treat the return to idle as the end of the
    /// editor's first turn and open the review relay.
    private func handleAwaitingEditorFirstTurn(editor: PTYSession) {
        guard nowRef() - startTime >= bootGrace else { return }

        if !editorEngaged {
            // Nothing to relay until the user has actually given the editor a
            // task and it has begun working. A `.working` state (spinner /
            // “esc to interrupt”) is the signal — mere keystroke echo would
            // fire the idle heuristic mid-typing.
            if MomentermPairTurnDetector.turnState(tail: tail(editor, editorTailLines)) == .working {
                editorEngaged = true
                DLog("MomentermPairSession: editor engaged (observed .working)")
            }
            return
        }

        guard turnEnded(editor, tailLines: editorTailLines) else { return }
        DLog("MomentermPairSession: first editor turn ended → relaying diff to reviewer")
        capturedTaskContext = captureEditorContext(editor)
        relayDiffToReviewer()
    }

    private func handleEditorTurn(editor: PTYSession) {
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
        let reviewerTail = tail(reviewer, reviewerTailLines)

        // Convergence is ONLY ever the explicit token — never inferred.
        if isIdle(reviewer),
           nowRef() - injectionTime >= sentinelResponseGrace,
           MomentermPairTurnDetector.tailContainsApproved(reviewerTail) {
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

    /// True when the current speaker has finished a turn: an explicit
    /// standalone [[END_TURN]] once idle (primary), or an idle ready-composer
    /// after a response grace (fallback for a forgotten sentinel).
    private func turnEnded(_ session: PTYSession, tailLines: Int) -> Bool {
        guard isIdle(session) else { return false }
        let t = tail(session, tailLines)
        let elapsed = nowRef() - injectionTime
        if elapsed >= sentinelResponseGrace, MomentermPairTurnDetector.tailContainsEndTurn(t) {
            return true
        }
        if elapsed >= readyResponseGrace,
           MomentermPairTurnDetector.turnState(tail: t) == .ready {
            DLog("MomentermPairSession: falling back to ready-composer heuristic for turn end")
            return true
        }
        return false
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

    /// One-time standing instruction injected before the user's first task, so
    /// every editor turn — including that first one, which the user types and
    /// therefore can't carry a sentinel — ends with a detectable `[[END_TURN]]`
    /// line. The token is mentioned mid-sentence here on purpose; the detector
    /// only matches it on a standalone line, so this echoed instruction never
    /// false-triggers a turn end.
    private func editorPrimingPrompt() -> String {
        return """
        지금부터 두 AI ‘페어 리뷰’ 모드로 진행합니다. 당신은 ‘편집자’입니다. 앞으로 당신의 모든 답변은 반드시 마지막 줄에 [[END_TURN]] 을 단독 줄로 출력해 턴의 끝을 표시하세요. 이 안내에는 ‘준비됨’ 한 마디만 답하고 마지막 줄에 [[END_TURN]] 을 출력한 뒤, 다음에 사용자가 입력할 실제 과제를 기다리세요.
        """
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

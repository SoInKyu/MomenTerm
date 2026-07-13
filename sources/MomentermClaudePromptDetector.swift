//
//  MomentermClaudePromptDetector.swift
//  iTerm2
//
//  Heuristic detector for "the foreground CLI tool is waiting on the user".
//  The primary target is Claude Code's confirmation / menu / arrow-selector
//  prompts but the patterns are kept generic enough to match other common
//  interactive CLIs (`(y/N)`, `Press Enter to continue`, numbered menus).
//
//  The strip driven by this detector is purely advisory — false negatives are
//  fine (we just stay quiet) but false positives lie to the user. The catalog
//  therefore stays conservative: matchers anchored to distinctive UI tokens,
//  not generic shell artifacts like `$` or `❯` alone.
//

import Foundation

@objc(MomentermClaudePromptDetector)
final class MomentermClaudePromptDetector: NSObject {

    // Compiled once per process. Each entry must match a distinctive
    // wait-for-input token; generic prompt characters belong elsewhere.
    //
    // The strongest signals are Claude Code's interactive-selector footer
    // tokens ("Enter to select", "Esc to cancel", "↑/↓ to navigate") — they
    // appear under every arrow-driven and numbered menu, contain phrases
    // that don't show up in ordinary shell output, and survive UI revisions
    // better than the menu body itself.
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"\(\s*[yY]\s*/\s*[nN]\s*\)"#,
            #"\[\s*[yY]\s*/\s*[nN]\s*\]"#,
            #"Do you want to"#,
            #"Would\s+you\s+like\s+to"#,
            #"❯\s*\d+\."#,
            #"Press\s+\w+\s+to\s+continue"#,
            #"Enter\s+to\s+select"#,
            #"Esc\s+to\s+cancel"#,
            #"↑/↓\s+to\s+navigate"#,
            // Claude Code plan mode footer + header — distinct from the
            // regular arrow-selector footer above.
            #"shift\s*\+\s*tab\s+to\s+approve"#,
            #"ctrl[\s\-]*g\s+to\s+edit\s+in\s+VS\s+Code"#,
            #"Claude\s+has\s+written\s+up\s+a\s+plan"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // A *single* `1. foo` or `1) foo` line is too weak (markdown lists, vim's
    // `:set` output, ls -l, …) so the numbered-menu signal requires two or
    // more such lines in the tail. Both `.` and `)` separators are accepted
    // because Claude Code uses the dot form while many other CLIs use the
    // paren form.
    private static let numberedMenuLine: NSRegularExpression? = {
        // Accept an optional selection-cursor prefix (`> 1.` / `❯ 1.`) so the
        // currently-highlighted entry is counted along with the rest.
        return try? NSRegularExpression(pattern: #"^\s*[>❯]?\s*\d+[).]\s"#,
                                        options: [.anchorsMatchLines])
    }()

    @objc(isWaitingForUserResponseWithTail:)
    static func isWaitingForUserResponse(tail: String) -> Bool {
        guard !tail.isEmpty else { return false }
        let range = NSRange(tail.startIndex..., in: tail)
        if matchesStrongGate(tail, range: range) {
            return true
        }
        if let menu = numberedMenuLine,
           menu.numberOfMatches(in: tail, options: [], range: range) >= 2 {
            return true
        }
        return false
    }

    /// Strong interactive-gate signals ONLY — the `patterns` catalogue (y/N,
    /// `❯ N.` selector, “Enter to select”, plan-mode footer, …) — deliberately
    /// EXCLUDING the weak “two-or-more numbered lines” heuristic.
    ///
    /// The bare numbered-lines signal is fine for the advisory attention strip
    /// (a numbered summary lighting the strip is a harmless false positive) but
    /// it is wrong for the pairing turn detector, where it is load-bearing: an
    /// agent that ends its turn with a numbered summary (“1. … 2. … 3. …”) is
    /// FINISHED, not sitting on a menu. Treating that as a confirmation gate
    /// wedges the relay — the ready-composer fallback never fires and the turn
    /// never hands off. Turn detection must therefore use this stricter test.
    @objc(isBlockedOnInteractiveGateWithTail:)
    static func isBlockedOnInteractiveGate(tail: String) -> Bool {
        guard !tail.isEmpty else { return false }
        let range = NSRange(tail.startIndex..., in: tail)
        return matchesStrongGate(tail, range: range)
    }

    private static func matchesStrongGate(_ tail: String, range: NSRange) -> Bool {
        for regex in patterns where regex.firstMatch(in: tail, options: [], range: range) != nil {
            return true
        }
        return false
    }
}

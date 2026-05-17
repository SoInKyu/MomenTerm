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
            #"❯\s*\d+\."#,
            #"Press\s+\w+\s+to\s+continue"#,
            #"Enter\s+to\s+select"#,
            #"Esc\s+to\s+cancel"#,
            #"↑/↓\s+to\s+navigate"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // A *single* `1. foo` or `1) foo` line is too weak (markdown lists, vim's
    // `:set` output, ls -l, …) so the numbered-menu signal requires two or
    // more such lines in the tail. Both `.` and `)` separators are accepted
    // because Claude Code uses the dot form while many other CLIs use the
    // paren form.
    private static let numberedMenuLine: NSRegularExpression? = {
        return try? NSRegularExpression(pattern: #"^\s*\d+[).]\s"#,
                                        options: [.anchorsMatchLines])
    }()

    @objc(isWaitingForUserResponseWithTail:)
    static func isWaitingForUserResponse(tail: String) -> Bool {
        guard !tail.isEmpty else { return false }
        let range = NSRange(tail.startIndex..., in: tail)
        for regex in patterns {
            if regex.firstMatch(in: tail, options: [], range: range) != nil {
                return true
            }
        }
        if let menu = numberedMenuLine,
           menu.numberOfMatches(in: tail, options: [], range: range) >= 2 {
            return true
        }
        return false
    }
}

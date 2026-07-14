//
//  MomentermPairRegistry.swift
//  iTerm2
//
//  App-wide registry of Codex ⇄ Claude pair sessions. A pair is created as
//  split panes in one window, but no single PseudoTerminal owns the relay:
//  several pairs can run in one window, and a pane can be dragged into
//  another tab or window mid-relay. Every window consults this registry
//  instead: to find the live pair a session belongs to (⌘W pair-unit close,
//  bottom-strip toggle), to clear finished pairs' completion banners, and to
//  stop relays when a window goes away.
//

import Foundation

@objc(MomentermPairRegistry)
final class MomentermPairRegistry: NSObject {

    @objc static let shared = MomentermPairRegistry()

    private var pairs: [MomentermPairSession] = []
    private var ordinalCounter = 0

    @objc func add(_ pair: MomentermPairSession) {
        pairs.append(pair)
    }

    /// Monotonically increasing pair number, used to pick each pair's accent
    /// color and the ①②③ badge that visually ties its two panes together.
    @objc func nextPairOrdinal() -> Int {
        ordinalCounter += 1
        return ordinalCounter
    }

    /// The live pair (if any) that `session` belongs to. Finished pairs don't
    /// count — their panes are independent again.
    @objc(livePairContaining:)
    func livePair(containing session: PTYSession?) -> MomentermPairSession? {
        guard let session else { return nil }
        return pairs.first {
            $0.isRunning && ($0.editorSession === session || $0.reviewerSession === session)
        }
    }

    /// Drop finished pairs that involve `session`, removing their leftover
    /// completion-banner borders — called when the session hosts a fresh pair
    /// or is about to go away.
    @objc(removeFinishedPairsContaining:)
    func removeFinishedPairs(containing session: PTYSession?) {
        guard let session else { return }
        pairs.removeAll { pair in
            guard !pair.isRunning,
                  pair.editorSession === session || pair.reviewerSession === session else {
                return false
            }
            pair.detachBorders()
            return true
        }
    }

    /// Window teardown: stop every live relay that involves one of `sessions`.
    /// The pair is left in the registry so the surviving partner window keeps
    /// its completion banner; pairs whose sessions are both gone are pruned.
    @objc(stopPairsContainingAnyOf:)
    func stopPairs(containingAnyOf sessions: [PTYSession]) {
        pairs.removeAll { pair in
            if pair.editorSession == nil && pair.reviewerSession == nil {
                pair.detachBorders()
                return true
            }
            let involved = sessions.contains {
                $0 === pair.editorSession || $0 === pair.reviewerSession
            }
            if involved && pair.isRunning {
                pair.stop()
            }
            return false
        }
    }
}

import Foundation

/// Small, nonproduction test entrypoint run by KBHarness in an iOS Simulator.
/// Test input is a fixed, public Zhuyin fixture; never capture real typing data.
enum RimeEventSmoke {
    private struct Trial {
        let id: String
        let keys: String
        let expanded: Bool
        let index: Int
    }

    static func execute() {
        let path = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("rime-event-smoke.json")
        var payload: [String: Any] = [
            "kind": "actual-ios-simulator-librime",
            "engineReady": false,
            "trials": [],
            "note": "Hardcoded, nonsensitive fixture input. A successful build is not Gboard parity."
        ]
        guard let engine = RimeEngineLibrime(), engine.isReady else {
            payload["error"] = "bundled Rime engine did not initialize in simulator"
            persist(payload, to: path)
            return
        }
        payload["engineReady"] = true
        engine.setOption("ascii_mode", false)

        // DaQian ASCII input: su = ㄋㄧ, su3 = ㄋㄧˇ,
        // dl1o = ㄎㄠㄅㄟ, d1 = ㄎㄅ.
        let trials: [Trial] = [
            .init(id: "no-tone-bar", keys: "su", expanded: false, index: 0),
            .init(id: "tone-bar-control", keys: "su3", expanded: false, index: 0),
            .init(id: "no-tone-expanded", keys: "su", expanded: true, index: 0),
            .init(id: "tone-expanded-control", keys: "su3", expanded: true, index: 0),
            .init(id: "no-tone-phrase-bar", keys: "dl1o", expanded: false, index: 0),
            .init(id: "initial-only-bar", keys: "d1", expanded: false, index: 0)
        ]

        var results: [[String: Any]] = []
        for trial in trials {
            engine.clear()
            var typedCommits: [String] = []
            for scalar in trial.keys.utf8 {
                let update = engine.processKey(Int32(scalar))
                if let commit = update.commit, !commit.isEmpty {
                    typedCommits.append(commit)
                }
            }
            let listed = trial.expanded ? engine.allCandidates() : []
            // The candidate page index and expanded absolute index intentionally
            // follow separate paths through RimeEngineLibrime.
            let update = trial.expanded
                ? engine.selectCandidateAbsolute(trial.index)
                : engine.selectCandidate(trial.index)

            let emitted = update.confirmedSelection
            let invariant = emitted == nil ||
                (emitted!.selectedText == update.commit &&
                 emitted!.rawInputBeforeSelection == trial.keys &&
                 (trial.expanded
                     ? emitted!.source == .expandedPanel
                     : emitted!.source == .candidateBar))
            results.append([
                "id": trial.id,
                "keySequence": trial.keys,
                "expanded": trial.expanded,
                "numberListedInExpanded": listed.count,
                "commitDuringTyping": typedCommits,
                "commitAfterSelection": update.commit as Any? ?? NSNull(),
                "confirmedSelection": emitted != nil,
                "confirmedText": emitted?.selectedText as Any? ?? NSNull(),
                "capturedOriginalKeys": emitted?.rawInputBeforeSelection as Any? ?? NSNull(),
                "eventInvariant": invariant
            ])
        }
        payload["trials"] = results
        payload["eventsEmitted"] = results.filter { $0["confirmedSelection"] as? Bool == true }.count
        payload["allEventInvariantsPass"] = results.allSatisfy { $0["eventInvariant"] as? Bool == true }
        persist(payload, to: path)
    }

    private static func persist(_ payload: [String: Any], to path: URL) {
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
        } catch {
            NSLog("RimeEventSmoke could not write result to simulator Documents")
        }
    }
}

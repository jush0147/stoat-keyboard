import Foundation

/// Small, nonproduction test entrypoint run by KBHarness in an iOS Simulator.
/// Test input is a fixed, public Zhuyin fixture; never capture real typing data.
enum RimeEventSmoke {
    private struct Trial {
        let id: String
        let keys: String
        let expanded: Bool
        let index: Int
        let target: String?

        init(id: String, keys: String, expanded: Bool, index: Int, target: String? = nil) {
            self.id = id
            self.keys = keys
            self.expanded = expanded
            self.index = index
            self.target = target
        }
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
            .init(id: "initial-only-bar", keys: "d1", expanded: false, index: 0),
            .init(id: "full-no-tone-phrase-target", keys: "dl1o", expanded: true, index: 0, target: "靠北"),
            .init(id: "initial-only-phrase-target", keys: "d1", expanded: true, index: 0, target: "靠北"),
            .init(id: "first-character-target", keys: "dl", expanded: true, index: 0, target: "靠"),
            .init(id: "second-character-target", keys: "1o", expanded: true, index: 0, target: "北")
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
            // A target can be absent in the first 200 candidates. Do not turn
            // that into an arbitrary other selection and call it learning.
            let targetIndex = trial.target.flatMap { target in
                listed.firstIndex { $0.text == target }
            }
            let canSelect = trial.target == nil || targetIndex != nil
            let update: RimeUpdate? = canSelect
                ? (trial.expanded
                    ? engine.selectCandidateAbsolute(targetIndex ?? trial.index)
                    : engine.selectCandidate(trial.index))
                : nil
            let emitted = update?.confirmedSelection
            let invariant = emitted == nil ||
                (emitted!.selectedText == update?.commit &&
                 emitted!.rawInputBeforeSelection == trial.keys &&
                 (trial.expanded
                     ? emitted!.source == .expandedPanel
                     : emitted!.source == .candidateBar))
            results.append([
                "id": trial.id,
                "keySequence": trial.keys,
                "expanded": trial.expanded,
                "numberListedInExpanded": listed.count,
                "firstCandidateInExpanded": listed.first?.text as Any? ?? NSNull(),
                "target": trial.target as Any? ?? NSNull(),
                "targetRankTop200": targetIndex.map { $0 + 1 } as Any? ?? NSNull(),
                "commitDuringTyping": typedCommits,
                "commitAfterSelection": update?.commit as Any? ?? NSNull(),
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

import Foundation

/// GitHub-only Rime preference experiment with fixed, non-sensitive words.
/// Each phase runs in a different process using the same app user-data directory.
/// This is NOT hooked into the production keyboard or a Gboard experiment.
enum RimeLearningSmoke {
    private static let fullInput = "dl1o"   // ㄎㄠㄅㄟ
    private static let shortInput = "d1"     // ㄎㄅ
    private static let wanted = "靠北"
    private static let checkpoints: Set<Int> = [1, 2, 3, 5, 10, 16, 24]

    static func execute(phase: String) {
        let reportURL = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("rime-learning-\(phase).json")
        var report: [String: Any] = [
            "phase": phase,
            "engine": "actual-ios-simulator-stoat-plustrim",
            "profileUsesAppGroup": RimePaths.usesAppGroup,
            "ready": false,
            "target": wanted,
            "notes": "All test inputs and selections are hardcoded fixtures, not private user text or Gboard behavior."
        ]
        guard ["baseline", "train-full", "after-full", "train-short", "after-both", "clean-control"].contains(phase) else {
            report["error"] = "Unknown phase"
            write(report, to: reportURL)
            return
        }
        guard let engine = RimeEngineLibrime(), engine.isReady else {
            report["error"] = "Real Rime engine failed to initialize"
            write(report, to: reportURL)
            return
        }
        report["ready"] = true
        engine.setOption("ascii_mode", false)

        report["before"] = ranks(engine)
        if phase.hasPrefix("train-") {
            let input = phase == "train-full" ? fullInput : shortInput
            var checkpointsOut: [[String: Any]] = []
            var selections = 0
            var confirmedCommits = 0
            var failures: [String] = []
            for n in 1...24 {
                engine.clear()
                for key in input.utf8 {
                    let update = engine.processKey(Int32(key))
                    if let unsolicited = update.commit, !unsolicited.isEmpty {
                        failures.append("Auto-commit before selection on iteration \(n)")
                    }
                }
                let candidates = engine.allCandidates()
                guard let chosen = candidates.firstIndex(where: { $0.text == wanted }) else {
                    failures.append("Target absent from recorded candidate list at iteration \(n)")
                    break
                }
                selections += 1
                let update = engine.selectCandidateAbsolute(chosen)
                if update.commit == wanted,
                   update.confirmedSelection?.selectedText == wanted,
                   update.confirmedSelection?.rawInputBeforeSelection == input {
                    confirmedCommits += 1
                } else {
                    failures.append("Unverified Rime candidate commit at iteration \(n)")
                    break
                }
                if checkpoints.contains(n) {
                    checkpointsOut.append([
                        "confirmed": confirmedCommits,
                        "rankings": ranks(engine)
                    ])
                }
            }
            report["selectionAttempts"] = selections
            report["confirmedCommits"] = confirmedCommits
            report["checkpointRanks"] = checkpointsOut
            report["failures"] = failures
            // This API asks librime to flush/sync its internal user dictionary.
            // The following process-start check remains the definitive test.
            report["syncSucceeded"] = engine.syncUserData()
        }
        report["after"] = ranks(engine)
        write(report, to: reportURL)
    }

    private static func rank(_ engine: RimeEngineLibrime, keys: String) -> [String: Any] {
        engine.clear()
        var earlyCommits: [String] = []
        for key in keys.utf8 {
            if let text = engine.processKey(Int32(key)).commit, !text.isEmpty {
                earlyCommits.append(text)
            }
        }
        let options = engine.allCandidates()
        let index = options.firstIndex { $0.text == wanted }
        let data: [String: Any] = [
            "input": keys,
            "rankTop200": index.map { $0 + 1 } as Any? ?? NSNull(),
            "first": options.first?.text as Any? ?? NSNull(),
            "candidateCount": options.count,
            "earlyCommits": earlyCommits
        ]
        engine.clear()
        return data
    }

    private static func ranks(_ engine: RimeEngineLibrime) -> [String: Any] {
        ["fullNoTone": rank(engine, keys: fullInput),
         "initialOnly": rank(engine, keys: shortInput)]
    }

    private static func write(_ data: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoded = try JSONSerialization.data(withJSONObject: data,
                                                     options: [.prettyPrinted, .sortedKeys])
            try encoded.write(to: url, options: .atomic)
        } catch {
            NSLog("RimeLearningSmoke could not write fixture report")
        }
    }
}

import Foundation

/// Debug-only, invented Zhuyin fixtures. No host text and no real user input.
enum RimeSegmentProbe {
    static func execute() {
        let path = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("rime-segment-probe.json")
        var output: [String: Any] = ["ready": false, "cases": []]
        guard let engine = RimeEngineLibrime() else { write(output, path); return }
        engine.setOption("ascii_mode", false)
        output["ready"] = true
        func snapshot() -> [String: Any] {
            let e = engine.compositionEvidence()
            return [
                "raw": e.rawInput, "preedit": e.preedit, "preview": e.commitPreview,
                "start": e.selectionStart, "end": e.selectionEnd,
                "cursor": e.cursorPosition,
                "candidatesFirst": Array(engine.allCandidates().prefix(12).map(\.text))
            ]
        }
        for keys in ["dldl", "dl1o", "dldldl"] {
            engine.clear()
            for k in keys.utf8 { _ = engine.processKey(Int32(k)) }
            let before = snapshot()
            let target = "靠"
            let index = engine.allCandidates().firstIndex { $0.text == target }
            var after: [String: Any] = [:]
            var second: [String: Any] = [:]
            var firstCommit: String? = nil
            var secondCommit: String? = nil
            var firstEvent = false
            if let index {
                let u = engine.selectCandidateAbsolute(index)
                firstCommit = u.commit
                firstEvent = u.confirmedSelection != nil
                after = snapshot()
                if let index2 = engine.allCandidates().firstIndex(where: { $0.text == "拷" }) {
                    let u2 = engine.selectCandidateAbsolute(index2)
                    secondCommit = u2.commit
                    second = snapshot()
                }
            }
            var row: [String: Any] = [
                "input": keys, "before": before, "firstTargetIndex": index as Any? ?? NSNull(),
                "firstCommit": firstCommit as Any? ?? NSNull(),
                "firstConfirmedEvent": firstEvent, "afterFirst": after,
                "secondCommit": secondCommit as Any? ?? NSNull(), "afterSecond": second
            ]
            // Suppress aggressive user words tracing outside the fixed fixtures.
            row["fixtureOnly"] = true
            var all = output["cases"] as? [[String: Any]] ?? []
            all.append(row)
            output["cases"] = all
        }
        write(output, path)
    }

    private static func write(_ value: [String: Any], _ path: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path, options: .atomic)
        }
    }
}

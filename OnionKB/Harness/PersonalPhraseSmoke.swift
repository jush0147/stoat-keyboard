import Foundation

/// Two independent Simulator processes prove missing-phrase discovery and
/// durable full/initial lookup using real native Rime candidate selection.
/// Only hardcoded invented example: 靠拷 (ㄎㄠ + ㄎㄠ).
enum PersonalPhraseSmoke {
    private static let word = "靠拷"
    private static let full = "dldl"
    private static let short = "dd"

    static func execute(phase: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("personal-phrase-\(phase).json")
        let store = PersonalPhraseLearning()
        var out: [String: Any] = ["phase": phase, "engineReady": false,
                                  "originalPhraseAbsent": false,
                                  "learned": false, "fullFound": false,
                                  "initialFound": false, "persisted": false]
        guard let engine = RimeEngineLibrime() else { write(out, url); return }
        out["engineReady"] = true
        engine.setOption("ascii_mode", false)
        func rawCandidates(_ keys: String) -> [Candidate] {
            engine.clear()
            for key in keys.utf8 { _ = engine.processKey(Int32(key)) }
            let candidates = engine.allCandidates()
            engine.clear()
            return candidates
        }
        let absent = !rawCandidates(full).contains { $0.text == word } &&
                     !rawCandidates(short).contains { $0.text == word }
        out["originalPhraseAbsent"] = absent
        switch phase {
        case "train":
            store.reset()
            for _ in 0..<2 {
                for character in ["靠", "拷"] {
                    engine.clear()
                    for key in "dl".utf8 { _ = engine.processKey(Int32(key)) }
                    let candidates = engine.allCandidates()
                    guard let index = candidates.firstIndex(where: { $0.text == character }) else {
                        out["missingCharacter"] = character
                        write(out, url)
                        return
                    }
                    let selection = engine.selectCandidateAbsolute(index)
                    guard let event = selection.confirmedSelection, selection.commit == character else {
                        out["selectionFailed"] = character
                        write(out, url)
                        return
                    }
                    store.accept(event, allowed: true)
                }
                _ = store.finishBoundary(allowed: true)
            }
            out["learned"] = store.phrases.contains { $0.text == word }
        case "verify":
            out["persisted"] = store.phrases.contains { $0.text == word }
        case "reset":
            store.reset()
            out["persisted"] = !store.phrases.contains { $0.text == word }
        default:
            out["error"] = "bad phase"
        }
        out["fullFound"] = store.suggestions(for: full).contains { $0.text == word }
        out["initialFound"] = store.suggestions(for: short).contains { $0.text == word }
        out["nativePhraseAbsentAtEnd"] = !rawCandidates(full).contains { $0.text == word }
        write(out, url)
    }

    private static func write(_ report: [String: Any], _ url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

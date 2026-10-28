import Foundation

/// Independent Simulator processes prove missing-phrase discovery and
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
        func recordOneBoundary(allowed: Bool, separator: String? = nil) -> Bool {
            for character in ["靠", "拷"] {
                engine.clear()
                for key in "dl".utf8 { _ = engine.processKey(Int32(key)) }
                guard let index = engine.allCandidates().firstIndex(where: { $0.text == character }) else {
                    out["missingCharacter"] = character
                    return false
                }
                let selection = engine.selectCandidateAbsolute(index)
                guard let event = selection.confirmedSelection, selection.commit == character else {
                    out["selectionFailed"] = character
                    return false
                }
                store.accept(event, allowed: allowed)
            }
            if let separator {
                _ = store.finishAfterSymbol(separator, allowed: allowed)
            } else {
                _ = store.finishBoundary(allowed: allowed)
            }
            return true
        }
        /// One continuous Rime composition, with real partial candidate
        /// selections (mix candidate bar and expanded panel when possible).
        /// No synthetic RimeConfirmedSelection objects are constructed.
        func recordContinuous(_ characters: [String], syllableKeys: [String]? = nil,
                              allowed: Bool = true) -> [RimeConfirmedSelection]? {
            engine.clear()
            let keys = syllableKeys ?? Array(repeating: "dl", count: characters.count)
            guard keys.count == characters.count else { return nil }
            let fullInput = keys.joined()
            for k in fullInput.utf8 { _ = engine.processKey(Int32(k)) }
            var confirmed: [RimeConfirmedSelection] = []
            for (position, character) in characters.enumerated() {
                let all = engine.allCandidates()
                guard let index = all.firstIndex(where: { $0.text == character }) else {
                    out["missingSegment"] = character
                    out["missingSegmentPosition"] = position
                    return nil
                }
                let update = index < 5
                    ? engine.selectCandidate(index)
                    : engine.selectCandidateAbsolute(index)
                if position < characters.count - 1 {
                    guard update.commit == nil && update.confirmedSegments.isEmpty else {
                        out["prematureSegmentCommitPosition"] = position
                        return nil
                    }
                } else {
                    guard update.commit == characters.joined() else {
                        out["finalSegmentCommit"] = update.commit as Any? ?? NSNull()
                        return nil
                    }
                    confirmed = update.confirmedSegments
                }
            }
            guard confirmed.count == characters.count,
                  confirmed.map(\.selectedText) == characters,
                  confirmed.map(\.rawInputBeforeSelection) == keys else {
                out["invalidSegmentCount"] = confirmed.count
                return nil
            }
            for event in confirmed { store.accept(event, allowed: allowed) }
            _ = store.finishBoundary(allowed: allowed)
            return confirmed
        }
        switch phase {
        case "observe-once":
            store.reset()
            out["realSelectionsPass"] = recordOneBoundary(allowed: true)
            out["notLearnedYet"] = store.phrases.isEmpty &&
                store.suggestions(for: full).isEmpty &&
                store.suggestions(for: short).isEmpty
        case "train":
            // First observation was written by a *different* process.
            out["realSelectionsPass"] = recordOneBoundary(allowed: true)
            out["learned"] = store.phrases.contains { $0.text == word }
            let fullNative = rawCandidates(full)
            let fullChoices = PersonalCandidateFusion.merge(
                native: fullNative, personal: store.suggestions(for: full), rawInput: full)
            let shortNative = rawCandidates(short)
            let shortChoices = PersonalCandidateFusion.merge(
                native: shortNative, personal: store.suggestions(for: short), rawInput: short)
            out["fusedFullFirst"] = fullChoices.first?.candidate.text == word &&
                fullChoices.first?.personalInput == full &&
                fullChoices.first?.nativeIndex == nil
            out["fusedInitialFirst"] = shortChoices.first?.candidate.text == word &&
                shortChoices.first?.personalInput == short &&
                shortChoices.first?.nativeIndex == nil
            // Candidate-bar and expanded choices both use this same index
            // mapping. No native candidate is selected by a shifted index.
            out["nativeIndicesPreserved"] = fullNative.indices.allSatisfy { index in
                fullChoices[index + 1].nativeIndex == index &&
                fullChoices[index + 1].candidate.text == fullNative[index].text
            }
        case "verify":
            out["persisted"] = store.phrases.contains { $0.text == word }
            store.confirmPersonal(word, input: short)
            out["confirmedPersonalCandidate"] =
                store.phrases.first(where: { $0.text == word })?.confirmations == 3
            store.penalize(word)
            out["negativeFeedbackApplied"] =
                store.phrases.first(where: { $0.text == word })?.confirmations == 2
        case "privacy":
            // Actual Rime selection events, but the caller has rejected the
            // field: neither confirmed segments nor host text may be learned.
            store.reset()
            out["rejectedFieldSelectionsPass"] = recordOneBoundary(allowed: false)
            out["rejectedFieldNoLearning"] = store.phrases.isEmpty &&
                store.suggestions(for: full).isEmpty
            // Cancellation of a previously verified partial sequence must
            // also remove the evidence of the partial phrase.
            engine.clear()
            for key in "dl".utf8 { _ = engine.processKey(Int32(key)) }
            if let index = engine.allCandidates().firstIndex(where: { $0.text == "靠" }),
               let event = engine.selectCandidateAbsolute(index).confirmedSelection {
                store.accept(event, allowed: true)
                store.cancel()
            }
            engine.clear()
            for key in "dl".utf8 { _ = engine.processKey(Int32(key)) }
            if let index = engine.allCandidates().firstIndex(where: { $0.text == "拷" }),
               let event = engine.selectCandidateAbsolute(index).confirmedSelection {
                store.accept(event, allowed: true)
            }
            _ = store.finishBoundary(allowed: true)
            out["cancellationNoLearning"] = store.phrases.isEmpty
        case "punctuation":
            store.reset()
            let badOne = recordOneBoundary(allowed: true, separator: "1")
            let badTwo = recordOneBoundary(allowed: true, separator: "「」")
            out["nonBoundarySelectionPass"] = badOne && badTwo
            out["nonBoundaryNoLearning"] = store.phrases.isEmpty &&
                store.suggestions(for: short).isEmpty
            let goodOne = recordOneBoundary(allowed: true, separator: "，")
            let goodTwo = recordOneBoundary(allowed: true, separator: "。")
            out["punctuationSelectionPass"] = goodOne && goodTwo
            out["punctuationLearned"] = store.phrases.contains { $0.text == word } &&
                store.suggestions(for: full).contains { $0.text == word } &&
                store.suggestions(for: short).contains { $0.text == word }
            out["punctuationRecognition"] =
                PersonalPhraseLearning.isExplicitPhraseBoundary("。") &&
                PersonalPhraseLearning.isExplicitPhraseBoundary("，") &&
                !PersonalPhraseLearning.isExplicitPhraseBoundary("「」") &&
                !PersonalPhraseLearning.isExplicitPhraseBoundary("1")
        case "segmented":
            store.reset()
            var valid = true
            for _ in 0..<2 {
                engine.clear()
                for k in full.utf8 { _ = engine.processKey(Int32(k)) }
                guard let first = engine.allCandidates().firstIndex(where: { $0.text == "靠" }) else {
                    valid = false; break
                }
                let beforeCommit = engine.selectCandidateAbsolute(first)
                guard beforeCommit.commit == nil, beforeCommit.confirmedSegments.isEmpty,
                      let second = engine.allCandidates().firstIndex(where: { $0.text == "拷" }) else {
                    valid = false; break
                }
                let final = engine.selectCandidateAbsolute(second)
                let segments = final.confirmedSegments
                guard final.commit == word, segments.map(\.selectedText) == ["靠", "拷"],
                      segments.map(\.rawInputBeforeSelection) == ["dl", "dl"] else {
                    valid = false; break
                }
                for event in segments { store.accept(event, allowed: true) }
                _ = store.finishBoundary(allowed: true)
            }
            out["nativeSegmentSelectionsVerified"] = valid
            out["segmentedNewPhraseLearned"] = valid &&
                store.suggestions(for: full).contains(where: { $0.text == word }) &&
                store.suggestions(for: short).contains(where: { $0.text == word })
            out["segmentedTop1"] = PersonalCandidateFusion.merge(
                native: rawCandidates(short), personal: store.suggestions(for: short),
                rawInput: short).first?.candidate.text == word
        case "segmented3":
            store.reset()
            let text = "靠拷烤"
            let first = recordContinuous(["靠", "拷", "烤"])
            let second = recordContinuous(["靠", "拷", "烤"])
            out["threeNativeSegmentsVerified"] = first?.count == 3 && second?.count == 3
            out["threeLearned"] = store.phrases.contains { $0.text == text } &&
                store.suggestions(for: "dldldl").contains { $0.text == text } &&
                store.suggestions(for: "ddd").contains { $0.text == text }
            out["threeInitialTopOne"] = PersonalCandidateFusion.merge(
                native: rawCandidates("ddd"), personal: store.suggestions(for: "ddd"),
                rawInput: "ddd").first?.candidate.text == text
        case "segmented3-restart":
            out["threePersisted"] = store.suggestions(for: "dldldl").contains { $0.text == "靠拷烤" } &&
                store.suggestions(for: "ddd").contains { $0.text == "靠拷烤" }
            store.reset()
        case "segmented4":
            store.reset()
            let text = "靠拷烤考"
            let first = recordContinuous(["靠", "拷", "烤", "考"])
            let second = recordContinuous(["靠", "拷", "烤", "考"])
            out["fourNativeSegmentsVerified"] = first?.count == 4 && second?.count == 4
            out["fourLearned"] = store.phrases.contains { $0.text == text } &&
                store.suggestions(for: "dldldldl").contains { $0.text == text } &&
                store.suggestions(for: "dddd").contains { $0.text == text }
            store.reset()
        case "segmented5":
            store.reset()
            let chars = ["靠", "拷", "烤", "考", "靠"]
            let text = chars.joined()
            out["fiveInitiallyAbsent"] =
                !rawCandidates("dldldldldl").contains { $0.text == text } &&
                !rawCandidates("ddddd").contains { $0.text == text }
            let first = recordContinuous(chars)
            let second = recordContinuous(chars)
            out["fiveNativeSegmentsVerified"] = first?.count == 5 && second?.count == 5
            out["fiveLearned"] = store.suggestions(for: "dldldldldl").contains { $0.text == text } &&
                store.suggestions(for: "ddddd").contains { $0.text == text }
            store.reset()
        case "segmented6":
            store.reset()
            let chars = ["靠", "拷", "烤", "考", "靠", "拷"]
            let text = chars.joined()
            out["sixInitiallyAbsent"] =
                !rawCandidates("dldldldldldl").contains { $0.text == text } &&
                !rawCandidates("dddddd").contains { $0.text == text }
            let first = recordContinuous(chars)
            let second = recordContinuous(chars)
            out["sixNativeSegmentsVerified"] = first?.count == 6 && second?.count == 6
            out["sixLearned"] = store.suggestions(for: "dldldldldldl").contains { $0.text == text } &&
                store.suggestions(for: "dddddd").contains { $0.text == text }
            out["sixTopOne"] = PersonalCandidateFusion.merge(
                native: rawCandidates("dddddd"), personal: store.suggestions(for: "dddddd"),
                rawInput: "dddddd").first?.candidate.text == text
            store.reset()
        case "segmented-mixed":
            store.reset()
            // The original three-character fixture 靠北拷 was already a Rime
            // candidate. This deliberately less natural four-character
            // fixture must be absent BEFORE claiming new-word learning.
            let chars = ["拷", "北", "烤", "靠"]
            let keys = ["dl", "1o", "dl", "dl"]
            let text = chars.joined()
            let fullKeys = keys.joined()
            let shortKeys = "d1dd"
            out["mixedInitiallyAbsent"] =
                !rawCandidates(fullKeys).contains { $0.text == text } &&
                !rawCandidates(shortKeys).contains { $0.text == text }
            let first = recordContinuous(chars, syllableKeys: keys)
            let second = recordContinuous(chars, syllableKeys: keys)
            out["mixedPhoneticsVerified"] = first?.map(\.rawInputBeforeSelection) == keys &&
                                            second?.map(\.rawInputBeforeSelection) == keys
            out["mixedLearned"] = store.suggestions(for: fullKeys).contains { $0.text == text } &&
                store.suggestions(for: shortKeys).contains { $0.text == text }
            store.reset()
        case "segmented3-interrupt":
            store.reset()
            engine.clear()
            for k in "dldldl".utf8 { _ = engine.processKey(Int32(k)) }
            var uncommitted = false
            if let index = engine.allCandidates().firstIndex(where: { $0.text == "靠" }) {
                let update = engine.selectCandidateAbsolute(index)
                uncommitted = update.commit == nil && update.confirmedSegments.isEmpty
            }
            // Any intervening key must destroy the tentative chain. A fresh
            // composition's final selection must not replay the earlier one.
            _ = engine.processKey(Int32(BopomoLayout.keyBackspace))
            engine.clear()
            for k in "dldl".utf8 { _ = engine.processKey(Int32(k)) }
            let firstNew = engine.allCandidates().firstIndex(where: { $0.text == "靠" })
            var stale = false
            if let index = firstNew {
                let update = engine.selectCandidateAbsolute(index)
                stale = !update.confirmedSegments.isEmpty
            }
            out["partialEditDiscarded"] = uncommitted && !stale && store.phrases.isEmpty
        case "segment-cancel":
            store.reset()
            engine.clear()
            for k in full.utf8 { _ = engine.processKey(Int32(k)) }
            var premature = false
            if let first = engine.allCandidates().firstIndex(where: { $0.text == "靠" }) {
                let partial = engine.selectCandidateAbsolute(first)
                premature = !partial.confirmedSegments.isEmpty
            }
            engine.clear()
            for k in "dl".utf8 { _ = engine.processKey(Int32(k)) }
            let single: RimeUpdate? = engine.allCandidates()
                .firstIndex(where: { $0.text == "拷" })
                .map { engine.selectCandidateAbsolute($0) }
            out["discardedPartialNotReplayed"] = !premature &&
                single?.confirmedSegments.isEmpty == true &&
                store.phrases.isEmpty
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

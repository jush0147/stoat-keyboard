import Foundation

/// 真 librime 引擎（SPEC §15.3 / §17.6）。
/// `prebuilt_data_dir` 指向 bundle 內預編譯 `.bin`（§5.8）→ 免裝置部署。
final class RimeEngineLibrime: RimeEngine {
    private let bridge: RimeBridge

    var isReady: Bool { bridge.isReady() }

    /// 失敗（找不到 RimeData / 初始化失敗）回 nil → 呼叫端降級 stub。
    init?() {
        guard let shared = RimePaths.sharedDir, let prebuilt = RimePaths.prebuiltDir else {
            return nil
        }
        bridge = RimeBridge(sharedDir: shared, userDir: RimePaths.userDir, prebuiltDir: prebuilt)
        guard bridge.isReady() else { return nil }
    }

    /// Selection evidence for one uninterrupted, explicitly selected Rime
    /// composition. A selection is tentative until Rime's final native commit
    /// exactly matches the entire selected sequence (2...6 single Han chars).
    /// Every phonetic syllable is read from Rime's spaced preedit, and must
    /// reverse-map to the original DaQian keys without guessing.
    private struct TentativeChain {
        let originalRaw: String
        let syllables: [String]
        let keys: [String]
        var selections: [RimeConfirmedSelection]

        var chosenText: String { selections.map(\.selectedText).joined() }
        var remainingPreedit: String {
            syllables.dropFirst(selections.count).joined(separator: " ")
        }
        var expectedPreedit: String { chosenText + remainingPreedit }
    }
    private var tentativeChain: TentativeChain?

    func processKey(_ keycode: Int32) -> RimeUpdate {
        // A new key may edit, extend, delete or finalize the old composition.
        // Never reuse previously selected segments after an intervening key.
        tentativeChain = nil
        bridge.processKey(keycode)
        return snapshot()
    }

    func selectCandidate(_ index: Int) -> RimeUpdate {
        let options = bridge.candidates()
        let selected = options.indices.contains(index) ? options[index].text : nil
        return verifiedSelection(selected: selected, source: .candidateBar) {
            bridge.selectCandidate(Int32(index))
        }
    }

    func allCandidates() -> [Candidate] {
        bridge.allCandidates().map { Candidate(text: $0.text, comment: $0.comment) }
    }

    func selectCandidateAbsolute(_ index: Int) -> RimeUpdate {
        let options = bridge.allCandidates()
        let selected = options.indices.contains(index) ? options[index].text : nil
        return verifiedSelection(selected: selected, source: .expandedPanel) {
            bridge.selectCandidateAbsolute(Int32(index))
        }
    }

    private func verifiedSelection(
        selected: String?, source: RimeConfirmedSelection.Source,
        perform: () -> Bool
    ) -> RimeUpdate {
        let before = bridge.compositionEvidence()
        let succeeded = perform()
        let after = bridge.compositionEvidence()
        var update = snapshot()
        guard succeeded, let selected, Self.oneHan(selected),
              !before.rawInput.isEmpty else {
            tentativeChain = nil
            return update
        }

        let selectedEvent: (String) -> RimeConfirmedSelection = { keys in
            RimeConfirmedSelection(source: source, selectedText: selected,
                                   rawInputBeforeSelection: keys)
        }

        if var chain = tentativeChain {
            // Before attempting to append, invalidate all chains on
            // composition edits, unexpected selection offsets or text.
            tentativeChain = nil
            guard before.rawInput == chain.originalRaw,
                  before.selectionStart == chain.chosenText.utf8.count,
                  before.preedit == chain.expectedPreedit,
                  chain.selections.count < chain.syllables.count else {
                return update
            }
            chain.selections.append(selectedEvent(chain.keys[chain.selections.count]))
            let prefix = chain.chosenText
            guard after.selectionStart == prefix.utf8.count else { return update }
            if chain.selections.count == chain.syllables.count {
                // No learning unless Rime itself actually committed this text.
                if update.commit == prefix, after.rawInput.isEmpty {
                    update.confirmedSegments = chain.selections
                }
            } else if update.commit == nil,
                      after.rawInput == chain.originalRaw,
                      after.preedit == chain.expectedPreedit,
                      after.commitPreview.hasPrefix(prefix) {
                tentativeChain = chain
            }
            return update
        }

        // Existing independent single-character commit behavior remains
        // unchanged, including the native Rime user dictionary.
        if let committed = update.commit, committed == selected {
            update.confirmedSelection = selectedEvent(before.rawInput)
            return update
        }

        // Accept only full, spaced Rime Zhuyin syllables, not abbreviated
        // input or arbitrary phonetic splitting. No host-context inspection.
        guard update.commit == nil,
              before.selectionStart == 0,
              after.selectionStart == selected.utf8.count,
              after.rawInput == before.rawInput,
              after.commitPreview.hasPrefix(selected) else { return update }
        let syllables = before.preedit.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard (2...6).contains(syllables.count) else { return update }
        let resolved = syllables.map(Self.keys(forBopomoSyllable:))
        guard resolved.allSatisfy({ $0 != nil }) else { return update }
        let keys = resolved.compactMap { $0 }
        guard keys.joined() == before.rawInput else { return update }
        var chain = TentativeChain(originalRaw: before.rawInput,
                                   syllables: syllables, keys: keys,
                                   selections: [selectedEvent(keys[0])])
        guard after.preedit == chain.expectedPreedit else { return update }
        tentativeChain = chain
        return update
    }

    private static func oneHan(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1,
              let value = text.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
    }

    private static let symbolToKey: [String: String] = {
        var result: [String: String] = [:]
        for row in BopomoLayout.rows {
            for key in row { result[key.symbol] = String(key.char) }
        }
        return result
    }()

    private static func keys(forBopomoSyllable text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var result = ""
        for symbol in text {
            guard let key = symbolToKey[String(symbol)] else { return nil }
            result += key
        }
        return PersonalPhraseLearning.isFullSyllable(result) ? result : nil
    }

    /// Test-only explicit flush before comparing a fresh process.
    func syncUserData() -> Bool { bridge.syncUserData() }

    func currentRawInput() -> String { bridge.rawInput() }

    // Ephemeral observation only; not evidence of per-character readings.
    func compositionEvidence() -> RimeCompositionEvidence { bridge.compositionEvidence() }

    func clear() { tentativeChain = nil; bridge.clear() }
    func setOption(_ name: String, _ value: Bool) {
        tentativeChain = nil
        bridge.setOption(name, value: value)
    }
    func getOption(_ name: String) -> Bool { bridge.getOption(name) }

    /// 讀取順序：先取 commit（按鍵可能已上字），再取 preedit/候選。
    private func snapshot() -> RimeUpdate {
        let commit = bridge.takeCommit()
        let cands = bridge.candidates().map { Candidate(text: $0.text, comment: $0.comment) }
        // 自繪 preedit：由 raw 大千輸入轉注音，與高亮候選無關 → 翻頁不會「反解成原始碼」（§32 #1）
        let preedit = BopomoLayout.bopomoPreedit(fromInput: bridge.rawInput())
        return RimeUpdate(preedit: preedit, candidates: cands, commit: commit)
    }
}

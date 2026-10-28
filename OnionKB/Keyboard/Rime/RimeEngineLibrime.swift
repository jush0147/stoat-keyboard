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

    /// This is intentionally only a *two single-character* split, not an
    /// arbitrary segment decoder. The prefix is tentative until the native
    /// final commit matches exactly. Any further typing invalidates the chain.
    private struct TentativeSegment {
        let first: RimeConfirmedSelection
        let originalRaw: String
        let remainingPreedit: String
        let remainingKeys: String
    }
    private var tentativeSegment: TentativeSegment?

    func processKey(_ keycode: Int32) -> RimeUpdate {
        tentativeSegment = nil
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
        guard succeeded, let selected, !selected.isEmpty, !before.rawInput.isEmpty else {
            tentativeSegment = nil
            return update
        }

        if let prior = tentativeSegment {
            tentativeSegment = nil
            if Self.oneHan(selected),
               before.rawInput == prior.originalRaw,
               before.preedit == prior.first.selectedText + prior.remainingPreedit,
               let committed = update.commit,
               committed == prior.first.selectedText + selected,
               after.rawInput.isEmpty {
                update.confirmedSegments = [
                    prior.first,
                    RimeConfirmedSelection(source: source, selectedText: selected,
                                           rawInputBeforeSelection: prior.remainingKeys)
                ]
            }
            return update
        }

        // Preserve the existing proven full-candidate event contract.
        if let committed = update.commit, committed == selected {
            update.confirmedSelection = RimeConfirmedSelection(
                source: source, selectedText: selected,
                rawInputBeforeSelection: before.rawInput)
            return update
        }

        // Strictly require Rime's *actual* two spaced phonetic syllables.
        // We do not split initial-only shorthand, unspaced guesses, or
        // ambiguous multi-syllable candidates ourselves.
        guard update.commit == nil, Self.oneHan(selected),
              before.selectionStart == 0,
              after.selectionStart == selected.utf8.count,
              after.rawInput == before.rawInput,
              after.commitPreview.hasPrefix(selected) else { return update }
        let tokens = before.preedit.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 2,
              let firstKeys = Self.keys(forBopomoSyllable: String(tokens[0])),
              let secondKeys = Self.keys(forBopomoSyllable: String(tokens[1])),
              firstKeys + secondKeys == before.rawInput,
              after.preedit == selected + String(tokens[1]) else { return update }
        tentativeSegment = TentativeSegment(
            first: RimeConfirmedSelection(source: source, selectedText: selected,
                                          rawInputBeforeSelection: firstKeys),
            originalRaw: before.rawInput, remainingPreedit: String(tokens[1]),
            remainingKeys: secondKeys)
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

    func clear() { tentativeSegment = nil; bridge.clear() }
    func setOption(_ name: String, _ value: Bool) {
        tentativeSegment = nil
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

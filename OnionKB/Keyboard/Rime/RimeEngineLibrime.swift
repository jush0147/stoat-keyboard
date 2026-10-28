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

    func processKey(_ keycode: Int32) -> RimeUpdate {
        bridge.processKey(keycode)
        return snapshot()
    }

    func selectCandidate(_ index: Int) -> RimeUpdate {
        // Snapshot BEFORE Rime mutates the composition. A selection may be
        // partial or only change the active candidate; do not call it a commit
        // until the actual result can be compared with the selected text.
        let current = bridge.candidates()
        let selected = current.indices.contains(index) ? current[index].text : nil
        let raw = bridge.rawInput()
        let succeeded = bridge.selectCandidate(Int32(index))
        var update = snapshot()
        if succeeded, let selected, !selected.isEmpty,
           let committed = update.commit, committed == selected, !raw.isEmpty {
            update.confirmedSelection = RimeConfirmedSelection(
                source: .candidateBar, selectedText: selected,
                rawInputBeforeSelection: raw)
        }
        return update
    }

    func allCandidates() -> [Candidate] {
        bridge.allCandidates().map { Candidate(text: $0.text, comment: $0.comment) }
    }

    func selectCandidateAbsolute(_ index: Int) -> RimeUpdate {
        // Expanded candidates use absolute indices, NOT the current page.
        let options = bridge.allCandidates()
        let selected = options.indices.contains(index) ? options[index].text : nil
        let raw = bridge.rawInput()
        let succeeded = bridge.selectCandidateAbsolute(Int32(index))
        var update = snapshot()
        if succeeded, let selected, !selected.isEmpty,
           let committed = update.commit, committed == selected, !raw.isEmpty {
            update.confirmedSelection = RimeConfirmedSelection(
                source: .expandedPanel, selectedText: selected,
                rawInputBeforeSelection: raw)
        }
        return update
    }

    /// Test-only explicit flush before comparing a fresh process.
    func syncUserData() -> Bool { bridge.syncUserData() }

    func currentRawInput() -> String { bridge.rawInput() }

    func clear() { bridge.clear() }
    func setOption(_ name: String, _ value: Bool) { bridge.setOption(name, value: value) }
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

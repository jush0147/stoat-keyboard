import Foundation

/// 候選形狀（SPEC §15.1 引擎↔UI 接縫契約）。
struct Candidate {
    let text: String
    let comment: String?
}

/// 成功確認候選的最小事件。只在當次選字成功且 Rime 的 commit
/// 完全等於選中候選時產生。rawInput 只供同一次處理期間判斷輸入來源；
/// 不代表已經取得逐字完整注音，更不能直接拿來訓練個人詞庫。
struct RimeConfirmedSelection {
    enum Source { case candidateBar, expandedPanel }
    let source: Source
    let selectedText: String
    let rawInputBeforeSelection: String
}

/// 一次按鍵/選字後的引擎狀態快照。
struct RimeUpdate {
    var preedit: String           // 組字串（注音）；顯示於鍵盤內（§3.5）
    var candidates: [Candidate]
    var commit: String?           // 若產生上字文字
    var confirmedSelection: RimeConfirmedSelection? = nil
}

/// 引擎協定——UI 只依賴此抽象。實作：`RimeEngineLibrime`（真）/`RimeEngineStub`（後備）。
protocol RimeEngine: AnyObject {
    var isReady: Bool { get }
    func processKey(_ keycode: Int32) -> RimeUpdate
    func selectCandidate(_ index: Int) -> RimeUpdate
    func allCandidates() -> [Candidate]                       // 全候選（展開面板，§89）
    func selectCandidateAbsolute(_ index: Int) -> RimeUpdate  // 絕對索引選字（展開面板，§89）
    func clear()
    func setOption(_ name: String, _ value: Bool)
    func getOption(_ name: String) -> Bool
}


/// 後備 stub：librime 初始化失敗時用，避免鍵盤全黑（僅顯示提示）。
final class RimeEngineStub: RimeEngine {
    private var buffer = ""
    var isReady: Bool { true }

    func processKey(_ keycode: Int32) -> RimeUpdate {
        if keycode == 0xff08 {                 // backspace
            if !buffer.isEmpty { buffer.removeLast() }
        } else if let scalar = Unicode.Scalar(UInt32(max(0, keycode))), keycode < 128 {
            buffer.unicodeScalars.append(scalar)
        }
        return RimeUpdate(preedit: buffer,
                          candidates: buffer.isEmpty ? [] : [Candidate(text: "（無引擎）", comment: nil)],
                          commit: nil)
    }
    func selectCandidate(_ index: Int) -> RimeUpdate {
        let t = buffer; buffer = ""
        return RimeUpdate(preedit: "", candidates: [], commit: t)
    }
    func allCandidates() -> [Candidate] {
        buffer.isEmpty ? [] : [Candidate(text: "（無引擎）", comment: nil)]
    }
    func selectCandidateAbsolute(_ index: Int) -> RimeUpdate {
        let t = buffer; buffer = ""
        return RimeUpdate(preedit: "", candidates: [], commit: t)
    }
    func clear() { buffer = "" }
    func setOption(_ name: String, _ value: Bool) {}
    func getOption(_ name: String) -> Bool { false }
}

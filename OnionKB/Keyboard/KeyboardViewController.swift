import UIKit

/// 閉包式 swipe 手勢（上下划輸入英文，§28 #2）。
final class ClosureSwipe: UISwipeGestureRecognizer {
    private let handler: () -> Void
    init(direction: UISwipeGestureRecognizer.Direction, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        self.direction = direction
        delaysTouchesEnded = false   // tap 立即生效、不等 swipe 判失敗（§112 修卡頓/按不準）
        addTarget(self, action: #selector(fire))
    }
    @objc private func fire() { handler() }
}

/// 按鍵：覆寫 isHighlighted 做原廠按壓高亮（按下即時、放開快速淡出，§57）。
/// `pressedColor == nil` → 不手動高亮（交給 iOS 26 glass 互動動畫或系統）。
final class KeyButton: UIButton {
    var restingColor: UIColor? = KBColor.contentKey
    // 淺：白鍵壓暗 systemGray4；深：systemGray2 鍵壓亮 systemGray（深色按壓回饋，§144）
    var pressedColor: UIColor? = UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemGray.resolvedColor(with: $0) : UIColor.systemGray4.resolvedColor(with: $0) }
    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted, let pressed = pressedColor else { return }
            if isHighlighted {
                backgroundColor = pressed                                   // 原廠：按下即時高亮
            } else {
                UIView.animate(withDuration: 0.12) { self.backgroundColor = self.restingColor }
            }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // §152 設 shadowPath 免離屏渲染：30+ 鍵的陰影無 path 時每次 composite/捲動/打字都重算 → 卡。
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        }
    }
}

/// §164 可重用候選鈕：避免每鍵 `UIButton(type:.system)` 配置（打字卡頓主因之一）。
/// 單一 action 呼叫 onTap 閉包、reuse 時只更新閉包 → 不累積 action、不重配置。
final class CandButton: UIButton {
    var onTap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        setTitleColor(.label, for: .normal)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 原廠色盤（§99）：動態色，依 traitCollection 深淺自動解析，鍵盤隨系統深色模式切換。
enum KBColor {
    private static func dyn(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    /// 鍵盤底（原廠 iOS 26 精確量測，§102）：淺 #E2E4E8 / 深 #171717
    static let panel = dyn(UIColor(red: 226/255, green: 228/255, blue: 232/255, alpha: 1),
                           UIColor(red: 23/255, green: 23/255, blue: 23/255, alpha: 1))
    /// §146 iOS 18 扁平實色鍵盤底＝SDK 官方語意色（非手寫 hex）：淺 systemGray4(#D1D1D6) / 深 systemGray5(#2C2C2E)
    static let flatBg = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor.systemGray5.resolvedColor(with: tc)
            : UIColor.systemGray4.resolvedColor(with: tc)
    }
    /// 內容鍵：淺＝白；深＝systemGray3(#48484A)（§171 對標原廠深色鍵面 ~#404040，比 §144 systemGray2 深一階）
    static let contentKey = UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemGray3.resolvedColor(with: $0) : .white }
    /// 功能鍵：淺＝systemGray2(#AEAEB2)；深＝systemGray4(#3A3A3C)（§171 深一階，較內容鍵深、貼原廠）
    static let funcKey = UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemGray4.resolvedColor(with: $0) : UIColor.systemGray2.resolvedColor(with: $0) }
    /// 功能鍵按下：淺＝systemGray4(白鍵壓暗)；深＝systemGray2(暗鍵壓亮，§144)
    static let funcKeyPressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemGray2.resolvedColor(with: $0) : UIColor.systemGray4.resolvedColor(with: $0) }
    /// §148 首選高亮 pill（原廠選中候選白圓角底）：淺＝白；深＝systemGray3(#48484A 微亮於深底，可見不刺眼)
    static let candHighlight = UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemGray3.resolvedColor(with: $0) : .white }
}

/// 注音鍵盤主控制器（SPEC §7.2 / §15.3 / §24 / §27）。
/// 真 librime 驅動：大千鍵 → keycode → librime → 組字/候選/上字。
/// 選項（半全/標點/簡繁）移到容器 App 設定（§27 #1）；中/英為功能列快切鍵。
final class KeyboardViewController: UIInputViewController {

    private lazy var engine: RimeEngine = RimeEngineLibrime() ?? RimeEngineStub()

    private var preeditText = " "                                  // §155 isPreeditEmpty 狀態來源
    private let compositionLabel = UILabel()                       // §173 非內嵌模式：注音 preedit 顯在候選列左側
    private let compositionSeparator = UIView()                    // §176 注音淡化分區：preedit 與候選間細直線
    private weak var compositionSepWrapRef: UIView?                 // §176 分隔線外層（隨 preedit 顯隱）
    private var optionsMenu: UIMenu?                       // §168 ⚙ 設定選單（長按 123/返回鍵叫出，原廠乾淨佈局）
    private var funcOptionsButtons: [UIButton] = []        // §168 掛 ⚙ 長按選單的鍵（123/返回）：重建刷新、設定變更同步選單
    private let candidateBar = UIScrollView()
    private let candidateStack = UIStackView()
    private weak var candidateRowRef: UIStackView?   // 非注音模式隱藏（§80）
    private var currentCandidates: [Candidate] = []
    private lazy var personalLearning = PersonalPhraseLearning()
    private var personalCandidateInputs: [Int: String] = [:]
    private var lastPersonalCommit: String?
    private var lastPersonalCommitAt: Date = .distantPast
    private var learningDocumentID: UUID?
    private var bopomoKeys: [(key: BopomoLayout.Key, main: UIButton, eng: UILabel)] = []
    private var cnEnButton: UIButton?                                // 中/英 快切鍵
    private var shiftButton: UIButton?                              // ⇧ 英文 shift 實鍵（buildEnglishRows 指派；updateModeStyling/refreshEnglishCase 用）
    private weak var returnButton: UIButton?                         // return 鍵（依 hasText 切灰↔藍，§109）
    private struct ReturnState: Equatable { let disabled: Bool; let action: Bool; let type: UIReturnKeyType }
    private var lastReturnState: ReturnState?                        // §157 return 鍵狀態快取（無變化跳過重設，省每鍵 layout）
    private var heightConstraint: NSLayoutConstraint?
    private var kaomojiPanel: KaomojiPanel?                         // 顏文字面板（§36 #3）
    private var keyRowsStack: UIStackView!                          // 鍵列容器（模式切換，§44/§46）
    private var rootStack: UIStackView!                            // topBar + keyRowsStack（展開面板需插入，§89）
    private var rootTopConstraint: NSLayoutConstraint?             // §153 rootStack 頂部約束（候選列隱藏時加大頂部留白，免上緣裁切）
    private let expandButton = UIButton(type: .system)             // 候選展開/收合 chevron（§89）
    private var expandedPanel: UIScrollView?                       // 展開候選格面板（§89）
    private var isExpanded = false
    private let kbBackdrop = UIInputView(frame: .zero, inputViewStyle: .keyboard)   // 官方系統鍵盤底材（§105 native 方式）
    /// §146 建置變體旗標：true＝iOS 18 扁平實色版（實心底，非半透材質），出 ios18 IPA 時翻 true。
    static let flatStyleIOS18 = false
    // 真 Liquid Glass 層（§97，官方 UIGlassContainerEffect 容器 + 巢狀 glass）
    private var glassContainer: UIVisualEffectView?
    private var glassKeyButtons: [(button: UIButton, prominent: Bool)] = []   // 本輪 rebuild 登記的玻璃鍵
    private var glassPairs: [(button: UIButton, glass: UIVisualEffectView)] = []
    private enum KBMode { case bopomo, english, numbers }
    private var mode: KBMode = .bopomo
    private var lastLetterMode: KBMode = .bopomo                   // 123 返回的字母模式（注音/英文）
    private var hasMarkedText = false                              // §151 是否有 active marked 組字（discard 用，避免 commit 後誤清宿主字）
    private var markedLen = 0                                      // §151 目前 marked 注音字數（discard 用 deleteBackward 精準刪）

    // 空白鍵長按滑動移游標（§39）
    private var spaceCursorLastX: CGFloat = 0
    private var spaceCursorAccum: CGFloat = 0
    private let cursorStep: CGFloat = 9

    private enum ShiftState { case off, shifted, capsLock }
    private var shiftState: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    private var lastSpaceInsert = Date.distantPast                  // §154 雙擊空格→句點偵測
    private var englishMode: Bool { engine.getOption(SchemaOption.asciiMode.rawValue) }
    private var typeUppercase: Bool { shiftState != .off }

    private var fontScale: CGFloat { KBSettings.keyFontScale }       // 按鍵字體縮放（§27 #3）

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        if Self.flatStyleIOS18 {                                    // §146 iOS18 扁平實色版：實心底，不用 UIInputView 半透材質
            view.backgroundColor = KBColor.flatBg
        } else {
            view.backgroundColor = .clear                           // 底改由系統鍵盤底材提供（§105 native 方式）
            kbBackdrop.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(kbBackdrop)                             // 系統鍵盤底材：同原廠材質、自動深淺/半透、填滿整框
            NSLayoutConstraint.activate([
                kbBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                kbBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                kbBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
                kbBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        if isOS26 {                                                  // §146 上緣圓角＝iOS 26 系統需要的圓角 → 以系統為優先（iOS18 變體也保留，僅「鍵」改 iOS18 風格）
            view.layer.cornerRadius = 26                             // 原廠量測 ~26pt 視覺（§102）
            view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            view.layer.cornerCurve = .continuous
            view.layer.masksToBounds = true
        }
        buildUI()
        applyOptionDefaults()   // 套用容器 App 設定的選項預設（§27 #1）
        if #available(iOS 17.0, *) {   // trait 變更（深淺）即重套外觀，避免切 App 殘留白底（§111）
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _) in
                vc.applyKeyboardAppearance()
                vc.styleReturnKey()
                if #available(iOS 26.0, *), vc.useGlassKeys { vc.buildGlassLayer() }   // §143 深淺切換重建玻璃→ tint 跟著換
            }
        }
        // App 回前景：viewWillAppear/viewIsAppearing 在 suspend→resume 不會 fire（§118 缺口、研究 §124 Q4 證實）；
        // 掛前景通知，在轉場「完成後」乾淨重套高度（非動畫），吃掉系統 snapshot→live 還原殘留的偶發彈跳。
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appWillEnterForeground() {
        // 轉場後校正：壓系統高度約束 + 套自訂高度，全程非動畫（不疊加自家彈跳，§120/§124）。
        UIView.performWithoutAnimation {
            relaxEncapsulatedHeight()
            applyHeight()
            view.layoutIfNeeded()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeyboardAppearance()   // 跟隨 App 要求的鍵盤深淺（§99，如 Telegram 深色）
        // 重套引擎選項（簡繁/全形/標點，§63）；不重建按鍵——切 App 重建會閃動/變形（§113）。
        // 鍵已在 viewDidLoad 建好；⚙ 選單改設定時自呼 rebuildKeyRows。
        applyOptionDefaults()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 過渡完成後只校正外觀/return（§111）；高度不在此重套（§125：轉場交系統、約束已持續存在）。
        applyKeyboardAppearance()
        styleReturnKey()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        let currentDocumentID = textDocumentProxy.documentIdentifier
        if let previous = learningDocumentID, previous != currentDocumentID {
            personalLearning.cancel()
            lastPersonalCommit = nil
        }
        learningDocumentID = currentDocumentID
        applyKeyboardAppearance()   // App 切換/聚焦時深淺可能變
        styleReturnKey()            // 有無文字變動→ return 灰↔藍即時更新（§109）
    }

    /// 依 App 要求的 keyboardAppearance 覆寫深淺；.default → 跟系統（§99）。
    private func applyKeyboardAppearance() {
        // §171 一律跟系統深淺：不再依 host 的 keyboardAppearance 強制 override。
        // 根因：kbBackdrop（UIInputView 系統材質）只跟「系統」深淺、不跟 override；若 host 要求 .light 而系統為深，
        // 強制 .light 會讓「鍵跟 host(白) / 底跟系統(深)」不一致 →「深底白鍵」壞掉。跟系統即鍵與底一致。
        if overrideUserInterfaceStyle != .unspecified { overrideUserInterfaceStyle = .unspecified }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // 外觀過渡中、畫面尚未可見時就壓好高度約束（§115）+ 無動畫定版（§116）：
        // 可見時已是最終高度/按鍵位置，無待動畫差異 → 不會被看到跳動。
        relaxEncapsulatedHeight()
        applyHeight()
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // 轉場交給系統、我方不重繪（§125）：高度約束建立後持續存在，h 沒變時不需每 pass 重套（移除 applyHeight）。
        // 唯一必要＝relax 系統重新注入的 encapsulated 約束（idempotent，guard priority>998 只在新注入時動一次），
        // 否則被壓扁變形（§114）。包 performWithoutAnimation 確保此修正不被外層轉場動畫接管（§120）。
        UIView.performWithoutAnimation {
            relaxEncapsulatedHeight()
        }
    }

    /// iOS 呈現/切 App 時加入私有 required 約束 `UIView-Encapsulated-Layout-Height`（系統預設高 ~228）
    /// → 壓過自訂 @999 高度 → 高度 snap + 鍵被壓扁變形。降其優先序讓自訂高度恆勝（§114）。
    private func relaxEncapsulatedHeight() {
        for c in view.constraints where c.identifier == "UIView-Encapsulated-Layout-Height" {
            if c.priority.rawValue > 998 { c.priority = UILayoutPriority(998) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncGlassFrames()                               // §97：玻璃 frame 對齊按鈕（layout 後）
    }

    private func applyHeight() {
        // 原廠風格變動高度（§90，使用者選）：固定鍵高、總高度隨列數變（注音最高、英文/123 較矮、按鍵全模式同大小）。
        guard keyRowsStack != nil else { return }
        let rowGap: CGFloat = 11                                      // §148 列距 7→11：維持總高 340、單鍵 rowH 51.8→48.6 回原廠（須等於 keyRowsStack.spacing）
        // §147 候選列原廠化：單一候選條(40pt，組字內嵌)取代 §130 兩列。省一列。
        let barH: CGFloat = 40
        // §153 先判候選列顯隱（rebuildKeyRows 已設）→ 候選隱藏(英文/123)時加大頂部留白，免第一列鍵被上緣圓角裁切。
        let candVisible = !(candidateRowRef?.isHidden ?? true)
        let topMargin: CGFloat = candVisible ? 4 : 14
        rootTopConstraint?.constant = topMargin
        let bopomoChrome: CGFloat = 4 + barH + 5 + 4                 // 上邊距 + 單一候選條 + rootSpacing + 下邊距
        let baseChrome: CGFloat = topMargin + 4                      // §153 候選收起：頂部留白(14) + 下邊距(4)
        let refRows = CGFloat(showNumberRow ? 6 : 5)                 // 注音參考列數（數字列 + 4 注音 + 功能）
        // 由注音反推固定鍵高 → 各模式套同一 rowH，按鍵大小一致
        let rowH = max(38, (KBSettings.keyboardHeight - bopomoChrome - (refRows - 1) * rowGap) / refRows)
        // §138 #3：123 頁高度對齊英文頁；以英文頁列數作 123 高度基準，fillEqually 撐滿、外框一致。
        let englishRows = CGFloat((showNumberRow ? 1 : 0) + 3 + 1)
        let curRows = (mode == .numbers)
            ? max(englishRows, CGFloat(keyRowsStack.arrangedSubviews.count))
            : CGFloat(max(1, keyRowsStack.arrangedSubviews.count))
        let chrome = candVisible ? bopomoChrome : baseChrome
        // §187 注音鍵高壓縮對齊原廠：原廠注音鍵(112px)比英文鍵(129px)矮(多一列、列高壓縮)。
        // Stoat 原本全模式同鍵高(127px)→注音偏高。注音×0.88≈112px，英文/123 維持(已對齊原廠 129)。
        let modeRowH = (mode == .bopomo) ? rowH * 0.88 : rowH
        let h = chrome + curRows * modeRowH + (curRows - 1) * rowGap
        if let c = heightConstraint {
            c.constant = h
        } else {
            let c = view.heightAnchor.constraint(equalToConstant: h)
            c.priority = UILayoutPriority(999)
            c.isActive = true
            heightConstraint = c
        }
    }

    // MARK: - 鍵盤本地選項（不依賴 App Group，側載也可用，§65）
    private let localStore = UserDefaults.standard
    private func localOpt(_ key: String, default d: Bool = false) -> Bool {
        localStore.object(forKey: key) == nil ? d : localStore.bool(forKey: key)
    }
    private func setLocalOpt(_ key: String, _ v: Bool) { localStore.set(v, forKey: key) }
    private func optKey(_ o: SchemaOption) -> String { "kbopt_" + o.rawValue }
    private static let glassKey = "kbopt_glass"
    private static let glassStyleKey = "kbopt_glassStyle"   // §141：false=霜面(.regular) / true=透明(.clear)
    private static let glassTintKey = "kbopt_glassTint"     // §141：0無色 1藍 2灰 3暖
    /// 玻璃色調（§141）。nil＝無色（沿用白底材質）。
    private var glassTintColor: UIColor? {
        switch localStore.integer(forKey: Self.glassTintKey) {
        case 1: return UIColor.systemBlue.withAlphaComponent(0.25)
        case 2: return UIColor.systemGray.withAlphaComponent(0.30)
        case 3: return UIColor(red: 0.96, green: 0.86, blue: 0.70, alpha: 0.28)   // 暖調
        default: return nil
        }
    }
    private static let engHintKey = "kbopt_engHint"
    private static let numberRowKey = "kbopt_numberRow"
    private static let quickPunctKey = "kbopt_quickPunct"       // 第一列標點段顯示（§121）
    private static let quickKaomojiKey = "kbopt_quickKaomoji"   // 第一列顏文字段顯示（§121）
    private var numberSubPage = 0                       // 123 頁子頁（0/1，§66）
    private var showNumberRow: Bool { localOpt(Self.numberRowKey, default: false) }

    /// 123 標點模式（§82）：0=自動依中英、1=半形、2=全形。
    private static let n123ModeKey = "kbopt_123mode"
    private var is123Half: Bool {
        switch localStore.integer(forKey: Self.n123ModeKey) {
        case 1: return true
        case 2: return false
        default: return lastLetterMode == .english   // 自動：英文→半形、注音→全形
        }
    }
    /// 123 頁當前兩頁符號（依 is123Half，§82）。
    private var numberPages: ([[String]], [[String]]) {
        is123Half ? (BopomoLayout.numberPage0En, BopomoLayout.numberPage1En)
                  : (BopomoLayout.numberPage0Zh, BopomoLayout.numberPage1Zh)
    }
    /// 123 頁符號鍵（直接插入，§82）。
    private func numberKey(_ sym: String) -> UIButton {
        keyButton(title: sym) { [weak self] in self?.insertEnglish(sym) }
    }

    /// 套用 schema 選項（半全/標點/簡繁/中英）——讀鍵盤本地存儲（§65）。
    private func applyOptionDefaults() {
        for opt in SchemaOption.allCases {
            engine.setOption(opt.rawValue, localOpt(optKey(opt), default: opt.defaultOn))
        }
        updateModeStyling()
    }

    /// 鍵盤內建選項選單（⚙）：toggle 即時套用 + 本地持久化（§65）。
    private func refreshOptionsMenu() {
        func toggle(_ title: String, _ key: String, _ on: Bool, _ apply: @escaping (Bool) -> Void) -> UIAction {
            UIAction(title: title, state: on ? .on : .off) { [weak self] _ in
                self?.setLocalOpt(key, !on); apply(!on); self?.refreshOptionsMenu()
            }
        }
        // 移除「全形標點/字元」(fullShape) 與「英式標點」(asciiPunct)（§138 #1）；123 半全形改由「123 標點」子選單控制
        var items: [UIMenuElement] = SchemaOption.allCases.filter { ![.asciiMode, .fullShape, .asciiPunct].contains($0) }.map { opt in
            toggle(opt.title, optKey(opt), localOpt(optKey(opt), default: opt.defaultOn)) { [weak self] v in
                self?.engine.setOption(opt.rawValue, v)
                if opt == .fullShape { self?.rebuildKeyRows() }   // 123 頁半全形即時更新（§71）
            }
        }
        if #available(iOS 26.0, *) {
            let glassOn = localOpt(Self.glassKey, default: false)
            items.append(toggle("iOS 26 玻璃按鍵", Self.glassKey, glassOn) { [weak self] _ in self?.rebuildKeyRows(); self?.refreshOptionsMenu() })
            if glassOn {   // §141：玻璃風格（霜面/透明）+ 色調
                let clear = localOpt(Self.glassStyleKey)
                func gstyle(_ t: String, _ v: Bool) -> UIAction {
                    UIAction(title: t, state: clear == v ? .on : .off) { [weak self] _ in
                        self?.setLocalOpt(Self.glassStyleKey, v); self?.rebuildKeyRows(); self?.refreshOptionsMenu() }
                }
                items.append(UIMenu(title: "玻璃風格", options: .singleSelection,
                                    children: [gstyle("霜面", false), gstyle("透明", true)]))
                let tint = localStore.integer(forKey: Self.glassTintKey)
                func gtint(_ t: String, _ v: Int) -> UIAction {
                    UIAction(title: t, state: tint == v ? .on : .off) { [weak self] _ in
                        self?.localStore.set(v, forKey: Self.glassTintKey); self?.rebuildKeyRows(); self?.refreshOptionsMenu() }
                }
                items.append(UIMenu(title: "色調", options: .singleSelection,
                                    children: [gtint("無色", 0), gtint("藍", 1), gtint("灰", 2), gtint("暖", 3)]))
            }
        }
        items.append(toggle("注音內嵌輸入框（關＝顯候選列、較快）", Self.embeddedKey, localOpt(Self.embeddedKey, default: true)) { [weak self] _ in self?.embeddedModeChanged() })
        items.append(toggle("常駐數字列", Self.numberRowKey, localOpt(Self.numberRowKey, default: false)) { [weak self] _ in self?.rebuildKeyRows() })
        items.append(toggle("注音鍵英文提示", Self.engHintKey, localOpt(Self.engHintKey)) { [weak self] _ in self?.rebuildKeyRows() })
        // 第一列固定（§130）：標點 / 顏文字各自決定是否顯示
        items.append(toggle("第一列標點", Self.quickPunctKey, localOpt(Self.quickPunctKey, default: true)) { [weak self] _ in self?.refreshIdleQuickRow() })
        items.append(toggle("第一列顏文字", Self.quickKaomojiKey, localOpt(Self.quickKaomojiKey, default: true)) { [weak self] _ in self?.refreshIdleQuickRow() })
        // 123 標點：自動依中英 / 半形 / 全形（§82）
        let cur = localStore.integer(forKey: Self.n123ModeKey)
        func p123(_ title: String, _ v: Int) -> UIAction {
            UIAction(title: title, state: cur == v ? .on : .off) { [weak self] _ in
                self?.localStore.set(v, forKey: Self.n123ModeKey)
                if self?.mode == .numbers { self?.rebuildKeyRows() }
                self?.refreshOptionsMenu()
            }
        }
        items.append(UIMenu(title: "123 標點", options: .singleSelection,
                            children: [p123("自動（依中英）", 0), p123("半形", 1), p123("全形", 2)]))
        // §139：詞庫即時切換出字異常 → 退回；純注音/Plus 為兩個分別打包的版本，不在此切換。
        let menu = UIMenu(title: "輸入選項", children: items)
        optionsMenu = menu                                       // §168 長按 123/返回鍵叫出
        funcOptionsButtons.forEach { $0.menu = menu }            // 同步已掛選單的鍵（設定變更時）
    }

    // MARK: - UI

    private func buildUI() {
        refreshOptionsMenu()                                       // §168 ⚙ 選單（長按 123/返回鍵叫出）

        // §168 候選列只留 ⌄（展開候選格），對齊原廠乾淨佈局；⚙ 改長按 123、收鍵盤鍵移除（原廠 iPhone 無）。
        expandButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expandButton.tintColor = .secondaryLabel
        expandButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        expandButton.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .touchUpInside)


        // 候選：捲動列（與組字、⌄ 同一單列＝原廠風格）
        candidateStack.axis = .horizontal
        candidateStack.spacing = 18                 // §176 候選字距加寬（§159 基礎再加大，更透氣）
        candidateStack.alignment = .center
        candidateBar.showsHorizontalScrollIndicator = false
        candidateBar.addSubview(candidateStack)
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateBar.contentLayoutGuide.leadingAnchor, constant: 8),
            candidateStack.trailingAnchor.constraint(equalTo: candidateBar.contentLayoutGuide.trailingAnchor, constant: -8),
            candidateStack.topAnchor.constraint(equalTo: candidateBar.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateBar.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateBar.frameLayoutGuide.heightAnchor),
        ])

        candidateBar.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)   // 候選吃剩餘寬

        // §147 單一候選條 = 組字 | 候選(flex) | ⌄（省去獨立控制列，⚙ 已移功能列、⌨ 折入 ⌄）
        // §173 注音 preedit label（非內嵌模式顯，內嵌模式 isHidden）
        compositionLabel.font = .systemFont(ofSize: 18 * fontScale, weight: .regular)
        compositionLabel.textColor = .secondaryLabel                // §176 注音淡化：輸入區與候選區分層
        compositionLabel.isHidden = true
        compositionLabel.setContentHuggingPriority(.required, for: .horizontal)
        compositionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // §176 注音 preedit 與候選間細直線分隔（隨 compositionLabel 顯隱）
        compositionSeparator.backgroundColor = .separator
        compositionSeparator.isHidden = true
        compositionSeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        compositionSeparator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let sepWrap = UIView()                                      // 包一層讓直線垂直置中、不撐滿列高
        sepWrap.addSubview(compositionSeparator)
        compositionSeparator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            compositionSeparator.centerXAnchor.constraint(equalTo: sepWrap.centerXAnchor),
            compositionSeparator.centerYAnchor.constraint(equalTo: sepWrap.centerYAnchor),
            sepWrap.widthAnchor.constraint(equalToConstant: 9),
        ])
        sepWrap.isHidden = true
        compositionSepWrapRef = sepWrap
        let candidateRow = UIStackView(arrangedSubviews: [compositionLabel, sepWrap, candidateBar, expandButton])   // §176 preedit | 分隔 | §168 候選 | ⌄
        candidateRow.spacing = 6
        candidateRow.axis = .horizontal
        candidateRow.alignment = .fill                              // 候選 scrollview 撐滿列高
        candidateRow.spacing = 4
        candidateRow.isLayoutMarginsRelativeArrangement = true       // 避開上緣圓角裁切（§104）
        candidateRow.directionalLayoutMargins = .init(top: 0, leading: 12, bottom: 0, trailing: 6)
        candidateRowRef = candidateRow
        let candidateH = candidateRow.heightAnchor.constraint(equalToConstant: 40)   // 單列原廠候選條高
        candidateH.priority = UILayoutPriority(999)  // 可壓縮：host 高度不足時讓位（§58）
        candidateH.isActive = true

        let topBar = candidateRow   // 單一水平候選列即 topBar（勿再設 .vertical，§148 修：舊容器殘留會壞版面）

        keyRowsStack = UIStackView()
        keyRowsStack.axis = .vertical
        keyRowsStack.spacing = 11                // §148 列距 7→11（同 applyHeight rowGap，維持總高、單鍵縮回原廠）
        keyRowsStack.distribution = .fillEqually
        keyRowsStack.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)  // 唯一彈性帶：多餘高度灌入按鍵、不留空白帶（§59）
        rebuildKeyRows()

        rootStack = UIStackView(arrangedSubviews: [topBar, keyRowsStack])
        rootStack.axis = .vertical
        rootStack.spacing = 5
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        let topC = rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4)   // §153 動態：候選列隱藏(英文/123)時加大
        rootTopConstraint = topC
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            topC,
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
        refresh(RimeUpdate(preedit: "", candidates: [], commit: nil))
    }

    private func makeKeyRow(_ keys: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal
        row.spacing = 6                  // 原廠鍵距，避免擁擠（§54）
        row.distribution = .fillEqually
        return row
    }

    /// §165 統一鍵寬網格列（對標原廠注音 stagger）：所有鍵 = 容器/11−60/11（11 欄基準），列**置中**。
    /// row1(11鍵)滿版、row2/3(10鍵)置中內縮半鍵 → 各列鍵同寬、欄位對齊（修「右邊不平衡」）。
    private func uniformRow(_ keys: [UIView], shiftFraction: CGFloat = 0, widthInset: CGFloat = 0) -> UIView {
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal; row.spacing = 6; row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(row)
        row.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        row.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        // §182 row.centerX = (0.5 + shiftFraction) × 容器寬：shiftFraction>0 右移（依寬度比例、跨裝置一致）。0=置中。
        NSLayoutConstraint(item: row, attribute: .centerX, relatedBy: .equal,
                           toItem: container, attribute: .trailing,
                           multiplier: 0.5 + shiftFraction, constant: 0).isActive = true
        for k in keys {
            // §185 widthInset>0 收窄每鍵（整列變窄、左右同時內縮對齊原廠寬）
            k.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 1.0/11.0, constant: -60.0/11.0 - widthInset).isActive = true
        }
        return container
    }

    /// 依模式重建鍵列（注音/英文/數字，§44/§46）。
    private func rebuildKeyRows() {
        keyRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bopomoKeys.removeAll()
        glassKeyButtons.removeAll()                     // §97：重新登記本輪玻璃鍵
        funcOptionsButtons.removeAll()                  // §167 清功能列 ⚙ 舊參照（本輪重建）
        cnEnButton = nil; shiftButton = nil
        switch mode {
        case .numbers:
            let pages = numberSubPage == 0 ? numberPages.0 : numberPages.1   // 半/全形依模式+設定（§82）
            for (i, row) in pages.enumerated() {
                if i == pages.count - 1 {                           // row3：[切頁鍵] + 中段符號 + ⌫（兩頁切換，§66）
                    let switchTitle = numberSubPage == 0 ? "#+=" : "123"
                    let switchKey = grayKey(keyButton(title: switchTitle) { [weak self] in
                        self?.numberSubPage = self?.numberSubPage == 0 ? 1 : 0
                        self?.rebuildKeyRows()
                    })
                    var keys: [UIView] = [switchKey]
                    keys.append(contentsOf: row.map { numberKey($0) })
                    keys.append(backspaceKey())
                    keyRowsStack.addArrangedSubview(makeKeyRow(keys))
                } else {
                    keyRowsStack.addArrangedSubview(makeKeyRow(row.map { numberKey($0) }))
                }
            }
            keyRowsStack.addArrangedSubview(numberFunctionRow())
        case .english:
            buildEnglishRows()
        case .bopomo:
            // §165 統一鍵寬網格（對標原廠 stagger）：數字列/2/3 列(10鍵)置中內縮、row1(11鍵)滿版、row4(10鍵+⌫)左對齊網格。
            if showNumberRow { keyRowsStack.addArrangedSubview(uniformRow(numberRowKeys())) }
            for (i, row) in BopomoLayout.rows.enumerated() {
                let notes = row.map { bopomoKey($0) }
                if i == BopomoLayout.rows.count - 1 {            // 第4列：10 注音鍵 + ⌫（§182 撤 §178 lead：ㄈ 齊左對齊 ㄅ＝原廠；⌫ 維持 1.5× 好按，故右側略偏、注音鍵略窄於 grid）
                    let del = backspaceKey()
                    let r = UIStackView(arrangedSubviews: notes + [del])
                    r.axis = .horizontal; r.spacing = 6; r.distribution = .fill
                    for n in notes { n.widthAnchor.constraint(equalTo: notes[0].widthAnchor).isActive = true }
                    del.widthAnchor.constraint(equalTo: notes[0].widthAnchor, multiplier: 1.5).isActive = true   // §166 ⌫ 1.5×（使用者選保留大）
                    keyRowsStack.addArrangedSubview(r)
                } else if i == 0 {
                    keyRowsStack.addArrangedSubview(makeKeyRow(notes))   // row1：11 鍵滿版（=網格基準寬）
                } else if i == 1 {
                    keyRowsStack.addArrangedSubview(uniformRow(notes, shiftFraction: -0.014))   // §184 row2 微左（原廠中心≈.486，對稱 stagger）
                } else {
                    keyRowsStack.addArrangedSubview(uniformRow(notes, shiftFraction: 0.014))   // §186 撤 §185 收窄：原廠 row2/row3 同寬、僅 row3 右移（量測 IMG_2220：兩列皆 .889 寬、中心 .486/.513）
                }
            }
            keyRowsStack.addArrangedSubview(bopomoFunctionRow())
        }
        candidateRowRef?.isHidden = (mode != .bopomo)   // §142 注音恆顯；英文/123 預設收起（英文有補全時由 refreshEnglishCandidates 展開，對齊原廠矮高度）
        if mode == .english { refreshEnglishCase() } else { updateModeStyling() }
        applyHeight()                                   // 列數變動即更新高度（§90 原廠風格變動高度）
        if #available(iOS 26.0, *) { useGlassKeys ? buildGlassLayer() : teardownGlassLayer() }   // §97 官方玻璃容器（§141 啟用）
    }

    // MARK: - 英文 QWERTY 頁（§46）

    private var englishLetterButtons: [(letter: String, button: UIButton)] = []
    private let textChecker = UITextChecker()   // §142 英文候選：系統字典補全

    /// 英文模式候選（§142）：取游標前最後一個英文單字，用 UITextChecker 系統字典補全顯示於候選列。
    /// 沒打單字時候選列收起（對齊原廠英文鍵盤矮高度）；打字才出補全。next-word 預測需語言模型，暫不做。
    private func refreshEnglishCandidates() {
        guard mode == .english || mode == .bopomo else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let partial = String(String(before.reversed()).prefix { $0.isLetter || $0 == "'" }.reversed())
        // 注音模式（§142 #2 上滑打英文）：只在正打英文單字且未組字時顯示補全，否則不干擾中文候選/快捷列
        if mode == .bopomo, partial.isEmpty || !isPreeditEmpty { return }
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 英文：沒打單字 → 不顯補全（候選列收起，鍵盤維持原廠矮高度）；打字才補全
        let words: [String]
        if partial.isEmpty {
            words = []
        } else {
            let range = NSRange(location: 0, length: (partial as NSString).length)
            let comps = textChecker.completions(forPartialWordRange: range, in: partial, language: "en_US") ?? []
            words = Array(comps.prefix(16))
        }
        for word in words {
            let b = UIButton(type: .system)
            b.setTitle(word, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 18 * fontScale)
            b.setTitleColor(.label, for: .normal)
            b.addAction(UIAction { [weak self] _ in self?.applyEnglishCompletion(partial: partial, word: word) }, for: .touchUpInside)
            candidateStack.addArrangedSubview(b)
        }
        if mode == .english {   // §142 英文：有補全才展開候選列（對齊原廠：idle 矮、打字才出建議列）
            candidateRowRef?.isHidden = words.isEmpty
            applyHeight()
        }
    }

    /// 選英文候選：刪掉已打的部分單字 → 插入完整字 + 空格。
    private func applyEnglishCompletion(partial: String, word: String) {
        for _ in 0..<partial.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(word + " ")
        if shiftState == .shifted { shiftState = .off; refreshEnglishCase() }
        if mode == .bopomo {   // §142 #2：補完後還原注音閒置快捷列
            candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            refreshIdleQuickRow()
        } else {
            refreshEnglishCandidates()
        }
    }

    private func buildEnglishRows() {
        englishLetterButtons.removeAll()
        let rows = BopomoLayout.englishRows
        if showNumberRow { keyRowsStack.addArrangedSubview(makeKeyRow(numberRowKeys())) }   // 數字快捷列（§53/§66 可關，英文頁滿版對齊 QWERTY）
        // Row1：10 字母滿版
        keyRowsStack.addArrangedSubview(makeKeyRow(rows[0].map { englishKey($0) }))
        // Row2：9 字母置中內縮（寬度同 row1）。用純 UIView 容器避免 stack distribution 與置中打架→歪邊（§76）
        let r2 = makeKeyRow(rows[1].map { englishKey($0) })
        let r2c = UIView()
        r2.translatesAutoresizingMaskIntoConstraints = false
        r2c.addSubview(r2)
        NSLayoutConstraint.activate([
            r2.topAnchor.constraint(equalTo: r2c.topAnchor),
            r2.bottomAnchor.constraint(equalTo: r2c.bottomAnchor),
            r2.centerXAnchor.constraint(equalTo: r2c.centerXAnchor),
            r2.widthAnchor.constraint(equalTo: r2c.widthAnchor, multiplier: 0.9),
        ])
        keyRowsStack.addArrangedSubview(r2c)
        // Row3：⇧ + 7 字母 + ⌫
        let shift = grayKey(iconButton(shiftIcon()) { [weak self] in self?.tapShift() })
        shiftButton = shift
        let letters = rows[2].map { englishKey($0) }
        let del = backspaceKey()
        let r3 = UIStackView(arrangedSubviews: [shift] + letters + [del])
        r3.axis = .horizontal; r3.spacing = 6; r3.distribution = .fill
        for k in letters { k.widthAnchor.constraint(equalTo: letters[0].widthAnchor).isActive = true }
        shift.widthAnchor.constraint(equalTo: letters[0].widthAnchor, multiplier: 1.5).isActive = true
        del.widthAnchor.constraint(equalTo: letters[0].widthAnchor, multiplier: 1.5).isActive = true
        keyRowsStack.addArrangedSubview(r3)
        keyRowsStack.addArrangedSubview(englishFunctionRow())
    }

    private func englishKey(_ lower: String) -> UIButton {
        let b = keyButton(title: lower.uppercased()) { [weak self] in self?.tapEnglish(lower) }
        englishLetterButtons.append((lower, b))
        return b
    }

    private func tapEnglish(_ lower: String) {
        textDocumentProxy.insertText(typeUppercase ? lower.uppercased() : lower)
        if shiftState == .shifted { shiftState = .off; refreshEnglishCase() }
        refreshEnglishCandidates()   // §142 即時更新英文補全
    }

    private func refreshEnglishCase() {
        for (lower, b) in englishLetterButtons {
            let t = typeUppercase ? lower.uppercased() : lower
            if b.configuration != nil { b.configuration?.title = t } else { b.setTitle(t, for: .normal) }
        }
        shiftButton?.setImage(UIImage(systemName: shiftIcon()), for: .normal)
        if useGlassKeys, #available(iOS 26.0, *) {
            // glass：Shift 啟用＝藍前景高亮、關閉＝預設（§55）
            shiftButton?.configuration?.baseForegroundColor = shiftState == .off ? .label : .systemBlue
        } else {
            shiftButton?.tintColor = .label
            // 原廠：Shift 啟用＝白底高亮、關閉＝灰底（§49）
            (shiftButton as? KeyButton)?.restingColor = shiftState == .off ? Self.funcKeyGray : KBColor.contentKey
            shiftButton?.backgroundColor = shiftState == .off ? Self.funcKeyGray : KBColor.contentKey
        }
    }

    private func shiftIcon() -> String {
        switch shiftState {
        case .capsLock: return "capslock.fill"
        case .shifted: return "shift.fill"
        case .off: return "shift"
        }
    }

    /// 系統「切換鍵盤」鍵（§60）：tap→下一鍵盤、長按→鍵盤清單（Apple 標準）。custom KB 須自備，不可依賴系統 bar（Telegram 會藏）。
    private func nextKeyboardButton() -> UIButton {
        let b = iconButton("globe") { }     // 實際行為由 handleInputModeList 處理
        b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        return grayKey(b)
    }

    /// §168 把 ⚙ 設定選單掛到某鍵的「長按」（showsMenuAsPrimaryAction 預設 false → tap 走原動作、長按出選單）。
    private func withOptions(_ key: UIButton) -> UIButton {
        key.menu = optionsMenu
        funcOptionsButtons.append(key)   // 設定變更時 refreshOptionsMenu 同步、rebuild 時清空
        return key
    }

    /// 依 `needsInputModeSwitchKey` 在功能列最前面插入切換鍵盤鍵。
    private func withGlobe(_ keys: [UIView]) -> [UIView] {
        needsInputModeSwitchKey ? [nextKeyboardButton()] + keys : keys
    }

    /// iOS English 原廠底列：`中 · 123 · 😀 · 寬空格 · return`（§79，對齊 IMG_1950）。中→回注音。
    private func englishFunctionRow() -> UIStackView {
        let zh = grayKey(keyButton(title: "中") { [weak self] in self?.setMode(.bopomo) })   // 回注音
        let num = grayKey(keyButton(title: "123") { [weak self] in self?.setMode(.numbers) })
        let emoji = grayKey(iconButton("face.smiling") { [weak self] in self?.showKaomojiPanel() })   // 原廠無填滿線條笑臉（§135）
        let space = wideSpaceKey()
        let ret = returnKey()
        let keys = withGlobe([withOptions(num), zh, space, emoji, ret])   // §181 [123 中 空格 😀 ↵]：😀 移右、左2右2 → 空白鍵置中（比照注音 §179）
        return widebar(keys, wideIndex: keys.firstIndex { $0 === space }!, ref: num)
    }

    static let funcKeyGray = KBColor.funcKey   // §99 動態（淺灰/深灰）

    static var keyRadius: CGFloat { flatStyleIOS18 ? 5 : 6 }   // §148 iOS26 對標原廠 8→6（原 §77 圓潤 8pt 偏圓）；iOS18 變體 5pt

    // MARK: - 版本分層樣式（§93/§94 KeyStyle）
    /// 真 Liquid Glass（UIGlassEffect）由 ⚙「iOS 26 玻璃按鍵」開關 opt-in（§141）；風格(霜面/透明)+色調見選單。
    /// iOS 26 以上才套圓角/玻璃等「未來感」視覺；16–18 走原廠 classic（方正、實心）。
    private var isOS26: Bool { if #available(iOS 26.0, *) { return true }; return false }
    private var keyCornerCurve: CALayerCornerCurve { (Self.flatStyleIOS18 || !isOS26) ? .circular : .continuous }   // §146 iOS18 變體＝circular（iOS26 squircle）

    /// iOS 26 「玻璃」鍵（§92）：系統 UIButton.Configuration.glass() 在實機渲染異常
    /// （§88 藍底、§92 浮凸陰影，本機無 GUI 不可重現）→ 改用可預期的**半透明霜白**：
    /// 僅換底色、沿用 keyButton 既有圓角與 1px 細陰影，無系統材質＝無浮凸/無偏色。
    @available(iOS 26.0, *)
    private func applyGlass(_ b: UIButton, prominent: Bool) {
        // 真 Liquid Glass（§97 官方容器，§141 啟用）：此處只「登記」，玻璃由 buildGlassLayer 統一建（風格/色調讀 kbopt）。
        // 不覆寫字體 → 沿用 keyButton 25pt / bopomo .light / grayKey 16pt。
        b.backgroundColor = .clear
        b.layer.shadowOpacity = 0
        if let k = b as? KeyButton {                          // 按壓回饋：clear 底上閃白
            k.restingColor = .clear
            k.pressedColor = UIColor.white.withAlphaComponent(0.4)
        }
        glassKeyButtons.append((b, prominent))
    }

    /// 官方 Liquid Glass 多元件正解（§97）：一個 UIGlassContainerEffect 容器，
    /// 各鍵 glass 巢狀進其 contentView 合併渲染；容器置按鈕之下，按鈕 clear 底→玻璃透出、label/icon 在上。
    @available(iOS 26.0, *)
    private func buildGlassLayer() {
        teardownGlassLayer()
        guard useGlassKeys, let rs = rootStack, rs.superview != nil, !glassKeyButtons.isEmpty else { return }
        let container = UIVisualEffectView(effect: UIGlassContainerEffect())
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(container, belowSubview: rs)          // 按鈕之下＝玻璃為視覺底層
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: keyRowsStack.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: keyRowsStack.trailingAnchor),
            container.topAnchor.constraint(equalTo: keyRowsStack.topAnchor),
            container.bottomAnchor.constraint(equalTo: keyRowsStack.bottomAnchor),
        ])
        for (btn, prominent) in glassKeyButtons {
            let e = UIGlassEffect(style: localOpt(Self.glassStyleKey) ? .clear : .regular)   // §141 風格：透明/霜面
            e.isInteractive = false                              // 靜態鍵不需互動透鏡（§95）
            // §145：tint=nil（官方）在「純色底」會讓鍵消失（玻璃無 App 內容可折射）→ 必須染色才可見。
            // 用 SDK 官方語意色當 tint，對齊非玻璃：深色 systemGray2(內容)/Gray3(功能)、淺色白；高 alpha 確保可見。
            let dark = traitCollection.userInterfaceStyle == .dark
            // 原廠 iOS 26 玻璃鍵＝半透、透出 App 底色（Liquid Glass）。
            // 深色：底暗、玻璃會沒入 → 需高 alpha systemGray 才看得見；淺色：低 alpha 白 → 半透、透出底色＝原廠質感。
            let base: UIColor = dark
                ? (prominent ? UIColor.systemGray2 : UIColor.systemGray3).resolvedColor(with: traitCollection)
                : .white
            e.tintColor = glassTintColor ?? base.withAlphaComponent(dark ? 0.92 : 0.40)
            let g = UIVisualEffectView(effect: e)
            g.isUserInteractionEnabled = false
            g.layer.cornerRadius = Self.keyRadius
            g.layer.cornerCurve = keyCornerCurve   // §146 iOS18 變體玻璃鍵也 circular
            g.clipsToBounds = true
            container.contentView.addSubview(g)                 // 巢狀進 container.contentView → 合併渲染
            glassPairs.append((btn, g))
        }
        glassContainer = container
        view.setNeedsLayout()
    }

    private func teardownGlassLayer() {
        glassContainer?.removeFromSuperview()
        glassContainer = nil
        glassPairs.removeAll()
    }

    /// layout 後把各巢狀 glass frame 同步到對應按鈕（座標轉換）。
    private func syncGlassFrames() {
        guard let c = glassContainer else { return }
        for (btn, g) in glassPairs where btn.superview != nil {
            g.frame = c.contentView.convert(btn.bounds, from: btn)
        }
    }

    /// 功能鍵樣式：iOS 26 + 開關 on → Liquid Glass（regular）；否則灰底 #ABB0BB + 小字 + 原廠按壓高亮。
    private func grayKey(_ b: UIButton) -> UIButton {
        b.titleLabel?.font = .systemFont(ofSize: 16 * fontScale)   // §141 功能鍵小字（玻璃/非玻璃皆同 → 修玻璃時 123/英 被放大）
        if useGlassKeys, #available(iOS 26.0, *) {
            applyGlass(b, prominent: false)
        } else {
            b.backgroundColor = Self.funcKeyGray
            if let k = b as? KeyButton {             // 原廠：灰鍵按下變白（§57）
                k.restingColor = Self.funcKeyGray
                k.pressedColor = KBColor.funcKeyPressed
            }
        }
        return b
    }

    /// return 鍵（§107/§109）：依 returnKeyType + enablesReturnKeyAutomatically + hasText 即時上色。
    private func returnKey() -> UIButton {
        let b = iconButton("return") { [weak self] in self?.tapEnter() }
        returnButton = b
        lastReturnState = nil                                // §157 新建 return 鍵 → 失效快取，強制重套樣式
        styleReturnKey()
        return b
    }

    /// 依 proxy 狀態套 return 鍵樣式（§109）：停用→灰淡；動作型→藍；預設→灰。打字後由 textDidChange 重套。
    private func styleReturnKey() {
        guard let b = returnButton, let k = b as? KeyButton else { return }
        let proxy = textDocumentProxy
        let rkType = proxy.returnKeyType ?? .default
        let isAction = rkType != .default                                // nil→default（灰）；§110
        let hasContent = proxy.hasText || !isPreeditEmpty                 // 已上字 OR 組字中
        // enablesReturnKeyAutomatically proxy 不轉發（§110）→ 對動作欄位近似：空白即停用
        let disabled = isAction && !hasContent
        let st = ReturnState(disabled: disabled, action: isAction, type: rkType)
        if lastReturnState == st { return }                              // §157 無變化跳過：免每鍵 setTitle/setImage 觸發 layout（卡頓優化）
        lastReturnState = st
        if disabled {
            b.isEnabled = false
            b.tintColor = .tertiaryLabel                 // → 淡化
            k.restingColor = Self.funcKeyGray
            k.pressedColor = nil
            b.backgroundColor = Self.funcKeyGray
        } else if isAction {                              // 動作型（.go/.send/.next…）有內容→ 藍
            b.isEnabled = true
            b.tintColor = .white
            k.restingColor = .systemBlue
            k.pressedColor = UIColor.systemBlue.withAlphaComponent(0.7)
            b.backgroundColor = .systemBlue
        } else {                                          // 一般換行 → 灰
            b.isEnabled = true
            b.tintColor = .label
            k.restingColor = Self.funcKeyGray
            k.pressedColor = KBColor.funcKeyPressed
            b.backgroundColor = Self.funcKeyGray
        }
        // §154 return 鍵標籤適配：動作型欄位顯文字（搜尋/前往/傳送/完成…），一般欄位顯 ↵ 圖示（比照原廠）。
        let titleColor: UIColor = disabled ? .tertiaryLabel : (isAction ? .white : .label)
        if let label = Self.returnLabel(for: rkType) {
            b.setImage(nil, for: .normal)
            b.setTitle(label, for: .normal)
            b.setTitleColor(titleColor, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16 * fontScale)
        } else {
            b.setTitle(nil, for: .normal)
            b.setImage(UIImage(systemName: "return"), for: .normal)
        }
    }

    /// §154 returnKeyType → 中文標籤（nil＝顯 ↵ 圖示）。
    private static func returnLabel(for t: UIReturnKeyType) -> String? {
        switch t {
        case .go: return "前往"
        case .search, .google, .yahoo: return "搜尋"
        case .send: return "傳送"
        case .done: return "完成"
        case .next: return "下一個"
        case .join: return "加入"
        case .route: return "路線"
        case .continue: return "繼續"
        default: return nil                               // .default / .return / .emergencyCall → ↵
        }
    }

    /// 常駐數字列鍵（§45）：1-0 + 角落符號小標 + 上划輸入符號（§35 #2）。列佈局由呼叫端決定（注音用 uniformRow、英文用 makeKeyRow，§78）。
    private func numberRowKeys() -> [UIButton] {
        let digits = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
        return digits.map { d -> UIButton in
            let b = keyButton(title: "\(d)") { [weak self] in self?.textDocumentProxy.insertText("\(d)") }
            if let sym = BopomoLayout.numberSymbols[d] {
                let lbl = UILabel()
                lbl.text = sym
                lbl.font = .systemFont(ofSize: 10 * fontScale, weight: .medium)
                lbl.textColor = .systemGray
                lbl.translatesAutoresizingMaskIntoConstraints = false
                b.addSubview(lbl)
                NSLayoutConstraint.activate([
                    lbl.topAnchor.constraint(equalTo: b.topAnchor, constant: 2),
                    lbl.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
                ])
                b.addGestureRecognizer(ClosureSwipe(direction: .up) { [weak self] in self?.insertEnglish(sym) })
            }
            return b
        }
    }

    /// 注音功能列（原廠：123 · 中/英 · 😀 · 寬空格 · ⏎，§44）。
    private func bopomoFunctionRow() -> UIStackView {
        let num = grayKey(keyButton(title: "123") { [weak self] in self?.setMode(.numbers) })
        let cnEn = grayKey(keyButton(title: "英") { [weak self] in self?.setMode(.english) })  // 切英文 QWERTY
        let emoji = grayKey(iconButton("face.smiling") { [weak self] in self?.showKaomojiPanel() })   // 原廠無填滿線條笑臉（§135）
        let space = wideSpaceKey()
        let ret = returnKey()
        let keys = withGlobe([withOptions(num), cnEn, space, emoji, ret])   // §179 [123 英 空格 😀 ↵]：😀 移右、左2右2 → 空白鍵置中（兩拇指等距）
        return widebar(keys, wideIndex: keys.firstIndex { $0 === space }!, ref: num)
    }

    /// 數字頁功能列（返回字母模式 · 😀 · 寬空格 · ⏎，§44）。
    private func numberFunctionRow() -> UIStackView {
        let backTitle = lastLetterMode == .english ? "ABC" : "注音"
        let back = grayKey(keyButton(title: backTitle) { [weak self] in self?.setMode(self?.lastLetterMode ?? .bopomo) })
        let emoji = grayKey(iconButton("face.smiling") { [weak self] in self?.showKaomojiPanel() })   // 原廠無填滿線條笑臉（§135）
        let space = wideSpaceKey()
        let ret = returnKey()
        let keys = withGlobe([withOptions(back), emoji, space, ret])   // §185 [注音/ABC 😀 空格 ↵2×]：😀 移左、↵ 放大 2× → 左2(返回+😀)=右2(↵2×)、空白鍵置中且 Enter 大
        return widebar(keys, wideIndex: keys.firstIndex { $0 === space }!, ref: back, bigKey: ret, bigMult: 2.0)
    }

    private func wideSpaceKey() -> UIButton {
        let space = keyButton(title: "空格") { [weak self] in self?.tapSpace() }
        space.titleLabel?.font = .systemFont(ofSize: 16 * fontScale)   // §141 空格比照原廠：功能鍵小字（非內容鍵 25pt 大字）
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(spaceLongPress(_:)))
        lp.minimumPressDuration = 0.3
        lp.delaysTouchesEnded = false                      // 空格 tap 立即生效（§112）
        space.addGestureRecognizer(lp)                     // 長按滑動移游標（§39）
        return space
    }

    /// 功能列：小鍵等寬、指定一鍵（空格）加寬，比照 iOS。bigKey 可選放大某鍵（§185 123 頁 ↵）。
    private func widebar(_ keys: [UIView], wideIndex: Int, ref: UIView, bigKey: UIView? = nil, bigMult: CGFloat = 2.0) -> UIStackView {
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fill
        for (i, k) in keys.enumerated() where i != wideIndex && k !== ref && k !== bigKey && k is UIButton {
            k.widthAnchor.constraint(equalTo: ref.widthAnchor).isActive = true   // §183 只等寬「按鍵」；spacer/bigKey 由呼叫端自訂寬
        }
        keys[wideIndex].widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: 4.5).isActive = true   // §168 空格 4.0→4.5（⚙ 移出功能列後可更寬，貼原廠 ~53%）
        if let big = bigKey { big.widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: bigMult).isActive = true }   // §185 放大鍵
        return row
    }

    private func setMode(_ m: KBMode) {
        personalLearning.cancel()
        if isExpanded { collapseExpanded() }           // 切模式先收展開面板（§89）
        if m == .bopomo || m == .english { lastLetterMode = m }
        if m == .numbers { numberSubPage = 0 }        // 進 123 頁從第一頁開始（§66）
        mode = m
        rebuildKeyRows()
        applyHeight()                                  // 切模式即時更新高度（§81）
        if m == .bopomo {
            refresh(RimeUpdate(preedit: "", candidates: [], commit: nil))   // 還原閒置快捷符號列（§35）
        } else {                                                            // 英文/123 頁：清注音組字殘留，候選列改顯快捷符號（填滿、高度一致，§84）
            engine.clear()
            clearMarkedText()                                               // §149 組字中切英文/123 → 丟棄宿主欄位殘留 marked 注音
            currentCandidates = []
            preeditText = " "
            candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if m == .english { refreshEnglishCandidates(); autoCapitalize() }   // §142 進英文頁即顯補全 / §154 句首自動大寫
        }
    }

    /// Shift：單擊 off↔shifted、雙擊 capsLock（比照 iOS，§31）。
    private func tapShift() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.3 {
            shiftState = .capsLock
        } else {
            switch shiftState {
            case .off: shiftState = .shifted
            case .shifted, .capsLock: shiftState = .off
            }
        }
        lastShiftTap = now
        if mode == .english { refreshEnglishCase() } else { updateModeStyling() }
    }

    /// iOS 26 玻璃功能鍵是否啟用（鍵盤本地開關 + 系統版本，§57/§65）。
    private var useGlassKeys: Bool {
        if #available(iOS 26.0, *) { return localOpt(Self.glassKey, default: false) }   // 預設關（實心鍵）；玻璃為 opt-in（§141）
        return false
    }

    private func keyButton(title: String, action: @escaping () -> Void) -> UIButton {
        let b = KeyButton(frame: .zero)         // 必用 designated init：UIButton(type:) 工廠會忽略子類（§57）
        b.setContentCompressionResistancePriority(.defaultLow, for: .vertical)   // 高度不足時鍵自縮、不撐爆（§58）
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 25 * fontScale)   // §142 內容鍵 25pt regular（英文/數字/123 對標原廠中等粗；注音另覆寫 .light）
        b.titleLabel?.numberOfLines = 1                            // 防 123/ABC/#+= 換行（§88）
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.6
        b.titleLabel?.lineBreakMode = .byClipping
        b.backgroundColor = KBColor.contentKey
        b.setTitleColor(.label, for: .normal)
        b.layer.cornerRadius = Self.keyRadius
        b.layer.cornerCurve = keyCornerCurve                     // iOS26 squircle / 16–18 circular（§94）
        b.layer.shadowColor = UIColor.black.cgColor               // §147 Part B 鍵底陰影柔化貼原廠：硬 1px → 柔
        b.layer.shadowOpacity = 0.22
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowRadius = 1
        b.layer.masksToBounds = false
        b.addAction(UIAction { [weak self] _ in self?.playClick(); action() }, for: .touchUpInside)   // §154 點擊音效
        if !title.isEmpty, useGlassKeys, #available(iOS 26.0, *) {   // 內容鍵也 glass（§77）
            applyGlass(b, prominent: true)
        }
        return b
    }

    /// SF Symbol 圖示鍵（比照 iOS 原廠圖示，§43）。
    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> UIButton {
        let b = keyButton(title: "", action: action)
        b.setImage(UIImage(systemName: systemName), for: .normal)
        b.tintColor = .label
        return b
    }

    /// 雙標注音鍵：大字注音 + 角落小字英文；上下划輸入英文（§26.2 / §28）。
    private func bopomoKey(_ key: BopomoLayout.Key) -> UIButton {
        let b = keyButton(title: key.symbol) { [weak self] in self?.tapBopomo(key) }
        b.titleLabel?.font = .systemFont(ofSize: 25 * fontScale, weight: .light)   // §142 注音對標原廠細筆畫（英文/123 維持 regular）
        let eng = UILabel()
        eng.text = key.englishLabel
        eng.font = .systemFont(ofSize: 10 * fontScale, weight: .medium)
        eng.textColor = .systemGray
        eng.isHidden = !localOpt(Self.engHintKey)        // 預設純原廠；提示開關控制（§48）
        eng.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(eng)
        NSLayoutConstraint.activate([
            eng.topAnchor.constraint(equalTo: b.topAnchor, constant: 2),
            eng.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
        ])
        if key.hasSwipe {        // 上下划英文與標示解耦：永遠有效（大千≡QWERTY，§48）
            b.addGestureRecognizer(ClosureSwipe(direction: .up) { [weak self] in self?.insertEnglish(key.swipeLower) })
            b.addGestureRecognizer(ClosureSwipe(direction: .down) { [weak self] in self?.insertEnglish(key.swipeUpper) })
        }
        bopomoKeys.append((key, b, eng))
        return b
    }

    /// 上下划：清掉進行中的注音組字後，直接插英文（§28 #2）。
    private func insertEnglish(_ s: String) {
        if !isPreeditEmpty {
            engine.clear()
            refresh(RimeUpdate(preedit: "", candidates: [], commit: nil))
        }
        textDocumentProxy.insertText(s)
        refreshEnglishCandidates()   // §142 #2 注音/英文上滑英文 → 系統字典補全（內部依模式判斷）
    }

    /// 英文模式凸顯英文（依 Shift 顯示大/小寫）、淡化注音；同步 中/英、Shift 鍵（§26.2 / §31）。
    private func updateModeStyling() {
        let english = englishMode
        let upper = typeUppercase
        for (key, main, eng) in bopomoKeys {
            main.setTitleColor(english ? .systemGray3 : .label, for: .normal)
            if english {
                eng.isHidden = false
                eng.text = upper ? key.swipeUpper : key.swipeLower   // 標籤反映將輸出的大小寫（iOS 風）
                eng.textColor = .label
                eng.font = .systemFont(ofSize: 16 * fontScale, weight: .semibold)
            } else {
                eng.isHidden = !localOpt(Self.engHintKey)              // 純原廠時隱藏（§48）
                eng.text = key.englishLabel
                eng.textColor = .systemGray
                eng.font = .systemFont(ofSize: 10 * fontScale, weight: .medium)
            }
        }
        cnEnButton?.setTitle(english ? "英" : "中", for: .normal)
        cnEnButton?.setTitleColor(english ? .systemBlue : .label, for: .normal)
        // Shift 視覺：off ⇧灰 / shifted ⇧藍 / capsLock ⇪藍；注音模式淡化
        let shiftTitle = shiftState == .capsLock ? "⇪" : "⇧"
        shiftButton?.setTitle(shiftTitle, for: .normal)
        shiftButton?.setTitleColor(!english ? .systemGray3 : (shiftState == .off ? .label : .systemBlue), for: .normal)
        shiftButton?.backgroundColor = (english && shiftState != .off) ? UIColor.systemBlue.withAlphaComponent(0.15) : KBColor.contentKey
    }

    // MARK: - Input


    /// 注音鍵 tap：英文模式插字面字母（依 Shift 大小寫，§29 #1 / §31）；否則送注音。
    private func tapBopomo(_ key: BopomoLayout.Key) {
        if englishMode {
            textDocumentProxy.insertText(typeUppercase ? key.swipeUpper : key.swipeLower)
            if shiftState == .shifted { shiftState = .off; updateModeStyling() }
        } else {
            apply(engine.processKey(key.code))
        }
    }


    private func tapSpace() {
        if isPreeditEmpty {
            personalLearning.finishBoundary(allowed: canLearnPersonalPhrases)
            // §154 雙擊空格→句點：快速第二下空格 → 把前一個空格換成「. 」（前一字為英數時，比照原廠）
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            if Date().timeIntervalSince(lastSpaceInsert) < 0.3, before.hasSuffix(" "), before.count >= 2,
               case let prev = before[before.index(before.endIndex, offsetBy: -2)], prev.isLetter || prev.isNumber {
                textDocumentProxy.deleteBackward()              // 移除既有空格
                textDocumentProxy.insertText(". ")
                lastSpaceInsert = .distantPast
                autoCapitalize()
            } else {
                textDocumentProxy.insertText(" ")
                lastSpaceInsert = Date()
                autoCapitalize()
            }
        } else {
            apply(engine.processKey(BopomoLayout.keySpace))
        }
        if mode == .english { refreshEnglishCandidates() }   // §142
    }

    /// §154 點擊音效（原廠 playInputClick；KeyboardViewController 須符合 UIInputViewAudioFeedback 回傳 true）。
    private func playClick() { UIDevice.current.playInputClick() }

    /// §154 英文自動大寫：依欄位 autocapitalizationType + 游標前文脈，句首/詞首自動上 shift（capsLock 時不干預）。
    private func autoCapitalize() {
        guard englishMode, shiftState != .capsLock else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let shouldShift: Bool
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: shouldShift = false
        case .allCharacters: shouldShift = true
        case .words: shouldShift = before.isEmpty || (before.last?.isWhitespace ?? false)
        case .sentences:
            let trailingWS = before.reversed().prefix { $0.isWhitespace }
            let core = before.dropLast(trailingWS.count)
            shouldShift = core.isEmpty
                || trailingWS.contains { $0.isNewline }
                || (!trailingWS.isEmpty && (core.last.map { ".!?".contains($0) } ?? false))
        @unknown default: shouldShift = false
        }
        let target: ShiftState = shouldShift ? .shifted : .off
        if shiftState != target { shiftState = target; refreshEnglishCase() }
    }

    /// 長按空白鍵滑動移游標（§39，比照 iOS 觸控板）。
    @objc private func globeLongPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { showKaomojiPanel() }
    }

    @objc private func spaceLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            spaceCursorLastX = g.location(in: view).x
            spaceCursorAccum = 0
        case .changed:
            let x = g.location(in: view).x
            spaceCursorAccum += x - spaceCursorLastX
            spaceCursorLastX = x
            while spaceCursorAccum >= cursorStep {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: 1); spaceCursorAccum -= cursorStep
            }
            while spaceCursorAccum <= -cursorStep {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: -1); spaceCursorAccum += cursorStep
            }
        default:
            break
        }
    }

    private var isPreeditEmpty: Bool {
        preeditText == " " || preeditText.isEmpty
    }

    /// ⌫ 鍵：單擊刪一字；長按連續刪除（§62）。
    private var backspaceTimer: Timer?
    private func backspaceKey() -> UIButton {
        // §162 刪除全交 long-press 且**手勢獨佔觸控**（cancelsTouchesInView 預設 true）→ .ended 必可靠觸發、
        // 連刪 timer 必被取消，不會「連刪跳掉」（§156 用 cancelsTouchesInView=false 讓 button 也吃觸控 → .ended 不可靠 → 跳掉）。
        let b = grayKey(iconButton("delete.left") { })     // tap action 空：刪除/音效/高亮全在手勢處理
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(backspaceLongPress(_:)))
        lp.minimumPressDuration = 0                         // 觸碰即刪一次
        b.addGestureRecognizer(lp)
        return b
    }

    @objc private func backspaceLongPress(_ g: UILongPressGestureRecognizer) {
        let key = g.view as? KeyButton
        switch g.state {
        case .began:
            key?.isHighlighted = true                       // §162 手動高亮（手勢獨佔觸控、button 不自動高亮）
            playClick()
            tapBackspace()                                  // 立即刪一次
            backspaceTimer?.invalidate()
            // 初次 0.4s 後才開始連刪（比照原廠：短按只刪一字、不會多刪）
            backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.tapBackspace()
                }
            }
        case .ended, .cancelled, .failed:
            key?.isHighlighted = false
            backspaceTimer?.invalidate(); backspaceTimer = nil
        default: break
        }
    }

    private func tapBackspace() {
        personalLearning.cancel()
        if isPreeditEmpty, let text = lastPersonalCommit,
           Date().timeIntervalSince(lastPersonalCommitAt) < 5 {
            personalLearning.penalize(text)
            lastPersonalCommit = nil
        }
        if isPreeditEmpty { textDocumentProxy.deleteBackward() }
        else { apply(engine.processKey(BopomoLayout.keyBackspace)) }
        if mode == .english { refreshEnglishCandidates(); autoCapitalize() }   // §142 / §154 刪除後重評自動大寫
    }

    private func tapEnter() {
        if isPreeditEmpty { personalLearning.finishBoundary(allowed: canLearnPersonalPhrases) }
        else { personalLearning.cancel() }
        if isPreeditEmpty { textDocumentProxy.insertText("\n") }
        else { apply(engine.processKey(BopomoLayout.keyEnter)) }
    }

    /// §173 注音內嵌輸入框（marked text）開關（參考 Hamster enableEmbeddedInputMode）：
    /// ON＝注音內嵌輸入框（原廠感、重宿主較慢）；OFF＝注音顯候選列左側（快、無 setMarkedText）。預設 ON。
    private static let embeddedKey = "kbopt_embedded"
    private var useMarkedText: Bool { localOpt(Self.embeddedKey, default: true) }

    /// §173 切換內嵌模式 → 清當前組字（避免殘留 marked text / 候選列 label）。
    private func embeddedModeChanged() {
        if hasMarkedText {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
            hasMarkedText = false; markedLen = 0
        }
        engine.clear()
        refresh(RimeUpdate(preedit: "", candidates: [], commit: nil))
    }

    private var canLearnPersonalPhrases: Bool {
        // Fail closed on missing traits, secure entry, and non-general fields.
        guard let type = textDocumentProxy.keyboardType, type == .default,
              textDocumentProxy.textContentType == nil else { return false }
        return mode == .bopomo && !englishMode
    }

    private func apply(_ update: RimeUpdate) {
        if let event = update.confirmedSelection {
            personalLearning.accept(event, allowed: canLearnPersonalPhrases)
        } else if update.commit != nil {
            personalLearning.cancel()
        }
        if let commit = update.commit, !commit.isEmpty {
            if useMarkedText {
                // §149/§151 commit 取代當前 marked preedit → unmark 定稿
                textDocumentProxy.setMarkedText(commit, selectedRange: NSRange(location: (commit as NSString).length, length: 0))
                textDocumentProxy.unmarkText()
                hasMarkedText = false; markedLen = 0
            } else {
                textDocumentProxy.insertText(commit)             // §172 無 marked text → 直接上字
            }
        }
        refresh(update)
    }

    private func commitPersonalCandidate(_ text: String, input: String) {
        guard canLearnPersonalPhrases else { return }
        personalLearning.confirmPersonal(text, input: input)
        personalLearning.cancel()
        engine.clear()
        clearMarkedText()
        textDocumentProxy.insertText(text)
        lastPersonalCommit = text
        lastPersonalCommitAt = Date()
        refresh(RimeUpdate(preedit: "", candidates: [], commit: nil))
    }

    /// §151 取消組字（丟棄 marked 注音）。跨宿主可靠做法：unmarkText 把 marked 注音定稿成真文字，再 deleteBackward
    /// 精準刪掉 markedLen 個字。**不用 setMarkedText("")**——LINE 等 App 會把剛 commit 的字一起清掉、dismiss 時也清不掉。
    /// guard hasMarkedText：commit 後/無組字時不動，避免誤刪宿主既有真文字。
    private func clearMarkedText() {
        guard hasMarkedText else { return }                 // §151 guard：commit 後不動，避免誤清宿主已上字
        hasMarkedText = false; markedLen = 0
        // §163 改回官方 setMarkedText("") 清 marked 注音：取代 §151 unmark+deleteBackward×markedLen——
        // 快速刪除時 markedLen 與宿主 marked 文字不同步 → deleteBackward 多刪到已上字「跳掉」。
        // setMarkedText("") 不依賴長度、只清當前 marked region，不會多刪；guard 已防 commit 後誤清。
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
    }

    private func refresh(_ update: RimeUpdate) {
        currentCandidates = update.candidates
        personalCandidateInputs.removeAll()
        if !update.preedit.isEmpty, canLearnPersonalPhrases,
           let native = engine as? RimeEngineLibrime {
            let raw = native.currentRawInput()
            let existing = Set(currentCandidates.map(\.text))
            for phrase in personalLearning.suggestions(for: raw) where !existing.contains(phrase.text) {
                personalCandidateInputs[currentCandidates.count] = raw
                currentCandidates.append(Candidate(text: phrase.text, comment: "個人詞"))
            }
        }
        preeditText = update.preedit.isEmpty ? " " : update.preedit             // §155 isPreeditEmpty 狀態來源（注音已內嵌輸入框）
        // §173 注音 preedit 顯示：內嵌 ON→輸入框(marked text)、隱藏候選列 label；OFF→候選列 label、不碰宿主（快）。
        if useMarkedText {
            compositionLabel.isHidden = true
            compositionSepWrapRef?.isHidden = true
            if update.preedit.isEmpty {
                clearMarkedText()                                // §151 丟棄殘留 marked 注音（guard hasMarkedText：commit 後不動）
            } else {
                textDocumentProxy.setMarkedText(update.preedit, selectedRange: NSRange(location: (update.preedit as NSString).length, length: 0))
                hasMarkedText = true; markedLen = (update.preedit as NSString).length
            }
        } else {
            compositionLabel.text = update.preedit
            compositionLabel.isHidden = update.preedit.isEmpty   // 有注音才顯（候選列左側）
            compositionSepWrapRef?.isHidden = update.preedit.isEmpty   // §176 分隔線隨注音顯隱
        }
        styleReturnKey()                                         // 組字/清空→ return 灰↔藍即時更新（§110）
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if currentCandidates.isEmpty && update.preedit.isEmpty {
            if isExpanded { collapseExpanded() }                 // 組字清空→自動收合展開面板（§89）
            showQuickSymbols()                                   // 無組字→常用符號/顏文字（§35 #1）
            return
        }
        var didHighlight = update.preedit.isEmpty                   // §150 預測候選（輸入完、preedit 空）不高亮，比照原廠（圖3）；組字中才 pill
        var slot = 0                                                // §164 候選鈕 pool 索引
        let font = UIFont.systemFont(ofSize: 22 * fontScale)
        for (i, cand) in currentCandidates.enumerated() {
            guard Self.isRenderable(cand.text) else { continue }   // 過濾生僻字 tofu（§69）；保留原 index
            let b = candButton(slot); slot += 1                    // §164 重用，不每鍵新配置
            b.setTitle(cand.text, for: .normal)                    // 原廠候選無編號（§53）
            b.titleLabel?.font = font
            let idx = i
            b.onTap = { [weak self] in
                guard let self else { return }
                self.playClick()
                if let input = self.personalCandidateInputs[idx] {
                    self.commitPersonalCandidate(cand.text, input: input)
                } else {
                    self.apply(self.engine.selectCandidate(idx))
                }
            }   // §154 音效 + 選字
            if !didHighlight {                                      // §148 首選 pill：白圓角底 + 內距，餘候選扁平（reuse 時須清掉舊 pill）
                didHighlight = true
                b.backgroundColor = KBColor.candHighlight
                b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 11, bottom: 4, right: 11)
                b.layer.cornerRadius = 8
                b.layer.cornerCurve = .continuous
            } else {
                b.backgroundColor = .clear
                b.contentEdgeInsets = .zero
                b.layer.cornerRadius = 0
            }
            candidateStack.addArrangedSubview(b)
        }
    }

    /// §164 候選鈕 pool：依 slot 取既有、不足才新建（暖機後零配置）。
    private var candPool: [CandButton] = []
    private func candButton(_ slot: Int) -> CandButton {
        if slot < candPool.count { return candPool[slot] }
        let b = CandButton(frame: .zero)
        candPool.append(b)
        return b
    }

    // MARK: - 候選展開面板（§89，比照原廠格狀展開）

    private func toggleExpanded() {
        if isExpanded { collapseExpanded() }
        else if !isPreeditEmpty { buildExpandedPanel() }   // 僅組字中可展開
    }

    private func collapseExpanded() {
        expandedPanel?.removeFromSuperview()
        expandedPanel = nil
        isExpanded = false
        keyRowsStack.isHidden = false
        expandButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    }

    /// 展開：隱鍵盤、改顯全候選格（依字寬 wrap、左對齊、絕對索引選字）。
    private func buildExpandedPanel() {
        let cands = (engine.allCandidates() + personalLearning.suggestions(for: (engine as? RimeEngineLibrime)?.currentRawInput() ?? "").filter { phrase in
            !engine.allCandidates().contains { $0.text == phrase.text }
        }.map { Candidate(text: $0.text, comment: "個人詞") }).enumerated().filter { Self.isRenderable($0.element.text) }
        guard !cands.isEmpty else { return }

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = true
        scroll.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)   // 吃彈性高度，與 keyRowsStack 一致（§59）

        let vstack = UIStackView()
        vstack.axis = .vertical
        vstack.spacing = 0                                       // 列距由分隔線處理（§91）
        vstack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(vstack)

        let font = UIFont.systemFont(ofSize: 22 * fontScale)
        let avail = view.bounds.width - 16
        let cols = max(5, min(7, Int(avail / 62)))               // 等寬欄（原廠約 6 欄，§91）
        let cellW = avail / CGFloat(cols)
        let arr = Array(cands)
        var i = 0
        while i < arr.count {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 0
            rowStack.distribution = .fill
            var placed = 0
            while placed < cols, i < arr.count {
                let (absIdx, cand) = arr[i]
                rowStack.addArrangedSubview(expandedCandButton(cand.text, absoluteIndex: absIdx, font: font, width: cellW))
                placed += 1; i += 1
            }
            if placed < cols {                                   // 末列補 spacer 維持左對齊
                let spacer = UIView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                rowStack.addArrangedSubview(spacer)
            }
            vstack.addArrangedSubview(rowStack)
            if i < arr.count {                                   // 列間細橫線（原廠分隔，§91）
                let sep = UIView()
                sep.backgroundColor = .separator
                sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                vstack.addArrangedSubview(sep)
            }
        }

        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            vstack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            vstack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            vstack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            vstack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16),
        ])

        keyRowsStack.isHidden = true
        rootStack.addArrangedSubview(scroll)
        expandedPanel = scroll
        isExpanded = true
        expandButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
    }

    private func expandedCandButton(_ text: String, absoluteIndex: Int, font: UIFont, width: CGFloat) -> UIButton {
        let b = KeyButton(frame: .zero)
        b.setTitle(text, for: .normal)
        b.titleLabel?.font = font
        b.titleLabel?.adjustsFontSizeToFitWidth = true           // 長詞縮放不溢出欄（§91）
        b.titleLabel?.minimumScaleFactor = 0.6
        b.titleLabel?.lineBreakMode = .byClipping
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .clear                               // 原廠扁平無框（§91）
        b.restingColor = .clear
        b.pressedColor = .systemFill                             // 按下淡灰（動態、非白框，§99）
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 46).isActive = true
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if absoluteIndex >= self.engine.allCandidates().count {
                let raw = (self.engine as? RimeEngineLibrime)?.currentRawInput() ?? ""
                self.commitPersonalCandidate(text, input: raw)
            } else {
                self.apply(self.engine.selectCandidateAbsolute(absoluteIndex))
            }
            if self.isExpanded { self.collapseExpanded() }   // 選字後收合回候選列（§89）
        }, for: .touchUpInside)
        return b
    }

    /// 字形可顯示性檢測（§69）：任一字落到 LastResort 字型＝tofu → 不可顯示。per-scalar 快取。
    private static var glyphCache: [Unicode.Scalar: Bool] = [:]
    private static func isRenderable(_ text: String) -> Bool {
        let base = UIFont.systemFont(ofSize: 17) as CTFont
        for sc in text.unicodeScalars {
            if sc.value < 0x2E80 { continue }                      // ASCII/常見符號一律可顯示，免查
            if let c = glyphCache[sc] { if !c { return false }; continue }
            let ns = String(sc) as NSString
            let sub = CTFontCreateForString(base, ns as CFString, CFRange(location: 0, length: ns.length))
            let ok = !((CTFontCopyPostScriptName(sub) as String).contains("LastResort"))
            glyphCache[sc] = ok
            if !ok { return false }
        }
        return true
    }

    /// 無組字時的 idle 快捷列（點即插，§35 #1）。標點/顏文字兩段各由 ⚙ 開關（§121），皆預設開。
    private func showQuickSymbols() {
        var syms: [String] = []
        if localOpt(Self.quickPunctKey, default: true) { syms += BopomoLayout.quickPunct }
        if localOpt(Self.quickKaomojiKey, default: true) { syms += BopomoLayout.quickKaomoji }
        for sym in syms {
            let b = UIButton(type: .system)
            b.setTitle(sym, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 19 * fontScale)
            b.setTitleColor(.secondaryLabel, for: .normal)
            b.addAction(UIAction { [weak self] _ in self?.playClick(); self?.textDocumentProxy.insertText(sym) }, for: .touchUpInside)   // §154 音效
            candidateStack.addArrangedSubview(b)
        }
    }

    /// ⚙ 切換第一列標點/顏文字後即時重繪（候選列固定，只換內容、不動高度，§130）。
    private func refreshIdleQuickRow() {
        guard mode == .bopomo, currentCandidates.isEmpty, isPreeditEmpty, !isExpanded else { return }
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        showQuickSymbols()
    }

    // MARK: - 顏文字面板（§36 #3）

    private func showKaomojiPanel() {
        guard kaomojiPanel == nil else { return }
        let panel = KaomojiPanel(frame: .zero)
        panel.backTitle = lastLetterMode == .english ? "ABC" : "注"   // §180 返回鍵依來源：英文→ABC、注音→注（比照數字頁返回鍵）
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onInsert = { [weak self] s in self?.textDocumentProxy.insertText(s) }
        panel.onClose = { [weak self] in self?.hideKaomojiPanel() }
        panel.onDelete = { [weak self] in self?.tapBackspace() }   // ⌫ 刪除（§61）
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        kaomojiPanel = panel
    }

    private func hideKaomojiPanel() {
        kaomojiPanel?.removeFromSuperview()
        kaomojiPanel = nil
    }

    // 語音：自訂鍵盤無法錄音/叫起 iOS 聽寫（§32 #2）→ 鍵盤端不提供觸發。
    // 容器 App 若有錄音結果（手動開 App 錄製），viewWillAppear 仍會掃描上字。
}

// §154 點擊音效：回傳 true 後 playInputClick() 才會發聲（不需 Full Access）。
extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

import UIKit

/// 截圖驗證用 harness（非正式產品）：把 KeyboardViewController 嵌進一般 App 顯示，
/// 供 simulator 截圖驗證顏色/圓角/版面（本機無鍵盤 GUI 權限的替代方案）。
@main
final class HarnessAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        let personalArg = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--personal-phrase-phase=") }
        let learningArg = ProcessInfo.processInfo.arguments.first {
            $0.hasPrefix("--rime-learning-phase=")
        }
        // Learning CI runs the actual engine in an otherwise empty host app.
        // Do not instantiate a second Rime engine via KeyboardViewController.
        win.rootViewController = learningArg == nil && personalArg == nil ? HarnessVC() : UIViewController()
        win.makeKeyAndVisible()
        window = win
        if let learningArg = learningArg {
            let phase = String(learningArg.dropFirst("--rime-learning-phase=".count))
            DispatchQueue.main.async { RimeLearningSmoke.execute(phase: phase) }
        }
        if let personalArg = personalArg {
            let phase = String(personalArg.dropFirst("--personal-phrase-phase=".count))
            DispatchQueue.main.async { PersonalPhraseSmoke.execute(phase: phase) }
        }
        if ProcessInfo.processInfo.arguments.contains("--rime-segment-probe") {
            DispatchQueue.main.async { RimeSegmentProbe.execute() }
        }
        if ProcessInfo.processInfo.arguments.contains("--rime-event-smoke") {
            // Only hardcoded, non-sensitive cases; the report is written into
            // this Simulator app's Documents folder for GitHub CI to inspect.
            DispatchQueue.main.async {
                RimeEventSmoke.execute()
            }
        }
        return true
    }
}

final class HarnessVC: UIViewController {
    private let kb = KeyboardViewController()
    private let field = UITextField()
    private var nativeMode: Bool { ProcessInfo.processInfo.environment["NATIVE_KB"] == "1" }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground   // 白底，方便對比鍵盤灰

        if nativeMode {                            // 原廠鍵盤取色模式：UITextField → 系統鍵盤
            field.borderStyle = .roundedRect
            field.placeholder = "native keyboard"
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            ])
            return
        }

        let label = UILabel()
        label.text = "KB Harness — 截圖驗證"
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        addChild(kb)
        kb.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kb.view)
        kb.didMove(toParent: self)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            kb.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if nativeMode { field.becomeFirstResponder() }
    }
}

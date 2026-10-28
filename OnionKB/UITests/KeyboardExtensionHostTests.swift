import XCTest

/// Cloud-only real iOS system hosting acceptance. This test deliberately
/// never instantiates KeyboardViewController, and cannot succeed by calling
/// its RimeEngine directly. Stoat.app and the .appex are installed by CI.
final class KeyboardExtensionHostTests: XCTestCase {
    private let hostID = "com.kbtest.harness"

    private func tapSettings(_ application: XCUIApplication, _ title: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let item = application.staticTexts[title].firstMatch
        for _ in 0..<6 where !item.exists {
            application.swipeUp()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 12),
                      "Settings item not found: \(title). UI: \(application.debugDescription)",
                      file: file, line: line)
        if item.exists { item.tap() }
    }

    private func enableStoatViaSystemSettings() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15),
                      "Could not open the actual iOS Settings app")
        tapSettings(settings, "General")
        tapSettings(settings, "Keyboard")
        tapSettings(settings, "Keyboards")
        tapSettings(settings, "Add New Keyboard…")
        // This MUST select the installed extension through Settings, not
        // manufacture AppleKeyboards settings or inject a private preference.
        tapSettings(settings, "Stoat")
        settings.terminate()
    }

    private func visibleKey(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    func testInstalledThirdPartyExtensionInOrdinaryTextField() {
        enableStoatViaSystemSettings()

        let host = XCUIApplication(bundleIdentifier: hostID)
        host.launchArguments = ["--host-keyboard-ui"]
        host.launch()
        let field = host.textFields["stoat.host.textfield"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "Ordinary host UITextField is missing")
        field.tap()

        let zhuyin = visibleKey(host, "ㄎ")
        for _ in 0..<8 {
            if zhuyin.exists { break }
            let globe = [
                visibleKey(host, "Next keyboard"),
                visibleKey(host, "Next Keyboard"),
                visibleKey(host, "下一個鍵盤"),
                visibleKey(host, "🌐")
            ].first(where: { $0.exists })
            guard let switcher = globe else {
                XCTFail("Cannot switch to Stoat, system keyboard UI: \(host.debugDescription)")
                return
            }
            switcher.tap()
        }
        XCTAssertTrue(zhuyin.waitForExistence(timeout: 20),
                      "Stoat Zhuyin keyboard not hosted in the real app: \(host.debugDescription)")
        guard zhuyin.exists else { return }

        // Real button taps must pass through the separate keyboard extension
        // into its host's UITextDocumentProxy, no special test shortcuts.
        zhuyin.tap()
        let ao = visibleKey(host, "ㄠ")
        XCTAssertTrue(ao.waitForExistence(timeout: 8),
                      "Second phonetic key absent after choosing Stoat")
        guard ao.exists else { return }
        ao.tap()

        let candidate = visibleKey(host, "靠")
        XCTAssertTrue(candidate.waitForExistence(timeout: 20),
                      "Actual Rime candidate is absent in hosted extension. UI: \(host.debugDescription)")
        guard candidate.exists else { return }
        candidate.tap()

        XCTAssertEqual(field.value as? String, "靠",
                       "The keyboard extension did not actually commit its candidate to host text")
    }
}

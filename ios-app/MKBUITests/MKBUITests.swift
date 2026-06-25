//
//  MKBUITests.swift
//  MKBUITests
//
//  Created by apple on 2026/5/23.
//

import XCTest

final class MKBUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = launchApp()
        openCompanyCodex(in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testMessageTextShowsNativeSelectionMenu() throws {
        let app = launchApp()
        let message = textElement(containing: "我已经接入 Codex API", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 10), app.debugDescription)

        message.press(forDuration: 1.2)
        XCTAssertTrue(
            waitForAnyElement(labeled: ["选择", "全选", "复制", "Select", "Select All", "Copy"], in: app, timeout: 5),
            app.debugDescription
        )
    }

    @MainActor
    func testCodexModelAndReasoningMenus() throws {
        let app = launchApp()
        openCompanyCodex(in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["刷新公司 Codex"].waitForExistence(timeout: 10))

        tapButton(containing: "切换模型", in: app)
        XCTAssertTrue(app.buttons["gpt-5.5"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["gpt-5.5"].tap()
        tapButton(containing: "切换模型", in: app)
        XCTAssertTrue(app.buttons["gpt-5.4"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["gpt-5.4"].tap()

        tapButton(containing: "切换推理等级", in: app)
        XCTAssertTrue(app.buttons["high"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["high"].tap()
        tapButton(containing: "切换推理等级", in: app)
        XCTAssertTrue(app.buttons["medium"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["medium"].tap()
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testCodexHistoryCanOpenFixedTestConversation() throws {
        let app = launchApp(fixedSessionID: fixtureCodexTestSessionID)
        openCompanyCodex(in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10), app.debugDescription)

        openHistory(in: app)
        XCTAssertTrue(app.navigationBars["历史会话"].waitForExistence(timeout: 10) || app.staticTexts["历史会话"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Test"].waitForExistence(timeout: 15), app.debugDescription)
        tapHistoryRow(title: "Test", in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(waitForTextContaining("item.completed", in: app, timeout: 1), app.debugDescription)
        XCTAssertFalse(waitForTextContaining("codex_hooks", in: app, timeout: 1), app.debugDescription)
    }

    @MainActor
    func testCodexHistorySortsAndShowsMessages() throws {
        let app = launchApp()
        openCompanyCodex(in: app)
        openHistory(in: app)

        let testTitle = app.staticTexts["Test"]
        let adbTitle = app.staticTexts["检查 ADB 设备连接"]
        let gerritTitle = app.staticTexts["查找 Gerrit 密钥"]
        XCTAssertTrue(testTitle.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(adbTitle.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(gerritTitle.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertLessThan(testTitle.frame.minY, adbTitle.frame.minY, "History must sort newer Test session above ADB session.")
        XCTAssertLessThan(adbTitle.frame.minY, gerritTitle.frame.minY, "History must sort ADB session above older Gerrit session.")

        testTitle.tap()
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(waitForTextContaining("Test 会话已载入", in: app, timeout: 10), app.debugDescription)
        XCTAssertFalse(waitForTextContaining("item.completed", in: app, timeout: 1), app.debugDescription)
        XCTAssertFalse(waitForTextContaining("codex_hooks", in: app, timeout: 1), app.debugDescription)
    }

    @MainActor
    func testCodexSourceSwitchesHistoryScope() throws {
        let app = launchApp()
        openCompanyCodex(in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "quectel-lnx")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)

        tapButton(containing: "公司 Codex", in: app)
        tapButton(containing: "lab-vscode", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "lab-vscode")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)

        openHistory(in: app)
        XCTAssertTrue(app.staticTexts["Lab Test"].waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testCodexOrientationSmoke() throws {
        let app = launchApp(fixedSessionID: fixtureCodexTestSessionID)
        openCompanyCodex(in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10) || app.staticTexts["Codex"].waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 10) || app.staticTexts["Codex"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testCodexSendGuideAndInterrupt() throws {
        guard liveCodexUITestsEnabled else {
            throw XCTSkip("Live Company Codex send/guide/interrupt tests are disabled unless MKB_ENABLE_LIVE_CODEX_UI_TESTS=1 is set for this command.")
        }
        let fixedSessionID = liveCodexSessionValue(name: "MKB_LIVE_CODEX_SESSION_ID").trimmingCharacters(in: .whitespacesAndNewlines)
        let fixedSessionTitleValue = liveCodexSessionValue(name: "MKB_LIVE_CODEX_SESSION_TITLE").trimmingCharacters(in: .whitespacesAndNewlines)
        let fixedSessionTitle = fixedSessionTitleValue.isEmpty ? "Test" : fixedSessionTitleValue
        XCTAssertFalse(fixedSessionID.isEmpty, "Live UI tests must pass MKB_LIVE_CODEX_SESSION_ID for the real company Codex Test history conversation.")
        XCTAssertFalse(isCurrentBridgeSessionID(fixedSessionID), "Live UI tests must target a real Codex history session, not the current bridge session.")

        let app = launchApp(fixedSessionID: fixedSessionID, useFixture: false, disableHistoryLoad: true)
        openCompanyCodex(in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fixedSessionTitle)).firstMatch.waitForExistence(timeout: 15) || messageField(in: app).exists, app.debugDescription)

        let stamp = String(Int(Date().timeIntervalSince1970))
        sendCodexMessage("MKBUI\(stamp) reply exactly MKBACK\(stamp)", in: app)
        XCTAssertTrue(waitForTextContaining("MKBUI\(stamp)", in: app, timeout: 8), app.debugDescription)
        XCTAssertTrue(waitForTextContaining("MKBACK\(stamp)", in: app, timeout: 120), app.debugDescription)

        sendCodexMessage("MKBLONG\(stamp) keep the turn active for a while and wait for mobile guidance before final answer", in: app)
        XCTAssertTrue(waitForTextContaining("MKBLONG\(stamp)", in: app, timeout: 8), app.debugDescription)

        let field = messageField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        clearField(field)
        field.typeText("MKBSTEER\(stamp) include MKBSTEERACK\(stamp)")
        let guideButton = app.buttons["引导当前任务"]
        XCTAssertTrue(guideButton.waitForExistence(timeout: 20), app.debugDescription)
        guideButton.tap()
        XCTAssertTrue(waitForTextContaining("MKBSTEER\(stamp)", in: app, timeout: 8), app.debugDescription)

        let interruptButton = app.buttons["中断当前任务"]
        XCTAssertTrue(interruptButton.waitForExistence(timeout: 20), app.debugDescription)
        interruptButton.tap()
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testCodexLiveReadOnlyHistoryCanOpenFixedTestConversation() throws {
        try requireCompanyCodexUITestAccess()
        let fixedSessionID = fixedCompanyCodexTestSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixedSessionTitle = liveCodexSessionTitle
        let expectedText = liveCodexSessionValue(name: "MKB_LIVE_CODEX_EXPECTED_TEXT").trimmingCharacters(in: .whitespacesAndNewlines)

        let app = launchApp(fixedSessionID: fixedSessionID, useFixture: false, disableHistoryLoad: true)
        openCompanyCodex(in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 15), app.debugDescription)
        if expectedText.isEmpty {
            XCTAssertTrue(
                waitForTextContaining(fixedSessionTitle, in: app, timeout: 20) ||
                    app.navigationBars[fixedSessionTitle].exists ||
                    app.staticTexts[fixedSessionTitle].exists,
                app.debugDescription
            )
        } else {
            XCTAssertTrue(waitForTextContaining(expectedText, in: app, timeout: 25), app.debugDescription)
        }

        openHistory(in: app)
        XCTAssertTrue(
            app.staticTexts[fixedSessionTitle].waitForExistence(timeout: 20) ||
                app.buttons[fixedSessionTitle].waitForExistence(timeout: 20),
            app.debugDescription
        )
        tapHistoryRow(title: fixedSessionTitle, in: app)
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 20), app.debugDescription)
        if expectedText.isEmpty {
            XCTAssertTrue(
                waitForTextContaining(fixedSessionTitle, in: app, timeout: 20) ||
                    app.navigationBars[fixedSessionTitle].exists ||
                    app.staticTexts[fixedSessionTitle].exists,
                app.debugDescription
            )
        } else {
            XCTAssertTrue(waitForTextContaining(expectedText, in: app, timeout: 25), app.debugDescription)
        }
        XCTAssertFalse(waitForTextContaining("item.completed", in: app, timeout: 1), app.debugDescription)
        XCTAssertFalse(waitForTextContaining("codex_hooks", in: app, timeout: 1), app.debugDescription)
    }

    @MainActor
    func testCodexFixtureSendReceiveGuideAndInterrupt() throws {
        let app = launchApp(fixedSessionID: fixtureCodexTestSessionID)
        openCompanyCodex(in: app)

        let stamp = String(Int(Date().timeIntervalSince1970))
        sendCodexMessage("fixture ping \(stamp)", in: app)
        XCTAssertTrue(waitForTextContaining("fixture ping \(stamp)", in: app, timeout: 8), app.debugDescription)
        XCTAssertTrue(waitForTextContaining("收到：fixture ping \(stamp)", in: app, timeout: 8), app.debugDescription)

        sendCodexMessage("fixture long \(stamp) keep the turn active", in: app)
        XCTAssertTrue(waitForTextContaining("fixture long \(stamp)", in: app, timeout: 8), app.debugDescription)

        let field = messageField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        clearField(field)
        field.typeText("fixture guide \(stamp)")
        let guideButton = app.buttons["引导当前任务"]
        XCTAssertTrue(guideButton.waitForExistence(timeout: 8), app.debugDescription)
        guideButton.tap()
        XCTAssertTrue(waitForTextContaining("已收到引导：fixture guide \(stamp)", in: app, timeout: 8), app.debugDescription)

        sendCodexMessage("fixture long interrupt \(stamp) keep the turn active", in: app)
        let interruptButton = app.buttons["中断当前任务"]
        XCTAssertTrue(interruptButton.waitForExistence(timeout: 8), app.debugDescription)
        interruptButton.tap()
        XCTAssertTrue(waitForTextContaining("任务已打断", in: app, timeout: 8), app.debugDescription)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments.append("-MKBResetCodexPromptForUITests")
            app.launchArguments.append("-MKBUseCodexFixtureForUITests")
            app.launch()
        }
    }

    @MainActor
    private func openCompanyCodex(in app: XCUIApplication) {
        let companyCodexButton = app.buttons["切换到公司 Codex"]
        if companyCodexButton.waitForExistence(timeout: 5) {
            companyCodexButton.tap()
        }
        XCTAssertTrue(messageField(in: app).waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    private func launchApp(fixedSessionID: String? = nil, useFixture: Bool = true, disableHistoryLoad: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-MKBResetCodexPromptForUITests")
        if useFixture {
            app.launchArguments.append("-MKBUseCodexFixtureForUITests")
        }
        if disableHistoryLoad {
            app.launchArguments.append("-MKBDisableHistoryLoadForUITests")
        }
        if let fixedSessionID, !fixedSessionID.isEmpty {
            XCTAssertFalse(isCurrentBridgeSessionID(fixedSessionID), "UITest must not target the current bridge session.")
            app.launchArguments.append(contentsOf: ["-MKBCodexFixedSessionID", fixedSessionID])
        }
        app.launch()
        return app
    }

    @MainActor
    private func openHistory(in app: XCUIApplication) {
        let historyButton = app.buttons["历史"]
        if historyButton.waitForExistence(timeout: 10) {
            historyButton.tap()
            return
        }
        let historyText = app.staticTexts["历史"]
        XCTAssertTrue(historyText.waitForExistence(timeout: 10), app.debugDescription)
        historyText.tap()
    }

    @MainActor
    private func tapHistoryRow(title: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label == %@", title)
        let exactTitle = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(exactTitle.waitForExistence(timeout: 15), app.debugDescription)
        exactTitle.tap()
    }

    @MainActor
    private func tapButton(containing text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
        button.tap()
    }

    @MainActor
    private func messageField(in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields["Message Codex"]
        if textField.exists { return textField }
        let textView = app.textViews["Message Codex"]
        if textView.exists { return textView }
        let firstTextField = app.textFields.firstMatch
        if firstTextField.exists { return firstTextField }
        let firstTextView = app.textViews.firstMatch
        if firstTextView.exists { return firstTextView }
        return app.descendants(matching: .any).matching(identifier: "Message Codex").firstMatch
    }

    @MainActor
    private func sendCodexMessage(_ text: String, in app: XCUIApplication) {
        let field = messageField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        clearField(field)
        field.typeText(text)
        let sendButton = app.buttons["发送"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 8), app.debugDescription)
        sendButton.tap()
    }

    @MainActor
    private func waitForTextContaining(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if textElement(containing: text, in: app).exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func textElement(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let staticText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if staticText.exists { return staticText }
        let labeledTextView = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if labeledTextView.exists { return labeledTextView }
        let textView = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        if textView.exists { return textView }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func waitForAnyElement(labeled labels: [String], in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                if app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func clearField(_ field: XCUIElement) {
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != "Message Codex" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 4))
        }
    }

    private func isCurrentBridgeSessionID(_ sessionID: String) -> Bool {
        sessionID == "linux-vscode-main" || sessionID == "codex-vscode-current"
    }

    private var fixedCompanyCodexTestSessionID: String {
        liveCodexSessionValue(name: "MKB_LIVE_CODEX_SESSION_ID")
    }

    private var liveCodexSessionTitle: String {
        let title = liveCodexSessionValue(name: "MKB_LIVE_CODEX_SESSION_TITLE").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Test" : title
    }

    private var fixtureCodexTestSessionID: String {
        "fixture-test"
    }

    private var liveCodexUITestsEnabled: Bool {
        if ProcessInfo.processInfo.environment["MKB_ENABLE_LIVE_CODEX_UI_TESTS"] == "1" {
            return true
        }
        let gatePath = "/tmp/MKB_ENABLE_LIVE_CODEX_UI_TESTS"
        guard let gateValue = try? String(contentsOfFile: gatePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              gateValue == "YES_MKB_LIVE_CODEX_UI_TESTS",
              let attributes = try? FileManager.default.attributesOfItem(atPath: gatePath),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modificationDate) < 600
    }

    private func requireCompanyCodexUITestAccess() throws {
        guard liveCodexUITestsEnabled else {
            throw XCTSkip("Company Codex UI tests are disabled unless MKB_ENABLE_LIVE_CODEX_UI_TESTS=1 is set for this command.")
        }
        let sessionID = fixedCompanyCodexTestSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw XCTSkip("Company Codex UI tests require MKB_LIVE_CODEX_SESSION_ID to avoid touching the active work conversation.")
        }
        XCTAssertFalse(isCurrentBridgeSessionID(sessionID), "Company Codex UI tests must not target the current bridge session.")
    }

    private func liveCodexSessionValue(name: String) -> String {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return value
        }
        let path = "/tmp/\(name)"
        guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

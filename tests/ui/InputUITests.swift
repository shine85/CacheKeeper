import XCTest

final class InputUITests: XCTestCase {
    func testCollectionHistoryDeleteRequiresConfirmationAndRefreshesList() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--collection-history"]; app.launch()
        let cells = app.tables.cells
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 15)); XCTAssertEqual(cells.count, 3)
        cells.element(boundBy: 0).swipeLeft(); app.buttons["删除"].firstMatch.tap()
        let confirmation = app.alerts["删除此采集会话？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.buttons["取消"].tap()
        XCTAssertEqual(cells.count, 3)
        cells.element(boundBy: 0).swipeLeft(); app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.buttons["删除"].tap()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: cells)
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 5), .completed)
    }
    func testCollectionReturnsAutomaticallyAfterHomeOtherAppAndHostRecreation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--collection-auto-return"]
        app.launch()
        let evidence = app.staticTexts["CollectionReturnEvidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 15), "COLLECTION_AUTO_RETURN: initial persisted image route")
        let original = evidence.label.split(separator: ":").first.map(String.init)
        XCTAssertNotNil(original)
        XCUIDevice.shared.press(.home)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(evidence.waitForExistence(timeout: 15), "COLLECTION_AUTO_RETURN: return without tapping Continue")
        XCTAssertTrue(evidence.label.hasPrefix(original! + ":idle:"))
        XCTAssertTrue(evidence.label.hasSuffix(":1"), "real background callback must recreate the host navigation")
        app.terminate()
        app.launchArguments = ["--collection-auto-return", "--collection-resume"]
        app.launch()
        XCTAssertTrue(evidence.waitForExistence(timeout: 15), "COLLECTION_AUTO_RETURN: process recreation uses durable original route")
        XCTAssertTrue(evidence.label.hasPrefix(original! + ":idle:"))
    }
    func testCollectionInteractiveBackCancellationAndCompletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--collection-auto-return"]
        app.launch()
        let evidence = app.staticTexts["CollectionReturnEvidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 15))
        let identity = evidence.label
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let short = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(evidence.waitForExistence(timeout: 5), "cancelled interactive back keeps the image page")
        XCTAssertEqual(evidence.label, identity)
        let far = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: far, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.navigationBars["一次性采集向导"].waitForExistence(timeout: 5), "completed native edge swipe returns to the guide")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(app.textFields["CacheKeeperAppSearch"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.textFields["CacheKeeperAppSearch"].waitForExistence(timeout: 10), "explicit exit must not restore old collection")
        XCTAssertFalse(evidence.exists)
    }
    private func requireElement(_ element: XCUIElement, in app: XCUIApplication, stage: String) -> Bool {
        guard element.waitForExistence(timeout: 5) else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(stage)-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "\(stage)-screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Navigation did not reach \(stage)")
            return false
        }
        return true
    }

    private func typeAndWaitForValue(_ text: String, into field: XCUIElement) -> Bool {
        var value = ""
        for character in text {
            value.append(character)
            field.typeText(String(character))
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
            guard XCTWaiter.wait(for: [updated], timeout: 5) == .completed else {
                XCTFail("Text field did not reach expected value: \(value)")
                return false
            }
        }
        return true
    }

    func testKeyboardInputCancelAndReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["CacheKeeperAppSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        for _ in 0..<10 {
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tap must actually show a keyboard")
            guard typeAndWaitForValue("baidu", into: field) else { return }
            XCTAssertEqual(field.value as? String, "baidu")
            app.buttons["取消"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertNotEqual(field.value as? String, "baidu")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.buttons["取消"].exists)
        }
        field.tap()
        guard typeAndWaitForValue("test.bundle", into: field) else { return }
        field.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return must dismiss the keyboard")
        XCTAssertEqual(field.value as? String, "test.bundle")
        let diagnostics = app.navigationBars.buttons["诊断"]
        XCTAssertTrue(diagnostics.isHittable)
        diagnostics.tap()
        // The harness publishes this marker only after UIKit's real didShow callback.
        guard requireElement(app.staticTexts["CacheKeeperTestSearchRoute"], in: app, stage: "diagnostics-shown") else { return }
        XCTAssertTrue(app.buttons["汇总已保存诊断"].exists)
        let back = app.navigationBars.buttons["缓存管家"]
        guard requireElement(back, in: app, stage: "diagnostics-back-button") else { return }
        XCTAssertTrue(back.isHittable)
        back.tap()
        guard requireElement(field, in: app, stage: "search-returned") else { return }
        XCTAssertEqual(field.value as? String, "test.bundle", "Navigation must preserve the query")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.segmentedControls.buttons["用户应用"].tap()
        XCTAssertEqual(field.value as? String, "test.bundle")
        app.buttons["取消"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        guard typeAndWaitForValue("return", into: field) else { return }
        XCTAssertEqual(field.value as? String, "return")
    }
}

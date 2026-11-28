import XCTest

final class InputUITests: XCTestCase {
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
        let diagnostics = app.navigationBars.buttons["测试快照"]
        XCTAssertTrue(diagnostics.isHittable)
        diagnostics.tap()
        // The harness publishes this marker only after UIKit's real didShow callback.
        guard requireElement(app.staticTexts["CacheKeeperTestSearchRoute"], in: app, stage: "diagnostics-shown") else { return }
        XCTAssertTrue(app.navigationBars["测试快照"].exists)
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

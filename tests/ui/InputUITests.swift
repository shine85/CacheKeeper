import XCTest

final class InputUITests: XCTestCase {
    func testKeyboardInputCancelAndReturn() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["CacheKeeperAppSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        for _ in 0..<10 {
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tap must actually show a keyboard")
            field.typeText("baidu")
            XCTAssertEqual(field.value as? String, "baidu")
            app.buttons["取消"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertNotEqual(field.value as? String, "baidu")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.buttons["取消"].exists)
        }
        field.tap()
        field.typeText("test.bundle\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return must dismiss the keyboard")
        XCTAssertEqual(field.value as? String, "test.bundle")
        app.buttons["诊断"].tap()
        XCTAssertTrue(app.navigationBars["诊断采集"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
        field.typeText("return")
        XCTAssertEqual(field.value as? String, "return")
    }
}

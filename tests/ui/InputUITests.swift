import XCTest

final class InputUITests: XCTestCase {
    func testKeyboardInputCancelAndReturn() {
        let app = XCUIApplication()
        app.launch()
        let field = app.searchFields["CacheKeeperAppSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        for _ in 0..<10 {
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tap must actually show a keyboard")
            field.typeText("baidu")
            XCTAssertEqual(field.value as? String, "baidu")
            app.buttons["取消"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertNotEqual(field.value as? String, "baidu")
        }
        app.buttons["诊断"].tap()
        XCTAssertTrue(app.navigationBars["诊断采集"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("test.bundle")
        XCTAssertEqual(field.value as? String, "test.bundle")
    }
}

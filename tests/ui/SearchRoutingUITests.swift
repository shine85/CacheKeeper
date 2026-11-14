import XCTest

final class SearchRoutingUITests: XCTestCase {
    private func snapshot(_ app: XCUIApplication) throws -> [String: Any] {
        app.buttons["诊断"].tap()
        let result = app.staticTexts["CacheKeeperTestSearchRoute"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let data = try XCTUnwrap(result.label.data(using: .utf8))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["state"] as? String, "frozen")
        XCTAssertEqual(value["probeRevision"] as? Int, 2)
        return value
    }

    func testRealFieldTapReachesProbeAndEditing() throws {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["CacheKeeperAppSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let result = try snapshot(app)
        XCTAssertEqual(result["observedFieldTouch"] as? Bool, true)
        let events = try XCTUnwrap(result["events"] as? [String])
        XCTAssertTrue(events.contains("shouldBegin"))
        XCTAssertTrue(events.contains("didBegin"))
        XCTAssertEqual(result["rootCenterHit"] as? String, "field")
        XCTAssertEqual(result["windowHitRole"] as? String, "field")
        XCTAssertEqual(result["windowHitInsideRoot"] as? Bool, true)
        XCTAssertEqual(result["sameHit"] as? Bool, true)
    }

    func testExternalOverlayBypassesRootWhileOtherControlsWork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--search-external-overlay"]
        app.launch()
        let overlay = app.otherElements["CacheKeeperTestExternalOverlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 15))
        // Coordinate tap must follow the real event route, even though the covered field is not hittable.
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let userTab = app.segmentedControls.buttons["用户应用"]
        userTab.tap()
        XCTAssertTrue(userTab.isSelected)
        app.tables.firstMatch.swipeLeft()
        let trollTab = app.segmentedControls.buttons["巨魔应用"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: trollTab)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        let result = try snapshot(app)
        XCTAssertEqual(result["observedFieldTouch"] as? Bool, false)
        let events = try XCTUnwrap(result["events"] as? [String])
        XCTAssertFalse(events.contains("shouldBegin"))
        XCTAssertFalse(events.contains("didBegin"))
        XCTAssertEqual(result["rootCenterHit"] as? String, "field")
        XCTAssertEqual(result["windowHitRole"] as? String, "navigationContainer")
        XCTAssertEqual(result["windowHitKind"] as? String, "view")
        XCTAssertEqual(result["windowHitInsideRoot"] as? Bool, false)
        XCTAssertEqual(result["windowHitInsideNavigationBar"] as? Bool, false)
        XCTAssertEqual(result["sameHit"] as? Bool, false)
    }
}

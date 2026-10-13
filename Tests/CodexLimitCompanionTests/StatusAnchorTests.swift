import XCTest
import AppKit
@testable import CodexLimitCompanion

final class StatusAnchorTests: XCTestCase {
    func testRejectsUnhostedStatusItemAndAcceptsTopEdgeOnEitherDisplay() {
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -1920, y: -300, width: 1920, height: 1080)]
        XCTAssertFalse(StatusAnchor.isValid(NSRect(x: 0, y: -18, width: 80, height: 22), screens: screens))
        XCTAssertFalse(StatusAnchor.isValid(.zero, screens: screens))
        XCTAssertTrue(StatusAnchor.isValid(NSRect(x: 1700, y: 1056, width: 28, height: 24), screens: screens))
        XCTAssertTrue(StatusAnchor.isValid(NSRect(x: -500, y: 756, width: 28, height: 24), screens: screens))
        XCTAssertFalse(StatusAnchor.isValid(NSRect(x: 3000, y: 1056, width: 28, height: 24), screens: screens))
    }
}

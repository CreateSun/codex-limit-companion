import AppKit
import XCTest
@testable import CodexLimitCompanion

final class StatusIconTests: XCTestCase {
    func testIconsHaveVisiblePixelsAtAllQuotaStates() throws {
        for (name, value) in [("unknown", Optional<Double>.none), ("empty", 0), ("half", 50), ("full", 100)] {
            let image = QuotaIcon.image(remaining: value)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            var visible = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visible += 1 }
                }
            }
            XCTAssertGreaterThan(visible, 50, "Invisible status icon: \(name)")
            if let path = ProcessInfo.processInfo.environment["COMPANION_ICON_TEST_OUTPUT"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
            }
        }
    }
}

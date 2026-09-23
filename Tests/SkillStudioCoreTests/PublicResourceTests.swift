import XCTest
@testable import SkillStudioCore

final class PublicResourceTests: XCTestCase {
    func testVendorArtworkIsAbsentFromCoreResources() {
        for (name, ext) in [("claude", "icns"), ("codex", "icns"), ("gemini", "png")] {
            XCTAssertNil(Localization.resourceURL(name, extension: ext))
        }
    }
}

import XCTest
@testable import MobiusCore

final class UpdateCheckerTests: XCTestCase {
    func testParseRelease() {
        let json = Data(#"{"tag_name":"v0.1.6","html_url":"https://github.com/chussum/mobius/releases/tag/v0.1.6"}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(json),
                       ReleaseInfo(version: "0.1.6",
                                   url: "https://github.com/chussum/mobius/releases/tag/v0.1.6"))
        XCTAssertNil(UpdateChecker.parse(Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"v"}"#.utf8)))
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("0.1.6", than: "0.1.5"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.10", than: "0.1.5")) // 문자열 비교 함정
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.5", than: "0.1.5"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.4", than: "0.1.5"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0")) // 자릿수 패딩
    }
}

import XCTest
@testable import MobiusCore

final class ModelsTests: XCTestCase {
    func testEnvironmentPaths() {
        let env = MobiusEnvironment(home: URL(fileURLWithPath: "/tmp/x"), localUser: "u")
        XCTAssertEqual(env.credentialsFile.path, "/tmp/x/.claude/.credentials.json")
        XCTAssertEqual(env.claudeKeychainService, "Claude Code-credentials")
    }
}

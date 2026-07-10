import Foundation

/// 모든 파일 경로의 단일 출처. 테스트는 temp 루트로, CLI는 MOBIUS_HOME 환경변수로 재지정 가능.
public struct MobiusEnvironment: Sendable {
    public var home: URL
    public var localUser: String

    public init(home: URL, localUser: String) {
        self.home = home
        self.localUser = localUser
    }

    public var claudeDir: URL { home.appendingPathComponent(".claude") }
    public var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public var credentialsFile: URL { claudeDir.appendingPathComponent(".credentials.json") }
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    public var appSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Mobius")
    }
    public var accountsFile: URL { appSupportDir.appendingPathComponent("accounts.json") }

    /// Claude Code가 쓰는 Keychain 항목 좌표
    public var claudeKeychainService: String { "Claude Code-credentials" }
    public var claudeKeychainAccount: String { localUser }

    public static func live() -> MobiusEnvironment {
        let home: URL
        if let override = ProcessInfo.processInfo.environment["MOBIUS_HOME"] {
            home = URL(fileURLWithPath: override)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return MobiusEnvironment(home: home, localUser: NSUserName())
    }
}

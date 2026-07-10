import Foundation

public enum ClaudeConfigError: Error { case malformedClaudeJSON }

/// Claude Code 자격증명 3곳(Keychain / .credentials.json / ~/.claude.json oauthAccount)의 읽기·쓰기.
public struct ClaudeConfigIO: Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient

    public init(env: MobiusEnvironment, keychain: KeychainClient) {
        self.env = env
        self.keychain = keychain
    }

    // MARK: 읽기

    /// 현재 로그인 상태의 스냅샷. 로그아웃 상태(Keychain·파일 둘 다 없음)면 nil.
    ///
    /// **Keychain을 진실의 원천으로 삼는다** — 실측 결과 이 환경의 Claude Code는
    /// 최신 토큰을 Keychain "Claude Code-credentials"에 쓰고 .credentials.json 파일은
    /// 갱신하지 않는다(낡음). 파일을 우선 읽으면 낡은 토큰이 최신 이메일과 짝지어져
    /// 프로필이 오염된다(실측 버그). 파일은 Keychain이 비었을 때의 폴백일 뿐이다.
    /// 호출측이 매 틱 이걸 부르지 않도록 상위에서 변화 감지로 게이팅한다(승인창 최소화).
    public func readLiveSnapshot() throws -> CredentialsSnapshot? {
        let blob: Data
        if let keychainBlob = try keychain.read(service: env.claudeKeychainService,
                                                account: env.claudeKeychainAccount) {
            blob = keychainBlob
        } else if let fileData = try? Data(contentsOf: env.credentialsFile), !fileData.isEmpty {
            blob = fileData
        } else {
            return nil
        }
        var oauthJSON: Data?
        if let block = try readOAuthAccountDict() {
            oauthJSON = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
        }
        return CredentialsSnapshot(keychainBlob: blob, credentialsFileData: blob,
                                   oauthAccountJSON: oauthJSON)
    }

    public func readOAuthAccountDict() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: env.claudeJSON) else { return nil }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConfigError.malformedClaudeJSON
        }
        return dict["oauthAccount"] as? [String: Any]
    }

    public func liveEmail() throws -> String? {
        try readOAuthAccountDict()?["emailAddress"] as? String
    }

    /// 라이브 상태(토큰+이메일)를 간격을 두고 두 번 읽어 **값이 일치할 때만** 반환한다.
    /// 로그인/전환 도중 토큰(Keychain)과 이메일(~/.claude.json)이 순차 갱신되는 찰나엔
    /// 두 읽기가 달라지므로 nil을 반환해 "새 토큰 + 옛 이메일" 오저장을 막는다.
    ///
    /// 파일 mtime 기반 판정은 부적합하다 — 활성 claude 세션이 ~/.claude.json을 자주 쓰므로
    /// "N초간 idle" 조건이 영영 충족되지 않아 로그인 완료 감지가 막힌다(실측 버그). 그래서
    /// 파일이 바쁜지와 무관하게 값 자체를 두 번 비교한다.
    public func readStableLiveSnapshot(gap: Duration = .milliseconds(700))
        async -> (snapshot: CredentialsSnapshot, email: String)? {
        guard let s1 = try? readLiveSnapshot(), let e1 = try? liveEmail() else { return nil }
        try? await Task.sleep(for: gap)
        guard let s2 = try? readLiveSnapshot(), let e2 = try? liveEmail() else { return nil }
        guard s1.keychainBlob == s2.keychainBlob, e1 == e2 else { return nil }
        return (s2, e2)
    }

    // MARK: 쓰기

    public func writeLiveSnapshot(_ snap: CredentialsSnapshot) throws {
        try keychain.write(service: env.claudeKeychainService,
                           account: env.claudeKeychainAccount, data: snap.keychainBlob)
        try writeAtomic(snap.credentialsFileData, to: env.credentialsFile, mode: 0o600)
        try patchOAuthAccount(snap.oauthAccountJSON)
    }

    private func patchOAuthAccount(_ oauthJSON: Data?) throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: env.claudeJSON) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ClaudeConfigError.malformedClaudeJSON }
            dict = existing
        }
        if let oauthJSON,
           let block = try JSONSerialization.jsonObject(with: oauthJSON) as? [String: Any] {
            dict["oauthAccount"] = block
        } else {
            dict.removeValue(forKey: "oauthAccount")
        }
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try writeAtomic(out, to: env.claudeJSON, mode: 0o600)
    }

    func writeAtomic(_ data: Data, to url: URL, mode: Int16) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

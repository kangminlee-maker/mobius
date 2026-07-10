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

    /// 라이브 상태가 안정적인지 — 즉 Claude Code가 토큰 파일(.credentials.json)과
    /// 이메일 파일(~/.claude.json)을 "지금 갱신 중"이 아닌지 판별한다.
    ///
    /// 두 파일에는 공통 계정 식별자가 없어(토큰 파일엔 email 없음, email 파일엔 token 없음)
    /// 로그인/전환으로 둘이 순차 갱신되는 찰나에 읽으면 "새 토큰 + 옛 이메일"이 섞여
    /// 프로필에 잘못 저장될 수 있다. 두 파일 모두 최근 `window`초 내 수정이 없을 때만
    /// 일관적이라고 보고, 저장 계열 연산(resave/adopt/reconcile)을 이때만 수행한다.
    public func liveIsStable(now: Date = Date(), window: TimeInterval = 2) -> Bool {
        for url in [env.credentialsFile, env.claudeJSON] {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if now.timeIntervalSince(m) < window { return false }
        }
        return true
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

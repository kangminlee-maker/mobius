import Foundation

public enum SwitcherError: Error, Equatable {
    case unknownAccount
    case noStoredSecret
    case unsupportedProvider(Provider)
}

/// 계정 전환 엔진. 순서: 라이브 되저장 → 대상 기록 → 실패 시 롤백.
/// 프로바이더별 라이브 IO는 ProviderConfigIO 어댑터가 담당하고,
/// Switcher는 등록된 어댑터의 풀들에 같은 전환/adopt/reconcile 규칙을 적용한다.
public final class Switcher: @unchecked Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient
    let store: AccountStore
    let ios: [Provider: any ProviderConfigIO]

    public init(env: MobiusEnvironment, keychain: KeychainClient,
                store: AccountStore, io: ClaudeConfigIO,
                extraIOs: [any ProviderConfigIO] = []) {
        self.env = env; self.keychain = keychain; self.store = store
        var map: [Provider: any ProviderConfigIO] = [.claude: io]
        for extra in extraIOs { map[extra.provider] = extra }
        self.ios = map
    }

    /// 등록된 어댑터들 — 프로바이더 rawValue 순으로 결정적 순회.
    private var orderedIOs: [(Provider, any ProviderConfigIO)] {
        ios.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    /// 현재 라이브 상태를, (provider, email)이 일치하는 프로필에 되저장한다.
    /// 반환: 되저장된 프로필 id (일치 프로필 없으면 nil).
    /// 사용자 전환(switchTo) 직전에 호출 — 라이브가 settled 상태이므로 단일 읽기로 충분하다.
    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    @discardableResult
    public func resaveLiveIntoMatchingProfile(provider: Provider) throws -> UUID? {
        guard let io = ios[provider],
              let live = try io.readLiveSecretData(),
              let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: {
                  $0.provider == provider && $0.emailAddress == email
              })
        else { return nil }
        try store.setSecretData(live, for: profile.id)
        return profile.id
    }

    public func switchTo(_ id: UUID) throws {
        guard let profile = store.file.accounts.first(where: { $0.id == id }) else {
            throw SwitcherError.unknownAccount
        }
        guard let io = ios[profile.provider] else {
            throw SwitcherError.unsupportedProvider(profile.provider)
        }
        guard let target = try store.secretData(for: id) else { throw SwitcherError.noStoredSecret }

        // 1. 라이브 최신 토큰 되저장 (CLI가 refresh했을 수 있으므로)
        let before = try io.readLiveSecretData()
        try resaveLiveIntoMatchingProfile(provider: profile.provider)

        // 2. 대상 기록, 실패 시 롤백
        do {
            try io.writeLiveSecretData(target)
        } catch {
            if let before { try? io.writeLiveSecretData(before) }
            throw error
        }
        try store.setActive(id)
    }

    /// 현재 로그인된 계정이 아직 프로필로 등록되지 않았다면 자동 흡수한다 (전 프로바이더).
    /// 앱 최초 실행 시 "등록된 계정 없음" 대신 사용 중인 계정이 바로 뜨도록 하는 부트스트랩.
    /// 반환: 새로 흡수한 첫 프로필(있으면). 로그인 상태가 아니거나 이미 등록됐으면 nil.
    @discardableResult
    public func adoptLiveAccountIfUnregistered() async throws -> AccountProfile? {
        var first: AccountProfile?
        for (provider, io) in orderedIOs {
            guard let adopted = try await adoptLiveAccount(provider: provider, io: io) else {
                continue
            }
            if first == nil { first = adopted }
        }
        return first
    }

    private func adoptLiveAccount(provider: Provider,
                                  io: any ProviderConfigIO) async throws -> AccountProfile? {
        // ★ 등록 여부를 먼저 확인 — 이메일 읽기는 승인창 없는 값싼 경로다(프로토콜 계약).
        //   Claude의 Keychain 읽기(승인창 유발)는 정말 미등록일 때만.
        guard let email = try io.liveEmail(),
              !store.file.accounts.contains(where: {
                  $0.provider == provider && $0.emailAddress == email
              })
        else { return nil }
        // 비밀+이메일을 두 번 읽어 일치할 때만(전환/리프레시 중 불일치 배제) 저장한다.
        guard let (live, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == email,
              let identity = try io.liveIdentity(), identity.emailAddress == email
        else { return nil }
        let nickname = String(email.split(separator: "@").first ?? "account")
        let profile = try store.upsertProfile(nickname: nickname, provider: provider,
                                              identity: identity, secretData: live)
        try store.setActive(profile.id)
        return profile
    }

    /// 외부(앱 밖) 재로그인 감지 시 상태 대사 (전 프로바이더): 라이브 email이 아는
    /// 프로필이면 그 프로필을 활성으로 표시하고 최신 토큰을 흡수한다.
    /// 모르는 계정이면 손대지 않는다.
    public func reconcile() async throws {
        for (provider, io) in orderedIOs {
            try await reconcile(provider: provider, io: io)
        }
    }

    private func reconcile(provider: Provider, io: any ProviderConfigIO) async throws {
        // 이메일은 승인창 없는 값싼 경로로 읽는다. 활성 계정이 그대로면 비밀 읽기
        // (Claude는 Keychain)를 아예 하지 않아 15초 주기 승인창 폭탄을 막는다.
        guard let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: {
                  $0.provider == provider && $0.emailAddress == email
              })
        else { return }
        let activeUnchanged = store.file.activeByProvider[provider] == profile.id
        // 존재 확인은 stat으로 — 15초 주기 정상 경로에서 비밀 파일 전체를 읽지 않는다
        // (파일이 없을 때만 secretData가 레거시 Keychain 이관까지 시도).
        let alreadyHasSecret = FileManager.default
            .fileExists(atPath: env.secretFile(for: profile.id).path)
            || (try? store.secretData(for: profile.id)) != nil
        if activeUnchanged && alreadyHasSecret { return } // 정상 상태 — 비밀 접근 없음

        // 실제 변화가 있을 때만(드묾) 비밀+이메일 두 번 읽어 일치 확인 후 저장.
        guard let (live, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == email else { return }
        try store.setSecretData(live, for: profile.id)
        if !activeUnchanged {
            try store.setActive(profile.id)
            // 외부(사용자) 로그인으로 활성이 바뀐 것 — 자동 전환 상태가 아니므로
            // 플래그를 내려 onTick의 primary 자동 복귀를 막는다 (앱·CLI 공통 경로).
            try store.setAutoSwitchedFromPrimary(false, provider: provider)
        }
    }
}

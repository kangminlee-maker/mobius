import Foundation

/// 리셋 프로브 판단부(순수 상태) — 소진 기록(rateLimit)의 리셋 시각이 지난 계정을 골라내고,
/// 창당 1회 디듀프 + 실패 백오프를 관리한다. 실행(실제 최소 호출)은 호출자가 한다.
/// 설계·실측 근거: docs/design/reset-probe-prep.md
public final class ResetProber: @unchecked Sendable {
    /// 창당 최대 시도(첫 시도 포함). 초과 시 이 창은 포기 — 리트라이 스톰 방지.
    public var maxAttempts = 3
    /// n번째 실패 후 다음 시도까지의 간격 (마지막 값이 이후 반복 적용)
    public var backoff: [TimeInterval] = [60, 300]

    private enum Phase: Equatable {
        case pending(attempts: Int, nextAttemptAt: Date)
        case done
    }
    /// 계정별 마지막 창 상태 — 리셋 시각이 바뀌면 새 창으로 보고 초기화한다.
    private var windows: [UUID: (resetsAt: Date, phase: Phase)] = [:]
    private let lock = NSLock()

    public init() {}

    /// 지금 프로브해야 할 계정들 (파일 내 순서 = 풀 우선순위 유지).
    public func due(file: AccountsFile, now: Date) -> [AccountProfile] {
        guard file.resetProbeEnabled else { return [] }
        lock.lock(); defer { lock.unlock() }
        return file.accounts.filter { p in
            guard !p.needsReauth, let rl = p.rateLimit, now >= rl.resetsAt else { return false }
            switch phase(of: p.id, resetsAt: rl.resetsAt) {
            case .done: return false
            case let .pending(_, nextAttemptAt): return now >= nextAttemptAt
            }
        }
    }

    private func phase(of id: UUID, resetsAt: Date) -> Phase {
        if let w = windows[id], w.resetsAt == resetsAt { return w.phase }
        let fresh = Phase.pending(attempts: 0, nextAttemptAt: .distantPast)
        windows[id] = (resetsAt, fresh)
        return fresh
    }

    public func noteSuccess(_ id: UUID, resetsAt: Date) {
        lock.lock(); defer { lock.unlock() }
        windows[id] = (resetsAt, .done)
    }

    /// 재시도가 무의미한 사유(만료·폐기 토큰 등) — 이 창은 즉시 포기.
    public func noteGiveUp(_ id: UUID, resetsAt: Date) {
        lock.lock(); defer { lock.unlock() }
        windows[id] = (resetsAt, .done)
    }

    /// 실패 기록. 반환 true = 시도 소진(창 포기 확정) — 호출자는 이때만 실패를 알린다.
    public func noteFailure(_ id: UUID, resetsAt: Date, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case let .pending(prior, _) = phase(of: id, resetsAt: resetsAt) else {
            return false // 이미 done — 늦게 도착한 실패는 무시
        }
        let attempts = prior + 1
        if attempts >= maxAttempts {
            windows[id] = (resetsAt, .done)
            return true
        }
        let delay = backoff[min(attempts - 1, backoff.count - 1)]
        windows[id] = (resetsAt,
                       .pending(attempts: attempts, nextAttemptAt: now.addingTimeInterval(delay)))
        return false
    }
}

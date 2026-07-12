import Foundation

/// codex 세션 로그(rollout-*.jsonl)의 rate_limits 상태.
///
/// 실측(2026-07-12, codex-cli 0.144.1): 매 턴의 `event_msg`/`token_count` 이벤트에
/// `payload.rate_limits`가 붙어 온다 — Claude처럼 에러 문구를 긁을 필요 없이 구조화돼 있고,
/// 사용량 게이지도 이 이벤트에서 네트워크 없이 얻는다.
/// ```
/// {"timestamp":"2026-07-12T09:07:14.309Z","type":"event_msg","payload":{"type":"token_count",
///  "info":{...},"rate_limits":{"limit_id":"codex","primary":{"used_percent":64.0,
///  "window_minutes":300,"resets_at":1783861033},"secondary":{"used_percent":82.0,
///  "window_minutes":10080,"resets_at":1784354513},"plan_type":"pro",
///  "rate_limit_reached_type":null}}}
/// ```
/// primary=5시간 창(300분), secondary=주간 창(10080분), resets_at=epoch 초.
public struct CodexRateLimitStatus: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var usedPercent: Double
        public var windowMinutes: Int?
        public var resetsAt: Date?

        public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    public var primary: Window?    // 5시간 창
    public var secondary: Window?  // 주간 창
    /// rate_limit_reached_type — null이 아니면 서버가 소진을 명시한 것.
    /// 값 형태는 미실측(실제 소진 미관찰) — 창 이름 포함 여부로 방어적으로 해석한다.
    public var reachedType: String?
    /// 라인 자신의 timestamp (없으면 nil)
    public var timestamp: Date?

    public init(primary: Window?, secondary: Window?, reachedType: String?, timestamp: Date?) {
        self.primary = primary
        self.secondary = secondary
        self.reachedType = reachedType
        self.timestamp = timestamp
    }

    /// 소진 판정: 서버 명시(reached_type != nil) 또는 used_percent >= 100 (방어적 이중화 —
    /// 실제 소진 이벤트 형태를 실측하기 전까지 두 신호 모두 인정한다).
    ///
    /// 리셋 시각은 소진된 창들 중 가장 늦은 resets_at — 주간 창이 소진이면 5시간 창이
    /// 리셋돼도 소용없기 때문. reached_type이 있는데 어느 창인지 못 읽으면 primary의
    /// resets_at을 쓴다(가장 짧은 잠금 — 틀려도 다음 hit가 다시 교정한다).
    public func exhaustionHit() -> RateLimitHit? {
        var exhausted: [Window] = []
        if let p = primary, p.usedPercent >= 100 { exhausted.append(p) }
        if let s = secondary, s.usedPercent >= 100 { exhausted.append(s) }
        if let t = reachedType {
            if t.localizedCaseInsensitiveContains("secondary"), let s = secondary {
                exhausted.append(s)
            } else if t.localizedCaseInsensitiveContains("primary"), let p = primary {
                exhausted.append(p)
            }
            if exhausted.isEmpty { return RateLimitHit(resetsAt: primary?.resetsAt) }
        }
        guard !exhausted.isEmpty else { return nil }
        return RateLimitHit(resetsAt: exhausted.compactMap(\.resetsAt).max())
    }

    /// 게이지용 사용량 스냅샷 — Claude usage 엔드포인트와 같은 개념으로 투영
    /// (primary=5시간 창, secondary=주간 창. 네트워크 0).
    public func usageSnapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: primary?.usedPercent,
                      fiveHourResetsAt: primary?.resetsAt,
                      sevenDayPercent: secondary?.usedPercent,
                      sevenDayResetsAt: secondary?.resetsAt,
                      fetchedAt: fetchedAt)
    }
}

/// codex 세션 로그 한 줄에서 rate_limits 상태를 찾는다.
public enum CodexRateLimitParser {
    /// - Parameter line: rollout 로그 한 줄 (JSON 객체 기대). 시각 판단은
    ///   라인 자신의 timestamp를 상태에 실어 호출측이 한다.
    public static func parse(line: String) -> CodexRateLimitStatus? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        return CodexRateLimitStatus(
            primary: window(rateLimits["primary"] as? [String: Any]),
            secondary: window(rateLimits["secondary"] as? [String: Any]),
            reachedType: rateLimits["rate_limit_reached_type"] as? String,
            timestamp: RateLimitParser.timestamp(from: obj))
    }

    static func window(_ dict: [String: Any]?) -> CodexRateLimitStatus.Window? {
        guard let dict, let pct = dict["used_percent"] as? Double else { return nil }
        return CodexRateLimitStatus.Window(usedPercent: pct,
                                           windowMinutes: dict["window_minutes"] as? Int,
                                           resetsAt: (dict["resets_at"] as? Double)
                                               .map(dateFromEpochSecondsOrMillis))
    }
}

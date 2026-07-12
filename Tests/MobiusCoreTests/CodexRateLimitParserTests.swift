import XCTest
@testable import MobiusCore

final class CodexRateLimitParserTests: XCTestCase {

    /// 실측 라인(2026-07-12, codex-cli 0.144.1) — 값만 단순화, 구조는 그대로.
    func realLine(primaryPct: Double = 64.0, secondaryPct: Double = 82.0,
                  reached: String = "null") -> String {
        #"""
        {"timestamp":"2026-07-12T09:07:14.309Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":486875,"cached_input_tokens":412288,"output_tokens":2660,"reasoning_output_tokens":336,"total_tokens":489535},"last_token_usage":{"input_tokens":88304,"cached_input_tokens":86912,"output_tokens":662,"reasoning_output_tokens":101,"total_tokens":88966},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\#(primaryPct),"window_minutes":300,"resets_at":1783861033},"secondary":{"used_percent":\#(secondaryPct),"window_minutes":10080,"resets_at":1784354513},"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":\#(reached)}}}
        """#
    }

    func testParsesRealTokenCountLine() throws {
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: realLine()))
        XCTAssertEqual(status.primary?.usedPercent, 64.0)
        XCTAssertEqual(status.primary?.windowMinutes, 300)
        XCTAssertEqual(status.primary?.resetsAt, Date(timeIntervalSince1970: 1_783_861_033))
        XCTAssertEqual(status.secondary?.usedPercent, 82.0)
        XCTAssertEqual(status.secondary?.windowMinutes, 10080)
        XCTAssertNil(status.reachedType)
        XCTAssertEqual(status.timestamp,
                       RateLimitParser.isoFractional.date(from: "2026-07-12T09:07:14.309Z"))
        // 소진 아님
        XCTAssertNil(status.exhaustionHit())
        // 게이지 투영
        let usage = status.usageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(usage.fiveHourPercent, 64.0)
        XCTAssertEqual(usage.sevenDayPercent, 82.0)
        XCTAssertEqual(usage.sevenDayResetsAt, Date(timeIntervalSince1970: 1_784_354_513))
    }

    func testIgnoresLinesWithoutRateLimits() {
        XCTAssertNil(CodexRateLimitParser.parse(
            line: #"{"timestamp":"2026-07-12T09:00:00Z","type":"response_item","payload":{"type":"message"}}"#))
        XCTAssertNil(CodexRateLimitParser.parse(line: "not json at all"))
        XCTAssertNil(CodexRateLimitParser.parse(line: #"{"payload":{}}"#))
    }

    // MARK: 소진 판정

    func testUsedPercent100TriggersExhaustion() throws {
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: realLine(primaryPct: 100.0)))
        let hit = try XCTUnwrap(status.exhaustionHit())
        // primary 창만 소진 → 그 창의 리셋 시각
        XCTAssertEqual(hit.resetsAt, Date(timeIntervalSince1970: 1_783_861_033))
    }

    func testBothWindowsExhaustedUsesLatestReset() throws {
        let status = try XCTUnwrap(CodexRateLimitParser.parse(
            line: realLine(primaryPct: 100.0, secondaryPct: 100.0)))
        // 주간 창이 소진이면 5시간 창이 리셋돼도 소용없다 — 늦은 쪽
        XCTAssertEqual(status.exhaustionHit()?.resetsAt,
                       Date(timeIntervalSince1970: 1_784_354_513))
    }

    func testReachedTypeNamingWindowTriggersExhaustion() throws {
        // 서버 명시가 있으면 used_percent가 100 미만이어도 소진
        let status = try XCTUnwrap(CodexRateLimitParser.parse(
            line: realLine(primaryPct: 97.0, reached: #""secondary""#)))
        XCTAssertEqual(status.reachedType, "secondary")
        XCTAssertEqual(status.exhaustionHit()?.resetsAt,
                       Date(timeIntervalSince1970: 1_784_354_513)) // secondary의 리셋
    }

    func testReachedTypeUnknownFallsBackToPrimaryReset() throws {
        // 창 이름을 못 읽는 미래 변형 → 가장 짧은 잠금(primary 리셋)으로 보수적 처리
        let status = try XCTUnwrap(CodexRateLimitParser.parse(
            line: realLine(reached: #""some_future_kind""#)))
        XCTAssertEqual(status.exhaustionHit()?.resetsAt,
                       Date(timeIntervalSince1970: 1_783_861_033))
    }

    func testMillisecondEpochDefensivelyHandled() throws {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1783861033000}}}}"#
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: line))
        XCTAssertEqual(status.primary?.resetsAt, Date(timeIntervalSince1970: 1_783_861_033))
        XCTAssertNil(status.secondary)
    }
}

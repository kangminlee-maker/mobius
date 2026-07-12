import XCTest
@testable import MobiusCore

final class UsageFetcherTests: XCTestCase {
    // 실측 응답(2026-07-11) 축약본
    let sample = #"""
    {
     "five_hour": {"utilization": 42.0, "resets_at": "2026-07-10T19:09:59.895133+00:00"},
     "seven_day": {"utilization": 33.0, "resets_at": "2026-07-12T22:59:59.895158+00:00"},
     "extra_usage": {"is_enabled": true}
    }
    """#

    func testParseRealSchema() throws {
        let snap = try XCTUnwrap(UsageFetcher.parse(Data(sample.utf8)))
        XCTAssertEqual(snap.fiveHourPercent, 42.0)
        XCTAssertEqual(snap.sevenDayPercent, 33.0)
        // 마이크로초 fractional seconds 파싱 확인
        let expected = ISO8601DateFormatter()
        XCTAssertEqual(Int(snap.fiveHourResetsAt!.timeIntervalSince1970),
                       Int(expected.date(from: "2026-07-10T19:09:59+00:00")!.timeIntervalSince1970))
        XCTAssertNotNil(snap.sevenDayResetsAt)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(UsageFetcher.parse(Data("not json".utf8)))
        XCTAssertNil(UsageFetcher.parse(Data(#"{"unrelated": 1}"#.utf8)))
    }

    func testAccessTokenExtraction() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(UsageFetcher.accessToken(from: blob), "tok-123")
        XCTAssertNil(UsageFetcher.accessToken(from: Data("{}".utf8)))
    }

    func testParsesScopedModelLimit() {
        let json = Data(#"""
        {"five_hour":{"utilization":47},"seven_day":{"utilization":72,"resets_at":"2026-07-12T23:00:00.000+00:00"},
         "limits":[
           {"kind":"session","group":"session","percent":47},
           {"kind":"weekly_all","group":"weekly","percent":72},
           {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical",
            "resets_at":"2026-07-12T23:00:00.000+00:00","scope":{"model":{"display_name":"Fable"}}}
         ]}
        """#.utf8)
        let snap = UsageFetcher.parse(json)
        XCTAssertEqual(snap?.scopedLimits?.count, 1)
        XCTAssertEqual(snap?.scopedLimits?.first?.label, "Fable")
        XCTAssertEqual(snap?.scopedLimits?.first?.percent, 100)
        XCTAssertNotNil(snap?.scopedLimits?.first?.resetsAt)
    }

    func testOldCacheWithoutScopedDecodes() throws {
        // 구버전 캐시(scopedLimits 키 없음)도 디코드되어야 한다
        let old = Data(#"{"fiveHourPercent":10,"sevenDayPercent":20,"fetchedAt":0}"#.utf8)
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: old)
        XCTAssertEqual(snap.fiveHourPercent, 10)
        XCTAssertNil(snap.scopedLimits)
    }

    func testExhaustionHitMirrorsCodexSemantics() {
        let now = Date(timeIntervalSince1970: 1_784_300_000)
        let fiveReset = now.addingTimeInterval(3600)
        let weekReset = now.addingTimeInterval(86_400)
        func snap(_ five: Double?, _ week: Double?) -> UsageSnapshot {
            UsageSnapshot(fiveHourPercent: five, fiveHourResetsAt: five != nil ? fiveReset : nil,
                          sevenDayPercent: week, sevenDayResetsAt: week != nil ? weekReset : nil,
                          fetchedAt: now)
        }
        // 창 여유 → 소진 아님 (monthly spend만 도달한 상황)
        XCTAssertNil(snap(40, 39).exhaustionHit(now: now))
        // 5시간 창 소진 → 그 창의 리셋 시각
        XCTAssertEqual(snap(100, 39).exhaustionHit(now: now), RateLimitHit(resetsAt: fiveReset))
        // 둘 다 소진 → 더 늦은 주간 리셋 시각
        XCTAssertEqual(snap(100, 100).exhaustionHit(now: now), RateLimitHit(resetsAt: weekReset))
        // 100%지만 리셋 시각이 이미 지남 → 소진 아님 (낡은 스냅샷 방어)
        let stale = UsageSnapshot(fiveHourPercent: 100,
                                  fiveHourResetsAt: now.addingTimeInterval(-60),
                                  sevenDayPercent: 10, sevenDayResetsAt: weekReset, fetchedAt: now)
        XCTAssertNil(stale.exhaustionHit(now: now))
    }

    func testExpiresAtParsing() {
        // 실측: claudeAiOauth.expiresAt는 13자리 epoch 밀리초 (2026-07-11 확인)
        let ms = Data(#"{"claudeAiOauth":{"expiresAt":1783785648000}}"#.utf8)
        XCTAssertEqual(UsageFetcher.expiresAt(from: ms),
                       Date(timeIntervalSince1970: 1_783_785_648))
        let secs = Data(#"{"expiresAt":1783785648}"#.utf8) // 방어: 초 단위도 허용
        XCTAssertEqual(UsageFetcher.expiresAt(from: secs),
                       Date(timeIntervalSince1970: 1_783_785_648))
        XCTAssertNil(UsageFetcher.expiresAt(from: Data("{}".utf8)))
    }
}

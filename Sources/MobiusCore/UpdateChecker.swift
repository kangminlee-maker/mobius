import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public var version: String // "0.1.6" (태그의 v 접두어 제거)
    public var url: String     // 릴리스 페이지 html_url

    public init(version: String, url: String) {
        self.version = version; self.url = url
    }
}

/// GitHub Releases에서 최신 버전 확인. 인증 불필요(공개 레포), 하루 1회 + 수동 버튼만
/// 호출하므로 비인증 rate limit(시간당 60회)에 전혀 걸리지 않는다.
public enum UpdateChecker {
    public static let latestURL =
        URL(string: "https://api.github.com/repos/chussum/mobius/releases/latest")!

    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !v.isEmpty else { return nil }
        return ReleaseInfo(version: v, url: html)
    }

    /// 숫자 세그먼트 비교 — "0.1.10"이 "0.1.5"보다 최신임을 올바르게 판정한다
    /// (문자열 비교는 "0.1.10" < "0.1.5"로 오판).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func fetchLatest() async throws -> ReleaseInfo? {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}

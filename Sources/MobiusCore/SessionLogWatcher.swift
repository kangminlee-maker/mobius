import Foundation

/// ~/.claude/projects/**/*.jsonl 을 주기 스캔해 "새로 추가된" rate-limit 이벤트만 돌려준다.
/// 네트워크 요청 없음. 앱/CLI 어느 쪽에서든 타이머로 scan()을 호출한다.
/// 첫 스캔에서는 기존 내용을 파싱하지 않고 오프셋만 기록한다 (과거 이벤트로 오탐 방지).
public final class SessionLogWatcher: @unchecked Sendable {
    let env: MobiusEnvironment
    private var offsets: [String: UInt64] = [:]   // 파일 경로 → 읽은 위치
    private var primed = false                    // 첫 스캔 여부
    private let lock = NSLock()
    /// 이 시간 안에 수정된 파일만 본다
    public var recentWindow: TimeInterval = 600

    public init(env: MobiusEnvironment) { self.env = env }

    public func scan(now: Date = Date()) -> [RateLimitHit] {
        lock.lock(); defer { lock.unlock() }
        var hits: [RateLimitHit] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: env.projectsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard mtime > now.addingTimeInterval(-recentWindow) || offsets[url.path] == nil else {
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            // 첫 스캔 이후 새로 나타난 파일은 전체가 "새 내용" (start=0)
            let start = offsets[url.path] ?? 0
            offsets[url.path] = end
            // 첫 스캔이거나 파일이 잘렸으면(로테이션) 오프셋만 갱신하고 내용은 건너뜀
            guard primed, start < end else { continue }
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(end - start)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let hit = RateLimitParser.parse(line: String(line), now: now) {
                    hits.append(hit)
                }
            }
        }
        primed = true
        return hits
    }
}

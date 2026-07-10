import SwiftUI

struct MenuBarLabel: View {
    let status: MenuStatus

    var dotColor: Color? {
        switch status {
        case .primaryActive: return nil       // 기본 상태는 점 없음(깔끔)
        case .fallbackActive: return .orange
        case .allExhausted: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        // 메뉴바는 템플릿 이미지가 관례 — ∞ 심볼 + 상태 점
        Image(systemName: dotColor == nil ? "infinity" : "infinity.circle.fill")
            .symbolRenderingMode(dotColor == nil ? .monochrome : .palette)
            .foregroundStyle(dotColor ?? .primary, .primary)
    }
}

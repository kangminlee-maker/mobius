import AppKit
import SwiftUI
import Combine
import MobiusCore

struct AccountListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @Namespace private var cardSpace

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                header
                if state.file.accounts.isEmpty {
                    emptyView
                } else {
                    cards
                }
                footer
            }
            .padding(14)
            .disabled(state.desktopCapture != nil)
            .blur(radius: state.desktopCapture != nil ? 2 : 0)
            // Desktop 연결 가이드 — 팝오버가 닫혔다 열려도 진행 상태가 이어진다
            if state.desktopCapture != nil {
                DesktopCaptureSheet()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: state.desktopCapture)
        .frame(width: 410)
        .onReceive(clock) { now = $0 }
        .onAppear { state.reload(); state.refreshUsageIfStale(); now = Date() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "infinity")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
            Text("Mobius").font(.system(size: 14, weight: .bold, design: .rounded))
            Text(loc("뫼비우스")).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var providersWithAccounts: [Provider] {
        Provider.allCases.filter { !state.file.accounts(of: $0).isEmpty }
    }

    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(providersWithAccounts, id: \.self) { provider in
                providerSection(provider)
            }
        }
    }

    @ViewBuilder private func providerSection(_ provider: Provider) -> some View {
        let accounts = state.file.accounts(of: provider)
        VStack(spacing: 6) {
            if providersWithAccounts.count > 1 {
                HStack {
                    Text(provider.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // primary (고정)
            if let primary = accounts.first {
                card(primary, isPrimary: true)
            }
            // fallbacks (풀 내 DnD 재정렬)
            let fallbacks = Array(accounts.dropFirst())
            if !fallbacks.isEmpty {
                List {
                    ForEach(fallbacks, id: \.id) { p in
                        card(p, isPrimary: false)
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { state.moveFallback(provider: provider, from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: fallbacks.reduce(CGFloat(0)) { sum, p in
                    sum + AccountCardView.estimatedHeight(hasUsage: usageFor(p) != nil)
                })
            }
        }
    }

    private func usageFor(_ p: AccountProfile) -> UsageSnapshot? {
        showUsageGauges ? state.usage[p.id] : nil
    }

    private func isActive(_ p: AccountProfile) -> Bool {
        p.id == state.file.activeByProvider[p.provider]
    }

    private func card(_ p: AccountProfile, isPrimary: Bool) -> some View {
        // Desktop 연결·재로그인 플로우는 Claude 전용 (Codex 재로그인 감지는 미배선)
        let claudeCard = p.provider == .claude
        return AccountCardView(profile: p, isActive: isActive(p),
                        isPrimary: isPrimary,
                        autoSwitchOn: state.file.isAutoSwitchEnabled(p.provider),
                        usage: usageFor(p), now: now,
                        onConnectDesktop: claudeCard && state.desktopSwitcher.isDesktopInstalled
                            ? { state.beginDesktopCapture(for: p.id) } : nil,
                        onDelete: { state.removeAccount(p.id) },
                        onSetPrimary: isPrimary ? nil : {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                state.setPrimary(p.id)
                            }
                        },
                        onReauth: p.needsReauth && claudeCard ? { state.addAccount() } : nil)
            .matchedGeometryEffect(id: p.id, in: cardSpace)
            .onTapGesture {
                guard !isActive(p) else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    state.manualSwitch(to: p.id)
                }
            }
            .contextMenu {
                if p.needsReauth && claudeCard {
                    Button(loc("다시 로그인")) { state.addAccount() }
                }
                if !isPrimary {
                    Button(loc("Primary 계정으로 설정")) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            state.setPrimary(p.id)
                        }
                    }
                }
                if claudeCard {
                    Button(p.hasDesktopSnapshot ? loc("Claude Desktop 다시 연결") : loc("Claude Desktop 연결")) {
                        state.beginDesktopCapture(for: p.id)
                    }
                }
                Button(loc("삭제"), role: .destructive) { state.removeAccount(p.id) }
            }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "infinity").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(loc("등록된 계정이 없습니다")).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(loc("설정(⚙)의 설치 현황에서 계정을 추가하세요"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            if let err = state.lastError {
                Text(err).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            // SettingsLink는 accessory(메뉴바 전용) 앱에서 창을 활성화하지 못해 무반응 —
            // 앱을 먼저 활성화한 뒤 openSettings 환경 액션으로 연다
            footerButton("gearshape", help: loc("설정")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            footerButton("power", help: loc("종료")) { NSApp.terminate(nil) }
        }
    }

    /// footer 아이콘 버튼 — 아이콘보다 넓은 히트 영역(28pt)으로 누르기 쉽게
    private func footerButton(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(help)
    }
}

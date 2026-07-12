import SwiftUI
import ServiceManagement
import MobiusCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var cliMessage = ""
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @State private var claudeInfo: ClaudeCLI.Info?
    @State private var codexInfo: ToolInventory.CLIInfo?
    @State private var claudeDesktop: ToolInventory.AppInfo?
    @State private var chatGPTApp: ToolInventory.AppInfo?
    @State private var toolsChecked = false
    @State private var installingClaude = false
    @State private var claudeInstallMessage = ""
    @State private var mobiusPaths: [String] = []
    @State private var mobiusChecked = false

    var body: some View {
        settingsForm
            // 설정창이 떠 있는 동안만 Dock에 아이콘 표시, 닫으면 메뉴바 전용으로 복귀
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                checkTools()
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: 설치 현황

    /// CLI 감지는 로그인 셸 호출이라 느리다(수백 ms) — 백그라운드에서 확인.
    /// 앱 번들 조회(LaunchServices)와 mobius 경로 확인은 빨라서 메인에서 바로.
    private func checkTools() {
        claudeDesktop = ToolInventory.appBundle(bundleID: "com.anthropic.claudefordesktop")
        chatGPTApp = ToolInventory.appBundle(bundleID: "com.openai.codex")
        refreshMobius()
        Task {
            let (claude, codex) = await Task.detached {
                (ClaudeCLI.locate(), ToolInventory.locateCodexCLI())
            }.value
            await MainActor.run {
                claudeInfo = claude
                codexInfo = codex
                toolsChecked = true
            }
        }
    }

    private func refreshMobius() {
        mobiusPaths = ToolInventory.mobiusInstallations()
        mobiusChecked = true
    }

    /// 공통 상태 행: [상태 아이콘] 이름 · 버전 / 경로
    @ViewBuilder private func toolRow(_ name: String, path: String?, version: String?) -> some View {
        HStack(spacing: 8) {
            if let path {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let version, !version.isEmpty {
                            Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(path).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if !toolsChecked {
                ProgressView().controlSize(.small)
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(loc("확인 중…")).font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(loc("설치 안 됨")).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    /// Claude Code CLI 행 — 미설치면 공식 스크립트 설치 버튼을 함께 노출
    /// (계정 추가가 이 CLI에 의존하므로 설치 수단은 유지한다).
    @ViewBuilder private var claudeCLIRow: some View {
        toolRow("Claude Code CLI", path: claudeInfo?.path, version: claudeInfo?.version)
        if toolsChecked, claudeInfo == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("Mobius는 Claude Code CLI로 계정을 로그인·전환합니다. 아래 버튼으로 공식 설치 스크립트를 실행하세요 (관리자 권한 불필요)."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        installClaude()
                    } label: {
                        if installingClaude {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loc("설치 중…")) }
                        } else { Text(loc("Claude Code 설치")) }
                    }
                    .disabled(installingClaude)
                    Spacer()
                }
                if !claudeInstallMessage.isEmpty {
                    Text(claudeInstallMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func installClaude() {
        installingClaude = true
        claudeInstallMessage = loc("설치 스크립트를 내려받아 실행 중입니다… (최대 1~2분)")
        Task {
            let err = await ClaudeCLI.install()
            let info = ClaudeCLI.locate()
            await MainActor.run {
                installingClaude = false
                claudeInfo = info
                claudeInstallMessage = err ?? loc("설치 완료! 이제 계정을 추가할 수 있어요.")
            }
        }
    }

    /// CLI별 자동 전환 토글 + 등록 계정 요약 — 설치 현황의 Claude/Codex 블록 공용.
    /// 계정 추가 진입점: Claude는 로그인 플로우 버튼, Codex는 터미널 안내(adopt 방식).
    @ViewBuilder private func poolControls(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(loc("자동 전환"), isOn: Binding(
                get: { state.file.isAutoSwitchEnabled(provider) },
                set: { state.setAutoSwitch($0, provider: provider) }))
            Text(loc("한도가 차면 다음 계정으로 자동으로 이어집니다"))
                .font(.caption).foregroundStyle(.secondary)
        }
        let accounts = state.file.accounts(of: provider)
        VStack(alignment: .leading, spacing: 4) {
            if accounts.isEmpty {
                Text(loc("등록된 계정이 없습니다"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.id) { p in
                HStack(spacing: 6) {
                    Circle()
                        .fill(p.id == state.file.activeByProvider[provider]
                              ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 5, height: 5)
                    Text(p.nickname).font(.system(size: 11, weight: .medium))
                    Text(p.emailAddress).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            switch provider {
            case .claude:
                Button(loc("계정 추가")) { state.addAccount() }
                    .controlSize(.small).padding(.top, 2)
            case .codex:
                Text(loc("터미널에서 `codex logout` 후 `codex login`으로 추가할 계정에 로그인하면, Mobius가 몇 초 안에 자동으로 등록합니다."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                Text(loc("지금 쓰던 계정은 이미 카드에 저장돼 있어 카드를 눌러 언제든 되돌아올 수 있어요."))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// mobius CLI 행 (일반 섹션) — 설치 상태 pill + 설치/재설치/삭제
    @ViewBuilder private var mobiusCLIRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("mobius CLI")
                    statusPill(installed: !mobiusPaths.isEmpty)
                }
                if !mobiusPaths.isEmpty {
                    Text(mobiusPaths.joined(separator: "  ·  "))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if mobiusChecked {
                if mobiusPaths.isEmpty {
                    Button(loc("설치")) { installMobius() }
                } else {
                    Button(loc("재설치")) { reinstallMobius() }
                    Button(loc("삭제"), role: .destructive) { uninstallMobius() }
                }
            }
        }
        if !cliMessage.isEmpty {
            Text(cliMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 설치 상태 pill — AccountCardView의 PRIMARY 캡슐과 같은 스타일
    private func statusPill(installed: Bool) -> some View {
        let color: Color = installed ? .green : .orange
        return Text(installed ? loc("설치됨") : loc("미설치"))
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// fallback이 없는 상태 = 어느 프로바이더 풀에도 계정이 2개 이상 없다.
    /// 전체 수로 세면 Claude 1개 + Codex 1개일 때 안내가 사라지는데, 그 상태는
    /// 여전히 어떤 풀도 자동 전환이 불가능하다.
    private var needsFallbackOnboarding: Bool {
        !Provider.allCases.contains { state.file.accounts(of: $0).count >= 2 }
    }

    private var settingsForm: some View {
        Form {
            if needsFallbackOnboarding {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(state.file.accounts.isEmpty
                              ? loc("아직 등록된 계정이 없어요")
                              : loc("Fallback 계정을 추가해 보세요"),
                              systemImage: "infinity")
                            .font(.system(size: 13, weight: .semibold))
                        Text(.init(state.file.accounts.isEmpty
                             ? loc("아래 **설치 현황**의 **계정 추가** 버튼으로 Claude 계정을 등록하세요. 개인·회사 계정을 함께 등록해 두면, 한 계정의 사용량이 차는 순간 다음 계정으로 알아서 전환됩니다.")
                             : loc("지금은 계정이 하나뿐이라 사용량이 차면 기다리는 수밖에 없어요. 아래 **설치 현황**의 **계정 추가**로 계정을 하나 더 등록하면, 한도가 차는 순간 자동으로 이어서 쓸 수 있습니다.")))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section(loc("일반")) {
                Picker(loc("언어"), selection: Binding(
                    get: { L10n.current },
                    set: { L10n.setLanguage($0); state.objectWillChange.send() })) {
                    Text(loc("시스템 기본")).tag("system")
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                Toggle(loc("로그인 시 자동 시작"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { cliMessage = loc("실패: %@", error.localizedDescription) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(loc("사용량 게이지 표시"), isOn: $showUsageGauges)
                    Text(loc("계정 카드에 5시간·주간 사용량과 초기화 남은 시간을 표시합니다"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                mobiusCLIRow
            }
            Section(loc("설치 현황")) {
                VStack(alignment: .leading, spacing: 10) {
                    claudeCLIRow
                    poolControls(.claude)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 10) {
                    toolRow("Codex CLI", path: codexInfo?.path, version: codexInfo?.version)
                    poolControls(.codex)
                }
                .padding(.vertical, 2)
                toolRow("Claude Desktop", path: claudeDesktop?.path, version: claudeDesktop?.version)
                // 동명의 "ChatGPT" 앱이 둘일 수 있어(구형 com.openai.chat) 번들 ID
                // com.openai.codex(Codex 데스크톱)만 대상으로 감지한다.
                toolRow("ChatGPT", path: chatGPTApp?.path, version: chatGPTApp?.version)
            }
            Section("Experimental") {
                Toggle(loc("계정 전환 시 Claude Desktop도 전환"), isOn: Binding(
                    get: { state.file.desktopSyncEnabled },
                    set: { state.setDesktopSync($0) }))
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(loc("자동 전환 시에도 Claude Desktop 전환"), isOn: Binding(
                        get: { state.file.desktopAutoSwitchEnabled },
                        set: { state.setDesktopAutoSwitch($0) }))
                    Text(loc("자동 전환 시 Claude Desktop이 종료 후 재실행됩니다"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(loc("한도 초기화 확정 (최소 호출)"), isOn: Binding(
                        get: { state.file.resetProbeEnabled },
                        set: { state.setResetProbe($0) }))
                    Text(loc("초기화된 계정에 최소한의 호출 1회를 보내 다음 초기화 시점을 확정하고 알림으로 알려줍니다. 호출은 소량의 사용량을 소비합니다."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: needsFallbackOnboarding ? 700 : 560)
    }

    // MARK: mobius 명령어 설치/재설치/삭제

    private var bundledMobiusPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "mobius")?.path
    }

    private func installMobius() {
        // 신규 설치는 /usr/local/bin/mobius 심볼릭 링크 (osascript로 관리자 권한)
        applyMobius(paths: ["/usr/local/bin/mobius"], action: .install)
    }

    private func reinstallMobius() {
        // 발견된 모든 위치의 심링크를 현재 번들 기준으로 재생성 (낡은 대상 교정)
        applyMobius(paths: mobiusPaths, action: .install)
    }

    private func uninstallMobius() {
        applyMobius(paths: mobiusPaths, action: .remove)
    }

    private enum MobiusCLIAction { case install, remove }

    /// 홈 아래 경로는 FileManager로 직접, /usr/local 등은 osascript 관리자 권한으로 처리.
    private func applyMobius(paths: [String], action: MobiusCLIAction) {
        guard !paths.isEmpty else { return }
        let src: String?
        if action == .install {
            guard let bundled = bundledMobiusPath else {
                cliMessage = loc("번들에서 mobius 바이너리를 찾을 수 없습니다 (개발 빌드에서는 Scripts/install-cli.sh 사용)")
                return
            }
            src = bundled
        } else {
            src = nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userPaths = paths.filter { $0.hasPrefix(home) }
        let adminPaths = paths.filter { !$0.hasPrefix(home) }
        var errors: [String] = []

        for path in userPaths {
            do {
                try? FileManager.default.removeItem(atPath: path)
                if let src {
                    try FileManager.default.createSymbolicLink(atPath: path,
                                                               withDestinationPath: src)
                }
            } catch { errors.append("\(path): \(error.localizedDescription)") }
        }

        if !adminPaths.isEmpty {
            let commands = adminPaths.map { path in
                if let src { return "ln -sf \(shellQuoted(src)) \(shellQuoted(path))" }
                return "rm -f \(shellQuoted(path))"
            }
            let command = (src != nil ? ["mkdir -p /usr/local/bin"] : []) + commands
            let script = "do shell script \(appleScriptQuoted(command.joined(separator: " && "))) with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                errors.append(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
            }
        }

        refreshMobius()
        if let first = errors.first {
            cliMessage = loc(action == .install ? "설치 실패: %@" : "삭제 실패: %@", first)
        } else if action == .install {
            cliMessage = loc("설치 완료: %@", paths.joined(separator: ", "))
        } else {
            cliMessage = loc("삭제 완료")
        }
    }

    /// POSIX shell 단일 인용 — `'` → `'\''` 로 어떤 경로도 안전하게.
    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 문자열 리터럴 — `\`와 `"` 이스케이프.
    private func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

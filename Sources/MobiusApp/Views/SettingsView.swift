import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var cliMessage = ""

    var body: some View {
        Form {
            Section("일반") {
                Toggle("로그인 시 자동 시작", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { cliMessage = "실패: \(error.localizedDescription)" }
                    }
                Toggle("CLI 자동 fallback", isOn: Binding(
                    get: { state.file.autoSwitchEnabled },
                    set: { state.setAutoSwitch($0) }))
            }
            Section("CLI") {
                HStack {
                    Text("`mobius` 명령어 설치")
                    Spacer()
                    Button("설치") { installCLI() }
                }
                if !cliMessage.isEmpty {
                    Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 260)
    }

    private func installCLI() {
        // 번들 내 mobius 바이너리 → /usr/local/bin 심볼릭 링크 (osascript로 관리자 권한)
        guard let src = Bundle.main.url(forAuxiliaryExecutable: "mobius")?.path else {
            cliMessage = "번들에서 mobius 바이너리를 찾을 수 없습니다 (개발 빌드에서는 Scripts/install-cli.sh 사용)"
            return
        }
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(src)' /usr/local/bin/mobius\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        cliMessage = error == nil ? "설치 완료: /usr/local/bin/mobius" : "설치 실패"
    }
}

import AppKit
import SwiftUI
import MobiusCore

@main
struct MobiusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            AccountListView().environmentObject(state)
        } label: {
            MenuBarLabel(status: state.menuStatus)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Dock 아이콘 없음, 메뉴바 전용
    }
}

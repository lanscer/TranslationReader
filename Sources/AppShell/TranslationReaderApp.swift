import SwiftUI
import AppKit

// 菜单栏常驻入口：LSUIElement=1 由 Info.plist 保证无 Dock 图标（文档 §3.6 §8）。
@main
struct TranslationReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        _ = LaunchClock.start
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image(systemName: "character.book.closed")
        }
        .menuBarExtraStyle(.menu)
    }
}

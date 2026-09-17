import AppKit
import SwiftUI

@main
struct LiteMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("LiteMD", id: MainWindowView.windowID) {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: Layout.defaultWindowWidth, height: Layout.defaultWindowHeight)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            LiteMDCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, .interface)
                .environment(\.colorTheme, model.settings.activeTheme)
                .tint(Color.themeAccent(model.settings.activeTheme))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            await AppModel.shared.open(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared.openMainWindow?()
        }
        return true
    }

    /// 当前进程退出后重新打开应用。
    private static func scheduleRelaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundlePath]
        try? process.run()
    }

    /// 退出前等待所有保存完成（spec §184：不能有数据丢失）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let model = AppModel.shared
            let approved = await model.prepareForTermination()
            if !approved, !sender.windows.contains(where: \.isVisible) {
                model.openMainWindow?()
            }
            if approved, model.updates.preparedApplication != nil {
                model.updates.scheduleInstallation()
            } else if approved, model.isRelaunchRequested {
                Self.scheduleRelaunch()
            }
            model.isRelaunchRequested = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }
}

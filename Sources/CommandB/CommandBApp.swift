import AppKit

// 用 NSApplication 直接启动，不挂 SwiftUI 的 Settings 场景——
// 该场景在启动时会自动弹出设置窗（含登录项开机自启），这正是要修的行为。
// 设置页由 AppDelegate.openSettings() 按需展示。
@main
struct CommandBEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        // 激活策略必须在 run() 之前定；放在 didFinishLaunching 里切换会
        // 取消 LaunchServices 的激活请求，导致手动打开也拿不到 isActive。
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

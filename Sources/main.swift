import AppKit

@main
struct LaunchpadMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // accessory：app 不参与「当前应用」竞争。
        // 台前调度下一旦本 app 成为 active app，系统会把原本在中央的其它程序
        // 收进左侧「最近应用」栏。nonactivatingPanel 只保证窗口成为 key 时不
        // 激活 app，挡不住点 Dock 图标 / open -a 时 LaunchServices 的显式激活，
        // 所以必须在 app 层面彻底退出前台竞争（Spotlight 也是这个模式）。
        // 代价：没有 Dock 图标；打开入口为 Finder 双击 / open -a / 分布式通知 /
        // 全局四指捏合 / 菜单栏图标。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

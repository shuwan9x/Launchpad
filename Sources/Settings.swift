import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let launchpadSettingsChanged = Notification.Name("launchpadSettingsChanged")
}

/// 全局设置，持久化到 UserDefaults
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let d = UserDefaults.standard
    /// 初始化完成前不写 LaunchAgent，避免控件初始化时的误触发
    private var ready = false

    /// 液态玻璃强度 0...1（变化要通知 AppDelegate 更新官方 NSGlassEffectView）
    @Published var glassIntensity: Double { didSet { persist(); notify() } }
    /// 果冻弹性强度 0...1
    @Published var jellyStrength: Double { didSet { persist() } }
    /// 图标大小固定 80pt，不提供自定义（老 Launchpad 行为）
    let iconSize: Double = 80
    /// 窗口置顶
    @Published var alwaysOnTop: Bool { didSet { persist(); notify() } }
    /// 开机自动启动
    @Published var launchAtLogin: Bool { didSet { persist(); applyLoginItem() } }
    /// 显示分类栏
    @Published var showCategories: Bool { didSet { persist() } }
    /// 多页显示（false = 单页显示全部应用，可滚动）
    @Published var multiPage: Bool { didSet { persist() } }
    /// 点击窗口外自动隐藏
    @Published var autoHideOnOutsideClick: Bool { didSet { persist() } }
    private init() {
        glassIntensity  = d.object(forKey: "glassIntensity")  as? Double ?? 0.62
        jellyStrength   = d.object(forKey: "jellyStrength")   as? Double ?? 0.70
        alwaysOnTop     = d.object(forKey: "alwaysOnTop")     as? Bool   ?? true
        launchAtLogin   = d.object(forKey: "launchAtLogin")   as? Bool   ?? false
        showCategories  = d.object(forKey: "showCategories")  as? Bool   ?? true
        multiPage       = d.object(forKey: "multiPage")       as? Bool   ?? true
        autoHideOnOutsideClick = d.object(forKey: "autoHideOnOutsideClick") as? Bool ?? true
        // 以 LaunchAgent 的真实存在状态为准，避免 UI 与实际不一致
        launchAtLogin = LoginItemManager.isEnabled
        ready = true
    }

    private func persist() {
        d.set(glassIntensity, forKey: "glassIntensity")
        d.set(jellyStrength, forKey: "jellyStrength")
        d.set(alwaysOnTop, forKey: "alwaysOnTop")
        d.set(launchAtLogin, forKey: "launchAtLogin")
        d.set(showCategories, forKey: "showCategories")
        d.set(multiPage, forKey: "multiPage")
        d.set(autoHideOnOutsideClick, forKey: "autoHideOnOutsideClick")
    }

    private func notify() {
        NotificationCenter.default.post(name: .launchpadSettingsChanged, object: nil)
    }

    private func applyLoginItem() {
        guard ready else { return }
        do {
            try LoginItemManager.setEnabled(launchAtLogin)
        } catch {
            // 回滚 UI 状态，避免显示与实际不一致
            DispatchQueue.main.async { [weak self] in
                self?.launchAtLogin = LoginItemManager.isEnabled
            }
            LoginItemManager.lastError = error.localizedDescription
        }
    }

}

/// 开机自启：写 ~/Library/LaunchAgents plist（不依赖 SMAppService 的签名/安装位置限制）
enum LoginItemManager {
    static let label = "com.local.launchpad.login"
    static var lastError: String?

    static var plistURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ on: Bool) throws {
        lastError = nil
        if on {
            guard Bundle.main.bundlePath.hasSuffix(".app") else {
                throw NSError(domain: "Launchpad", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "需以 .app 方式运行才能设置开机启动"])
            }
            let appPath = Bundle.main.bundlePath
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            // 立即注册（失败不致命，下次登录仍会生效）
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        } else {
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        }
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}

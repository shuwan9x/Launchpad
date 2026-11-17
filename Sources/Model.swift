import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreServices

/// 应用信息模型
struct AppItem: Identifiable, Codable, Hashable {
    let id: String          // 稳定标识 = bundle id 或路径
    var name: String
    var bundleID: String?
    var path: String?       // 可执行文件或 .app 路径
    var isFolder: Bool
    var folderItems: [AppItem]?   // 文件夹内含的应用
    var category: String?   // 分类（开发者工具/工具/效率与财务/社交/娱乐/信息与阅读/创意/其他）

    static func == (lhs: AppItem, rhs: AppItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 启动器布局模型（持久化排序）
struct LayoutStore: Codable {
    var items: [AppItem] = []
    var folderMap: [String: [String]] = [:]   // 文件夹名 -> 应用 id 列表
    var pageOrder: [String] = []              // 顶层顺序（文件夹名 + 应用 id）
}

/// 扫描结果落磁盘缓存：冷启动先读缓存立刻出界面，耗时扫描放到后台
enum AppScanCache {
    private static var url: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.local.launchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("apps.json")
    }

    static func read() -> [AppItem]? {
        guard let d = try? Data(contentsOf: url),
              let a = try? JSONDecoder().decode([AppItem].self, from: d),
              !a.isEmpty else { return nil }
        return a
    }

    static func write(_ apps: [AppItem]) {
        guard let d = try? JSONEncoder().encode(apps) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// 卸载后把该项从缓存里移除，否则下次冷启动读缓存会把它当成「新安装」补回来
    static func remove(id: String) {
        guard let cached = read() else { return }
        write(cached.filter { $0.id != id })
    }
}

final class AppScanner {
    /// 唯一「已安装」位置来源：扫描与卸载判定共用，避免两处口径不一致。
    static let searchRoots: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
    ]

    /// 扫描系统所有应用，返回按名称排序的列表
    static func scanAllApps() -> [AppItem] {
        var seen = Set<String>()
        var apps: [AppItem] = []

        let fm = FileManager.default

        func hasChinese(_ s: String) -> Bool {
            s.range(of: "\\p{Han}", options: .regularExpression) != nil
        }

        /// 系统语言 → loctable 里可能的键（zh-Hans-JP → zh_CN / zh-Hans / zh …）
        func languageKeys(_ lang: String) -> [String] {
            var keys = [lang]
            let parts = lang.split(separator: "-").map(String.init)
            if parts.count >= 2 {
                let base = parts[0], script = parts[1]
                keys.append("\(base)-\(script)")
                if script == "Hans" { keys.append("zh_CN") }
                if script == "Hant" { keys.append("zh_TW"); keys.append("zh_HK") }
                keys.append(base)
            }
            keys.append("en")
            return keys
        }

        /// macOS 新系统把应用名的本地化放在 InfoPlist.loctable，
        /// 而 Bundle.localizedInfoDictionary 在英文进程中只会给英文名。
        func localizedFromLoctable(_ bundle: Bundle) -> String? {
            guard let p = bundle.path(forResource: "InfoPlist", ofType: "loctable"),
                  let dict = NSDictionary(contentsOfFile: p) as? [String: Any] else { return nil }
            let langs =
                (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])
                ?? (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])
                ?? ["en"]
            for lang in langs {
                for key in languageKeys(lang) {
                    if let t = dict[key] as? [String: String],
                       let n = t["CFBundleDisplayName"] ?? t["CFBundleName"],
                       !n.isEmpty { return n }
                }
            }
            return nil
        }

        /// Finder / 访达中「应用程序」显示的名称（Spotlight 元数据，最权威）
        func spotlightDisplayName(path: String) -> String? {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url),
                  let raw = MDItemCopyAttribute(item, kMDItemDisplayName as CFString) as? String,
                  !raw.isEmpty else { return nil }
            return raw.hasSuffix(".app")
                ? (raw as NSString).deletingPathExtension : raw
        }

        /// 名称优先用 Spotlight/Finder 显示名，保证与访达完全一致；
        /// 取不到时才回退到系统 loctable / 文件名。
        func finderName(for bundle: Bundle, path: String) -> String {
            if let n = spotlightDisplayName(path: path) { return n }
            let fileFallback = ((path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            if let n = localizedFromLoctable(bundle) { return n }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let n = bundle.localizedInfoDictionary?[key] as? String,
                   !n.isEmpty { return n }
            }
            if let n = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !n.isEmpty { return n }
            return fileFallback
        }

        func truthy(_ v: Any?) -> Bool {
            if let b = v as? Bool { return b }
            if let s = v as? String { return s == "1" || s.lowercased() == "yes" }
            if let n = v as? NSNumber { return n.boolValue }
            return false
        }

        /// 只保留真正可由用户启动、有界面的应用
        func isLaunchable(_ bundle: Bundle, name: String) -> Bool {
            if let t = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
               t != "APPL" { return false }
            guard let exe = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                  !exe.isEmpty else { return false }
            // 后台 agent / 无 Dock 图标的辅助程序
            if truthy(bundle.object(forInfoDictionaryKey: "LSUIElement")) { return false }
            if truthy(bundle.object(forInfoDictionaryKey: "LSBackgroundOnly")) { return false }
            let low = name.lowercased()
            let blocked = ["uninstall", "helper", "distiller", "daemon",
                           "crash reporter", "diagnostic", "updater",
                           "setup assistant", "installer"]
            for k in blocked where low.contains(k) { return false }
            return true
        }

        func addApp(at full: String) {
            guard let bundle = Bundle(path: full) else { return }
            let fileFallback = ((full as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            guard isLaunchable(bundle, name: fileFallback) else { return }

            let bid = bundle.bundleIdentifier ?? ""
            let key = bid.isEmpty ? full : bid
            if seen.contains(key) { return }
            seen.insert(key)

            let displayName = finderName(for: bundle, path: full)
            apps.append(AppItem(
                id: key,
                name: displayName,
                bundleID: bid.isEmpty ? nil : bid,
                path: full,
                isFolder: false,
                folderItems: nil,
                category: CategoryClassifier.classify(bid, name: displayName)
            ))
        }

        // 递归扫描子目录（Utilities、Setapp、Adobe 等），但不进入 .app 包内部
        func walk(_ root: String, depth: Int) {
            guard depth >= 0,
                  let names = try? fm.contentsOfDirectory(atPath: root) else { return }
            for name in names where !name.hasPrefix(".") {
                let full = (root as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    addApp(at: full)
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        walk(full, depth: depth - 1)
                    }
                }
            }
        }

        // 顺序即去重优先级：用户安装版本 > 主目录 > 系统应用。
        // 不扫 /System/Library/CoreServices 内部工具（AccessibilityUIServer 之类
        // 不是用户可启动的程序，放进启动台只会变乱）。
        let depths = [3, 3, 1]          // 含 Adobe / Setapp 等套件子目录
        for (i, root) in AppScanner.searchRoots.enumerated() {
            walk(root, depth: depths[i])
        }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return apps
    }
}

enum AppLauncher {
    /// 启动应用
    static func launch(_ item: AppItem) {
        if let path = item.path {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let bid = item.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            // 只有 bundleID、没有 path 的项：先解析出真实 .app 再打开。
            // 旧代码写死 /dev/null，这类项根本启动不了。
            NSWorkspace.shared.open(url)
        }
    }
}

/// 根据 bundle id / 名称做启发式分类
enum CategoryClassifier {
    static let categories = ["开发者工具", "工具", "效率与财务", "社交", "娱乐", "信息与阅读", "创意", "其他"]

    static func classify(_ bid: String, name: String) -> String {
        let b = bid.lowercased()
        let n = name.lowercased()

        // 开发者工具
        let devKeywords = ["xcode", "terminal", "developer", "code", "intellij", "pycharm",
                           "webstorm", "datagrip", "android", "simulator", "instruments",
                           "git", "docker", "hbuilderx", "visual studio", "sublime", "vim",
                           "postman", "apipost", "cursor", "codex", "console", "activity monitor"]
        if b.contains("com.apple.dt") || b.contains("com.apple.terminal")
            || b.contains("com.apple.ActivityMonitor") || b.contains("com.apple.Console") {
            return "开发者工具"
        }
        for k in devKeywords where n.contains(k) { return "开发者工具" }

        // 社交
        let social = ["wechat", "weixin", "qq", "dingtalk", "feishu", "lark", "telegram",
                      "whatsapp", "facetime", "messages", "slack", "discord", "imessage"]
        for k in social where n.contains(k) || b.contains(k) { return "社交" }

        // 娱乐
        let ent = ["music", "tv", "podcasts", "games", "chess", "steam", "epic", "arcade",
                   "photo booth", "stocks", "news"]
        for k in ent where n.contains(k) || b.contains(k) { return "娱乐" }

        // 信息与阅读
        let info = ["books", "dictionary", "notes", "news", "safari", "chrome", "firefox",
                    "edge", "font book", "stickies", "mail"]
        for k in info where n.contains(k) || b.contains(k) { return "信息与阅读" }

        // 创意
        let creative = ["photos", "preview", "image", "quicktime", "imovie", "final cut",
                        "garageband", "freeform", "sketch", "figma", "blender", "pages",
                        "numbers", "keynote", "logic"]
        for k in creative where n.contains(k) || b.contains(k) { return "创意" }

        // 效率与财务
        let prod = ["calendar", "calculator", "reminders", "clock", "contacts", "findmy",
                    "wallet", "money", "finance", "bank", "spreadsheet", "excel", "word",
                    "numbers", "to do", "things", "notion", "obsidian", "evernote",
                    "shortcuts", "automator", "textedit", "maps", "weather"]
        for k in prod where n.contains(k) || b.contains(k) { return "效率与财务" }

        // 工具（系统工具等）
        let util = ["system settings", "system information", "disk utility", "activity",
                    "airport", "bluetooth", "color", "digital", "grapher", "keychain",
                    "migration", "screenshot", "script", "voiceover", "print", "scanner",
                    "time machine", "cleaner", "clean", "zip", "bandizip", "unarchiver",
                    "monitor", "to desk", "tailscale", "spacedesk", "utilities", "passwords"]
        for k in util where n.contains(k) || b.contains(k) { return "工具" }

        return "其他"
    }
}

import Foundation
import SwiftUI
import AppKit
import CoreServices

/// 顶层元素：要么是单个应用，要么是文件夹
enum GridItem: Identifiable, Hashable {
    case app(AppItem)
    case folder(name: String, items: [AppItem])

    var id: String {
        switch self {
        case .app(let a): return "app:" + a.id
        case .folder(let name, _): return "folder:" + name
        }
    }

    var name: String {
        switch self {
        case .app(let a): return a.name
        case .folder(let n, _): return n
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// 每页容量 = 7 列 × 4 行，与 GridMetrics 保持单一数据源
let kPageSize = GridMetrics.cols * GridMetrics.rows

/// 全局状态 + 布局持久化
final class LaunchpadStore: ObservableObject {
    @Published var items: [GridItem] = []      // 全局扁平顺序（含文件夹）
    @Published var searchText: String = ""
    @Published var selectedCategory: String? = nil
    @Published var page: Int = 0
    /// 从文件夹拖出图标期间抑制主网格的点击（松手的 mouseUp 会落在目标
    /// 应用 / 文件夹上，不拦就会误开）。
    /// 用「截止时间戳」而不是一次性布尔标记：时间戳到期自动失效，
    /// 万一 mouseUp 没落到网格上，也不会把用户的下一次正常单击永久吞掉。
    /// 普通属性（非 @Published）：只做门闩，不该触发视图重绘。
    var suppressGridTapUntil: Date = .distantPast

    @Published var folders: [String: [String]] = [:]
    @Published var topOrder: [String] = []

    private let allApps: [AppItem]
    /// 布局文件路径。默认落到 Application Support；构造时注入可让回归测试
    /// 写到隔离文件，绝不碰用户真实布局。
    private let layoutFile: URL
    /// layout.json 里保存过、但已不在最新扫描结果中的应用（例如已卸载或
    /// 手工加进文件夹的项）。重建文件夹成员时必须能找回它们，
    /// 否则「拖出一个图标」会把其余成员一起从文件夹里抹掉。
    private var fallbackApps: [String: AppItem] = [:]
    /// 全盘扫描正在进行中，避免窗口反复激活时并发改布局
    private var refreshing = false
    /// 应用目录的实时监听（安装 / 卸载 / 移动 .app 都会触发）
    private var appWatcher: AppDirectoryWatcher?
    /// 布局写盘去抖：拖拽/分类操作会连续调用 save()，合并成一次写。
    /// pendingSave 只在主线程访问；真正的编码+写盘放后台队列。
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.local.launchpad.layout",
                                          qos: .utility)
    private var terminateObserver: NSObjectProtocol?

    init(layoutFile: URL? = nil, apps: [AppItem]? = nil, autoRefresh: Bool = true) {
        // 冷启动优先读磁盘缓存，避免同步扫描 100+ 个应用包拖慢窗口出现
        if let injected = apps {
            allApps = injected
        } else if let cached = AppScanCache.read() {
            allApps = cached
        } else {
            allApps = AppScanner.scanAllApps()
            AppScanCache.write(allApps)
        }
        self.layoutFile = layoutFile ?? LaunchpadStore.defaultLayoutURL()
        for a in allApps { fallbackApps[a.id] = a }
        loadLayout()
        // 后台全盘扫描：卸载的移出布局、新安装的追加到末尾。
        // 扫描放后台，改布局回主线程，不阻塞窗口出现。
        if autoRefresh {
            refreshInstalledApps()
            startWatchingAppDirectories()
        }
        // 退出前把还没到期的去抖写盘立刻落地，避免丢最后一次布局改动
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.flush() }
    }

    deinit {
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        flush()
    }

    /// 订阅 /Applications、~/Applications、/System/Applications 的文件系统事件。
    /// 这样即使启动台一直藏在后台，用户拖进 / 删掉一个 .app，布局也会自动跟上，
    /// 不必等下次点 Dock 图标。
    private func startWatchingAppDirectories() {
        let watcher = AppDirectoryWatcher {
            NotificationCenter.default.post(name: .installedAppsDidChange, object: nil)
        }
        watcher.start()
        appWatcher = watcher
    }

    // MARK: - 安装 / 卸载后刷新布局

    /// 判断某个布局项对应的应用是否仍装在机器上。
    /// 关键：「不在扫描结果里」**不等于**卸载——应用可能只是升级中、被移动到
    /// 别的目录、或暂时扫不到。以前直接按扫描结果过滤，把用户文件夹清空过。
    /// 这里必须路径与 bundle id 都查不到，才判定为真的已卸载。
    private func isInstalled(_ a: AppItem?) -> Bool {
        guard let a else { return true }        // 没有实例信息就保守保留
        // 主路径来自扫描器，直接采信（系统应用可能在 Cryptexes 等位置，
        // 硬性要求落在扫描根下会误删 Safari 这类应用）
        if let p = a.path, !p.isEmpty,
           FileManager.default.fileExists(atPath: p) { return true }
        // 兜底：应用升级 / 被移到别的目录时用 bundle id 重新定位。
        // 但挂载的 DMG、废纸篁里的同名副本不算「已安装」——
        // 否则 /Applications/Claude.app 已删、DMG 还挂着时，幽灵图标永远清不掉。
        if let bid = a.bundleID, !bid.isEmpty,
           let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
           FileManager.default.fileExists(atPath: u.path),
           isRealInstallLocation(u.path) { return true }
        // path / bundle id 都没有，无法判定，一律保留
        if (a.path ?? "").isEmpty && (a.bundleID ?? "").isEmpty { return true }
        return false
    }

    private func isRealInstallLocation(_ path: String) -> Bool {
        !path.hasPrefix("/Volumes/") && !path.contains("/.Trash/")
    }

    /// 轻量清理：只检查已布局项，把确实已卸载的从顶层与文件夹里移除。
    /// 文件夹成员清空才解散，其余排序 / 成员一律原样保留。
    /// 每次窗口激活都会跑一次，路径检查很快，不需要全盘扫描。
    func pruneUninstalled() {
        var changed = false
        var newFolders: [String: [String]] = [:]
        for (name, ids) in folders {
            let kept = ids.filter { isInstalled(resolveApp($0)) }
            if kept.count != ids.count { changed = true }
            if kept.isEmpty { changed = true } else { newFolders[name] = kept }
        }

        var rebuilt: [GridItem] = []
        for gi in items {
            switch gi {
            case .app(let a):
                if isInstalled(a) { rebuilt.append(.app(a)) }
                else { changed = true }
            case .folder(let name, _):
                if let ids = newFolders[name], !ids.isEmpty {
                    rebuilt.append(.folder(name: name,
                                           items: ids.compactMap { resolveApp($0) }))
                } else {
                    changed = true
                }
            }
        }
        guard changed else { return }
        folders = newFolders
        items = rebuilt
        clampPage()
        save()
    }

    /// 用一次全新扫描刷新布局：卸载的移除、新安装的追加到**布局最后**、
    /// 已有项的名称 / 路径更新。用户排序与文件夹成员结构完全不动。
    func applyFreshApps(_ fresh: [AppItem]) {
        var freshById: [String: AppItem] = [:]
        for a in fresh {
            freshById[a.id] = a
            fallbackApps[a.id] = a
        }
        // 没被扫到但磁盘上仍存在的应用照样保留（升级 / 移动中的容错）
        func alive(_ id: String, _ stored: AppItem?) -> Bool {
            freshById[id] != nil || isInstalled(stored)
        }

        var newFolders: [String: [String]] = [:]
        for (name, ids) in folders {
            let kept = ids.filter { alive($0, resolveApp($0)) }
            if !kept.isEmpty { newFolders[name] = kept }
        }

        var rebuilt: [GridItem] = []
        var usedIds = Set<String>()
        for gi in items {
            switch gi {
            case .app(let a):
                guard alive(a.id, a) else { continue }
                rebuilt.append(.app(freshById[a.id] ?? a))
                usedIds.insert(a.id)
            case .folder(let name, _):
                guard let ids = newFolders[name], !ids.isEmpty else { continue }
                rebuilt.append(.folder(name: name,
                                       items: ids.compactMap { freshById[$0] ?? resolveApp($0) }))
                usedIds.formUnion(ids)
            }
        }
        // 新安装的应用只追加到末尾，不插队、不改已有顺序
        for a in fresh where !usedIds.contains(a.id) {
            rebuilt.append(.app(a))
        }
        guard rebuilt != items else { return }   // 无变化就不写盘
        folders = newFolders
        items = rebuilt
        clampPage()
        save()
    }

    /// 窗口重新显示 / 冷启动时调用：先做轻量卸载清理，再后台全盘扫描补新装应用。
    func refreshInstalledApps() {
        pruneUninstalled()
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fresh = AppScanner.scanAllApps()
            AppScanCache.write(fresh)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyFreshApps(fresh)
                self.refreshing = false
            }
        }
    }

    var allAppsById: [String: AppItem] {
        // 用循环而不是 uniqueKeysWithValues：缓存 / 布局一旦出现重复 id，
        // 后者会直接 trap 在启动阶段。
        var d: [String: AppItem] = [:]
        for a in allApps { d[a.id] = a }
        return d
    }

    /// 解析应用实例：最新扫描 → 当前内存布局 → 布局文件里的旧实例。
    /// 文件夹成员重组（拖出 / 合并）一律走这里，不能只用 allAppsById，
    /// 否则 layout.json 里恢复出来的应用会在重组时集体消失。
    private func resolveApp(_ id: String) -> AppItem? {
        if let a = allAppsById[id] { return a }
        for gi in items {
            if case .app(let a) = gi, a.id == id { return a }
            if case .folder(_, let apps) = gi,
               let a = apps.first(where: { $0.id == id }) { return a }
        }
        return fallbackApps[id]
    }

    /// 处于搜索 / 分类筛选时禁用拖拽（顺序不可变）
    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || selectedCategory != nil
    }

    // MARK: - 过滤后的可见顶层元素
    var visibleItems: [GridItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 「全部」搜索顶层内容，并展开文件夹成员；选中分类后只搜索该分类程序。
        // 分类名称本身也是搜索键，例如输入「社交」会列出社交类程序。
        if !q.isEmpty {
            var all: [GridItem] = []
            for gi in items {
                switch gi {
                case .app(let app):
                    if selectedCategory == nil || app.category == selectedCategory {
                        all.append(gi)
                    }
                case .folder(_, let apps):
                    if selectedCategory == nil { all.append(gi) }
                    all.append(contentsOf: apps.compactMap { app in
                        selectedCategory == nil || app.category == selectedCategory
                            ? GridItem.app(app) : nil
                    })
                }
            }
            let scored: [(offset: Int, item: GridItem, score: Int)] = all.enumerated().compactMap { pair in
                let s: Int?
                switch pair.element {
                case .app(let a):
                    s = FuzzySearch.relevance(query: q, name: a.name, path: a.path,
                                              bundleID: a.bundleID, category: a.category)
                case .folder(let name, _):
                    s = FuzzySearch.relevance(query: q, name: name)
                }
                guard let score = s else { return nil }
                return (pair.offset, pair.element, score)
            }
            return scored
                .sorted { l, r in l.score == r.score ? l.offset < r.offset : l.score > r.score }
                .map { $0.item }
        }

        guard let cat = selectedCategory else { return items }
        // 分组栏按「全部程序」统计：文件夹只是容器，不参与分组。
        // 被移进文件夹的应用同样展开成独立条目参与匹配，
        // 不会因为它们被收纳就从对应分类里消失。
        var all: [GridItem] = []
        for gi in items {
            switch gi {
            case .app:
                all.append(gi)
            case .folder(_, let apps):
                all.append(contentsOf: apps.map { GridItem.app($0) })
            }
        }
        return all.filter { gi in
            guard case .app(let a) = gi else { return false }
            return a.category == cat
        }
    }

    /// 单页 / 多页开关（来自设置）
    var multiPage: Bool { SettingsStore.shared.multiPage }

    var pageCount: Int {
        if !multiPage { return 1 }
        return max(1, (visibleItems.count + kPageSize - 1) / kPageSize)
    }

    func pageItems(_ p: Int) -> [GridItem] {
        let v = visibleItems
        if !multiPage { return v }          // 单页：全部应用一页显示
        guard p >= 0, p < pageCount else { return [] }
        let start = p * kPageSize
        guard start < v.count else { return [] }
        return Array(v[start..<min(start + kPageSize, v.count)])
    }

    /// 所有翻页的统一入口，带冷却锁，避免滚轮/触控板/连点造成一次动作连翻多页
    private var lastPageChange: Date = .distantPast
    private let pageCooldown: TimeInterval = 0.55

    @discardableResult
    func requestPage(_ target: Int) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastPageChange) >= pageCooldown else { return false }
        let clamped = min(max(target, 0), pageCount - 1)
        guard clamped != page else { return false }
        lastPageChange = now
        page = clamped
        return true
    }

    var canChangePage: Bool {
        Date().timeIntervalSince(lastPageChange) >= pageCooldown
    }

    /// 跟手拖动松手 / 带滑动动画的翻页：直接落页并刷新冷却时间
    func commitPage(_ target: Int) {
        let clamped = min(max(target, 0), pageCount - 1)
        guard clamped != page else { return }
        lastPageChange = Date()
        page = clamped
    }

    func stepPage(_ delta: Int) {
        _ = requestPage(page + delta)
    }

    func clampPage() {
        page = min(max(page, 0), pageCount - 1)
    }

    // MARK: - 持久化
    private static func defaultLayoutURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchpadApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }

    private func loadLayout() {
        guard let data = try? Data(contentsOf: layoutFile),
              let store = try? JSONDecoder().decode(LayoutStore.self, from: data) else {
            items = allApps.map { GridItem.app($0) }
            topOrder = items.map { $0.id }
            return
        }

        folders = store.folderMap
        topOrder = store.pageOrder

        // 记下布局文件里的所有实例，供以后重组文件夹成员时找回
        // 「已不在最新扫描结果里」的应用。最新扫描结果优先级更高。
        for a in store.items { fallbackApps[a.id] = a }
        for a in allApps { fallbackApps[a.id] = a }

        // 用最新扫描结果刷新中文名 / 路径；但已保存的布局项一律保留，
        // 绝不因为某个应用暂时扫不到就删掉用户的文件夹或排序。
        let fresh = allAppsById
        var storedById: [String: AppItem] = [:]
        for a in store.items { storedById[a.id] = a }
        func resolved(_ id: String) -> AppItem? { fresh[id] ?? storedById[id] }

        var rebuilt: [GridItem] = []
        var usedIds = Set<String>()
        for key in topOrder {
            if key.hasPrefix("folder:") {
                let name = String(key.dropFirst("folder:".count))
                let ids = folders[name] ?? []
                guard !ids.isEmpty else {
                    folders.removeValue(forKey: name)
                    continue
                }
                rebuilt.append(.folder(name: name, items: ids.compactMap { resolved($0) }))
                usedIds.formUnion(ids)
            } else if key.hasPrefix("app:") {
                let id = String(key.dropFirst("app:".count))
                if let a = resolved(id) {
                    rebuilt.append(.app(a))
                    usedIds.insert(id)
                }
            }
        }
        // 新安装的应用补到末尾；缓存里残留的已卸载项不要补回来
        for a in allApps where !usedIds.contains(a.id) && isInstalled(a) {
            rebuilt.append(.app(a))
        }
        items = rebuilt
        // 冷启动也立刻按磁盘现状清掉已卸载项，不等后台扫描
        pruneUninstalled()
        clampPage()
        save()
    }

    /// 当前布局的值类型快照，交给后台队列编码/写盘，不持有 self 的可变状态
    private func layoutSnapshot() -> LayoutStore {
        var appStore: [AppItem] = []
        for gi in items {
            switch gi {
            case .app(let a): appStore.append(a)
            case .folder(_, let fs): appStore.append(contentsOf: fs)
            }
        }
        return LayoutStore(items: appStore, folderMap: folders, pageOrder: topOrder)
    }

    private func write(_ snapshot: LayoutStore) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: layoutFile, options: .atomic)
    }

    func save() {
        topOrder = items.map { $0.id }     // 立即更新内存状态，视图照常刷新
        let snapshot = layoutSnapshot()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.write(snapshot)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 立即写盘（退出 / deinit 时调用），取消未触发的去抖任务
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        write(layoutSnapshot())
    }

    func resetLayout() {
        folders = [:]
        items = allApps.map { GridItem.app($0) }
        page = 0
        save()
    }

    // MARK: - 拖拽排序（把某一页的新顺序写回全局）
    func commitReorder(page p: Int, orderedIDs: [String]) {
        guard !isFiltering else { return }
        // 多页只替换当前页那一段；单页替换整个数组
        let start = multiPage ? p * kPageSize : 0
        let end = multiPage ? min(start + kPageSize, items.count) : items.count
        guard start < items.count, end > start else { return }

        var dict: [String: GridItem] = [:]
        for gi in items[start..<end] { dict[gi.id] = gi }
        let ordered = orderedIDs.compactMap { dict[$0] }
        guard ordered.count == (end - start) else { return }

        items.replaceSubrange(start..<end, with: ordered)
        clampPage()
        save()
    }

    // MARK: - 合并成文件夹
    private func uniqueFolderName(_ base: String) -> String {
        var name = base
        var i = 2
        while folders[name] != nil {
            name = "\(base) \(i)"
            i += 1
        }
        return name
    }

    private func collectedApps(_ gi: GridItem) -> [AppItem] {
        switch gi {
        case .app(let a): return [a]
        case .folder(_, let fs): return fs
        }
    }

    /// 把 drag 拖到 target 上：若 target 是文件夹则加入；否则新建文件夹，位置取 target 原位
    @discardableResult
    func merge(dragID: String, onto targetID: String) -> Bool {
        guard dragID != targetID,
              let dragIdx = items.firstIndex(where: { $0.id == dragID }),
              let targetIdx = items.firstIndex(where: { $0.id == targetID }) else { return false }
        let drag = items[dragIdx]
        let target = items[targetIdx]

        if case .folder(let fname, _) = target {
            guard !drag.isFolder else { return false }   // 文件夹不互相嵌套
            var ids = folders[fname] ?? []
            for a in collectedApps(drag) where !ids.contains(a.id) { ids.append(a.id) }
            folders[fname] = ids
            let apps = ids.compactMap { resolveApp($0) }

            // 老 Launchpad 行为：被拖程序消失，其它图标顺次补位，
            // 但目标文件夹必须钉在原来的格子里，不能跟着左移一格。
            let folderPos = targetIdx
            items.remove(at: dragIdx)
            if dragIdx < folderPos {
                // 删除后文件夹落在 folderPos-1，与后一项交换即可回到原索引，
                // 后面的元素自然前移填补空位。
                let cur = folderPos - 1
                if cur < items.count - 1 { items.swapAt(cur, cur + 1) }
            }
            if let idx = items.firstIndex(where: { $0.id == targetID }) {
                items[idx] = .folder(name: fname, items: apps)
            }
            page = min(page, pageCount - 1)
            save()
            return true
        }

        guard !drag.isFolder else { return false }

        var seen = Set<String>()
        let collected = (collectedApps(drag) + collectedApps(target))
            .filter { seen.insert($0.id).inserted }

        let base = collected.prefix(2).map { $0.name }.joined(separator: " & ")
        let name = uniqueFolderName(base)

        let hi = max(dragIdx, targetIdx), lo = min(dragIdx, targetIdx)
        items.remove(at: hi)
        items.remove(at: lo)
        let insertAt = min(lo, items.count)

        folders[name] = collected.map { $0.id }
        items.insert(.folder(name: name, items: collected), at: insertAt)
        page = min(page, pageCount - 1)   // 元素减少后避免停留在空页
        save()
        return true
    }

    // 从文件夹中移出（fallback 保证即使该应用已不在扫描结果里也能回到网格）
    func removeFromFolder(_ appId: String, folderName: String,
                          fallback: AppItem? = nil, insertAt: Int? = nil) {
        var ids = folders[folderName] ?? []
        guard ids.contains(appId) else { return }
        ids.removeAll { $0 == appId }

        let folderKey = "folder:" + folderName
        let idx = items.firstIndex(where: { $0.id == folderKey })
        let moved = resolveApp(appId) ?? fallback

        // 只有真正清空才解散文件夹；剩 1 个成员时保留文件夹，
        // 否则「拖出第一个图标」会让文件夹在主网格里凭空消失。
        let replacements: [GridItem]
        if ids.isEmpty {
            folders.removeValue(forKey: folderName)
            replacements = []
        } else {
            folders[folderName] = ids
            let apps = ids.compactMap { resolveApp($0) }
            replacements = [.folder(name: folderName, items: apps)]
        }
        if let i = idx {
            items.replaceSubrange(i...i, with: replacements)
        } else {
            items.append(contentsOf: replacements)
        }

        // 被拖出的程序插到松手位置：insert 会让该位置及之后的图标依次后移，
        // 也就是老 Launchpad 里「挤开其他图标」的效果。
        if let a = moved {
            let base = idx ?? max(0, items.count - 1)
            var at = insertAt ?? (base + replacements.count)
            // 文件夹占位由 1 项变成 replacements.count 项，落点在其后需补偿
            if at > base { at += replacements.count - 1 }
            at = min(max(at, 0), items.count)
            items.insert(.app(a), at: at)
        }
        clampPage()
        save()
    }

    /// 跨页拖动：把某个顶层项移动到全局扁平顺序的指定位置。
    /// 后面的项依次顺延，分页切片会自然重新排布（老 Launchpad 的挤开行为）。
    func relocate(itemID: String, toGlobalIndex: Int) {
        guard let from = items.firstIndex(where: { $0.id == itemID }) else { return }
        let moving = items.remove(at: from)
        let at = min(max(toGlobalIndex, 0), items.count)
        items.insert(moving, at: at)
        clampPage()
        save()
    }

    /// 文件夹内排序：按给定 id 顺序重排成员，并刷新网格里的文件夹缩略
    func reorderFolder(_ name: String, order: [String]) {
        guard let current = folders[name], order.count == current.count,
              Set(order) == Set(current) else { return }
        folders[name] = order
        if let idx = items.firstIndex(where: { $0.id == "folder:" + name }) {
            items[idx] = .folder(name: name,
                                 items: order.compactMap { resolveApp($0) })
        }
        save()
    }

    /// 重命名文件夹
    func renameFolder(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old, folders[trimmed] == nil else { return }
        folders[trimmed] = folders[old]
        folders.removeValue(forKey: old)
        if let idx = items.firstIndex(where: { $0.id == "folder:" + old }),
           case .folder(_, let apps) = items[idx] {
            items[idx] = .folder(name: trimmed, items: apps)
        }
        save()
    }
}

// MARK: - 应用目录实时监听（FSEvents）

/// 监听应用目录，安装 / 卸载 / 移动 .app 时立刻通知刷新布局。
/// 只订阅目录级事件（不开 FileEvents），事件少、耗电低；
/// FSEvents 的 latency + 自己的冷却把一次安装产生的一串写入合并成一次刷新。
/// paths 可在回归测试里注入临时目录，避免测试去动真实 /Applications。
final class AppDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.local.launchpad.appwatch", qos: .utility)
    private let onChange: () -> Void
    private let paths: [String]
    private var lastFire = Date.distantPast
    private let lock = NSLock()

    static var defaultPaths: [String] { AppScanner.searchRoots }

    init(paths: [String]? = nil, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.paths = (paths ?? AppDirectoryWatcher.defaultPaths)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppDirectoryWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,                       // 事件合并窗口
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            return
        }
    }

    private func fire() {
        let now = Date()
        lock.lock()
        guard now.timeIntervalSince(lastFire) > 6 else { lock.unlock(); return }
        lastFire = now
        lock.unlock()
        // 安装器通常先建临时目录、再改名成 .app，等它落定再刷新
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.onChange()
        }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    deinit { stop() }
}

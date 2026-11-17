import AppKit
import SwiftUI
import Combine
import QuartzCore

/// 离散滚轮：一次有效输入最多翻一页；系统行增量并不保证等于物理齿数。
/// 行增量为 0 时按同一轴的点位移取方向，空事件不产生翻页。
/// 连续插值设备由 `ScrollGestureRouter` 在串首直接发齿，这里不再需要
/// 任何时间窗 / 合并参数，也不再提供可调间隔设置项。
struct WheelDetentClassifier {
    /// 返回带符号齿数（向下滚为负），调用方换算成页面方向。
    func feed(lineDelta: Int, pixelDelta: CGFloat) -> Int {
        if lineDelta != 0 { return lineDelta > 0 ? 1 : -1 }
        guard pixelDelta.isFinite, abs(pixelDelta) > 0.001 else { return 0 }
        return pixelDelta > 0 ? 1 : -1
    }
}

/// 无边框**辅助面板**：能成为 key window 接收键盘，但不激活所属 app。
///
/// 台前调度下这一点是关键。普通 NSWindow 默认被当作 primary「主窗口」，
/// 系统为了给它腾出中央舞台，会把当前活动的其它程序收进左侧「最近应用」栏；
/// 用户看到的就是「一打开启动台，别的程序全跑到左边」。
/// 按 WWDC22《What's new in AppKit》的说法，辅助窗口（panel / popover / 设置）
/// 应该浮在现有窗口之上，不顶替中央窗口。这里用 nonactivatingPanel +
/// collectionBehavior.auxiliary 明确声明身份。
final class LaunchpadWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// auxiliary：Stage Manager / 全屏下都视为辅助窗口，不 displace 活动窗口
    /// （与 primary / canJoinAllApplications 互斥，且与 Spaces 组可叠加）。
    /// moveToActiveSpace：保留「在哪个桌面触发就在哪个桌面显示」。
    /// ignoresCycle：不参与 Cmd-` 窗口循环，它不是文档窗口。
    static let stageBehavior: NSWindow.CollectionBehavior = [
        .auxiliary,
        .moveToActiveSpace,
        .ignoresCycle,
    ]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: LaunchpadWindow!
    /// macOS 26 官方液态玻璃视图：作为窗口 contentView，SwiftUI 内容嵌在它里面
    private var glassView: NSGlassEffectView?
    /// 持有 hosting controller，避免 SwiftUI 视图被释放
    private var hosting: NSHostingController<LaunchpadView>?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var scrollRouter = ScrollGestureRouter()
    private var wheelScrollEndWorkItem: DispatchWorkItem?
    private var wheelScrollEndToken = UUID()
    private var globalClickMonitor: Any?
    /// accessory 模式没有 Dock 图标，用菜单栏图标保留「点击打开」入口
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    /// 点击应用隐藏窗口后，短时间内不再因重新激活把窗口弹回来
    private var suppressReactivateUntil: Date = .distantPast
    /// 避免窗口打开时 Dock / Launch Services 的焦点交接被当成用户切出。
    private var ignoreFocusLossUntil: Date = .distantPast
    private var frontmostPIDWhenShown: pid_t?
    private var frontmostWindowIDsWhenShown: [UInt32] = []
    private var focusWindowTimer: DispatchSourceTimer?
    private var duplicateInstance = false
    /// 窗口开关动画的代数：显示/隐藏互相打断时，让旧的收尾回调失效
    private var windowTransition = 0
    /// 记录用户期望的显隐状态，避免淡出期间 isVisible 仍为 true 导致切换错误。
    private var windowShouldBeVisible = false
    /// 桌面图标重开可能同时到达系统回调和单实例转发通知，只处理一次。
    private var lastReopenToggle = Date.distantPast

    private let settings = SettingsStore.shared


    // MARK: - 单例：已有实例则激活它并退出自己
    func applicationWillFinishLaunching(_ notification: Notification) {
        let ownPID = NSRunningApplication.current.processIdentifier
        let bid = Bundle.main.bundleIdentifier
        let others = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != ownPID else { return false }
            if let bid, !bid.isEmpty { return app.bundleIdentifier == bid }
            let n = app.localizedName ?? ""
            return n == "启动台" || n == "Launchpad"
        }
        if !others.isEmpty {
            duplicateInstance = true
            // 叫醒已有实例也走通知，不用 activate(options:.activateAllWindows)：
            // 激活 app 同样会让台前调度把其它程序收到左侧。
            DistributedNotificationCenter.default()
                .post(name: .launchpadReopenRequest, object: nil)
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !duplicateInstance else { return }
        // 菜单栏图标在窗口创建/显示之前就位：否则状态栏会在窗口淡入的
        // 同一帧重排图标，看起来就是「顶部状态栏闪一下」。
        setupStatusItem()
        let root = LaunchpadView()
        let hosting = NSHostingController(rootView: root)

        let win = LaunchpadWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 840),
            // 无边框 + nonactivatingPanel：成为 key window 时**不激活所属 app**，
            // 台前调度就不会把其它程序收进左侧「最近应用」栏。
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isFloatingPanel = true
        win.delegate = self
        // 让面板一出现就能接收键盘（搜索框 / 方向键翻页），而不是只在
        // 用户点进文本控件后才成为 key window
        win.becomesKeyOnlyIfNeeded = false
        win.hidesOnDeactivate = false
        // 面板不参与 app 级 hide，始终浮在原本的中央程序之上
        win.canHide = false
        win.worksWhenModal = true
        win.isOpaque = false
        win.backgroundColor = .clear
        // 系统窗口阴影是矩形的，会在圆角四角露出方形色块；
        // 改由 SwiftUI 的圆角形状投影负责
        win.hasShadow = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // 窗口位置固定：既不能拖背景，也不能拖标题栏，始终由 fitWindowToContent 居中
        win.isMovable = false
        win.isMovableByWindowBackground = false

        // 顺序很关键：SwiftUI 的 hosting view 会把窗口压到自己的理想尺寸，
        // 而 macOS 调整窗口尺寸时保持左下角不动 → 若先居中再挂 contentViewController，
        // 窗口会变小并偏左下。必须先挂视图、固定尺寸，最后才居中。
        //
        // 官方用法：NSGlassEffectView 是窗口 contentView，
        // SwiftUI 的 hosting.view 作为它的 contentView 嵌在玻璃里。
        // 之前把玻璃当普通子视图插在 SwiftUI 视图下层，z-order 不对，
        // 会连图标和标签一起被模糊掉。
        if #available(macOS 26.0, *) {
            self.hosting = hosting
            let glass = NSGlassEffectView(frame: hosting.view.bounds)
            glass.cornerRadius = 22
            glass.style = .clear
            applyGlassAppearance(glass)
            hosting.view.autoresizingMask = [.width, .height]
            glass.contentView = hosting.view
            win.contentView = glass
            glassView = glass
        } else {
            win.contentViewController = hosting
        }
        // 四角由 contentView 的 layer 裁掉：无边框窗口的矩形 backing
        // 会在圆角外留下硬边直角灰块，只有 masksToBounds 能彻底裁干净。
        let rootView = win.contentView
        rootView?.wantsLayer = true
        rootView?.layer?.cornerRadius = 22
        rootView?.layer?.cornerCurve = .continuous
        rootView?.layer?.masksToBounds = true
        hosting.view.wantsLayer = true
        hosting.view.layer?.masksToBounds = true
        win.level = settings.alwaysOnTop ? .floating : .normal
        // 台前调度：声明为辅助窗口，呈现时不把中央的活动窗口挤到左侧
        win.collectionBehavior = LaunchpadWindow.stageBehavior
        window = win
        fitWindowToContent(win)

        // 窗口不在创建时直接显示：统一交给 activate() 走淡入动画，
        // 避免冷启动先闪一下静态窗口再播动画。

        // 纯代码 app 没有 MainMenu.nib，必须自己构建主菜单，
        // 否则顶部菜单栏不会出现「启动台 / 文件 / 编辑 / 窗口 / 帮助」这套标准菜单。
        setupMainMenu()
        setupKeyMonitor()
        setupScrollMonitor()
        setupGlobalClickMonitor()
        setupPinchGestureMonitor()
        bindSettings()
        // 重复启动的实例会把桌面图标点击转交给主实例做显隐切换
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleReopenRequest),
            name: .launchpadReopenRequest,
            object: nil
        )

        activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.activate()
            // 调试入口：open Launchpad.app --args --open-settings
            if CommandLine.arguments.contains("--open-settings") {
                NotificationCenter.default.post(name: .openSettingsPage, object: nil)
            }
        }
    }

    /// 窗口高度跟随网格行数：一行 121pt，
    /// 另加 156pt 给搜索栏 / 分类栏 / 页码点与上下留白。
    /// 7×4 → 640，7×5 → 761；仅在屏幕装不下时收缩。
    private func fitWindowToContent(_ win: NSWindow) {
        let vf = (win.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let wantedH = 156 + CGFloat(GridMetrics.rows) * 121
        let w = min(900, vf.width - 40)
        let h = min(wantedH, vf.height - 40)
        win.setContentSize(NSSize(width: w, height: h))
        centerOnScreen(win)
    }

    /// 居中到当前屏幕可见区域（已排除菜单栏与 Dock）正中
    private func centerOnScreen(_ win: NSWindow) {
        guard let screen = win.screen ?? NSScreen.main else {
            win.center()
            return
        }
        let vf = screen.visibleFrame
        let sz = win.frame.size
        win.setFrame(
            NSRect(x: vf.midX - sz.width / 2,
                   y: vf.midY - sz.height / 2,
                   width: sz.width, height: sz.height),
            display: true
        )
    }

    /// 把「液态玻璃强度」映射到官方玻璃视图：影响 tint 浓度与 style（clear ↔ regular）
    @available(macOS 26.0, *)
    private func applyGlassAppearance(_ glass: NSGlassEffectView) {
        let intensity = min(max(CGFloat(settings.glassIntensity), 0), 1)
        glass.style = intensity > 0.72 ? .regular : .clear
        glass.tintColor = NSColor(white: 0.25, alpha: 0.04 + 0.16 * intensity)
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = false
        }
    }

    // MARK: - 菜单栏入口

    /// accessory app 不显示 Dock 图标，菜单栏图标是主要的点击打开入口。
    /// 左键切换显示/隐藏；按住 Control 或右键弹出菜单（含退出）。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill",
                                     accessibilityDescription: "启动台")
        item.button?.toolTip = "启动台：点击打开 / 关闭"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: windowShouldBeVisible ? "关闭启动台" : "打开启动台",
                                    action: #selector(toggleLaunchpad), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出启动台", action: #selector(quitLaunchpad),
                                  keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // 用完清掉，否则下次左键会直接弹菜单而不是切换
            DispatchQueue.main.async { [weak self] in self?.statusItem?.menu = nil }
        } else {
            toggleLaunchpad()
        }
    }

    @objc private func toggleLaunchpad() {
        if windowShouldBeVisible { hideWindow() } else { activate() }
    }

    @objc private func quitLaunchpad() { NSApp.terminate(nil) }

    // MARK: - 窗口开关动画

    /// contentView 的轻微缩放（0.96 ↔ 1.0），配合 alpha 做出现/消失感。
    /// 只动 layer.transform，不改 window.frame —— 否则 SwiftUI 会在动画中重算布局。
    private func setWindowScale(_ win: NSWindow, _ s: CGFloat) {
        guard let layer = win.contentView?.layer else { return }
        layer.removeAnimation(forKey: "lpWindowScale")
        layer.transform = CATransform3DMakeScale(s, s, 1)
    }

    private func animateWindowScale(_ win: NSWindow, from: CGFloat, to: CGFloat,
                                    duration: TimeInterval) {
        guard let layer = win.contentView?.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "lpWindowScale")
        layer.transform = CATransform3DMakeScale(to, to, 1)
    }

    /// 窗口上屏后重新声明一次玻璃参数。
    /// 不做视图树重算、不切 style、不强制同步 display —— 那些都会让顶部栏闪。
    @available(macOS 26.0, *)
    private func refreshGlassAppearance() {
        guard let glass = glassView else { return }
        applyGlassAppearance(glass)
        glass.needsDisplay = true
    }

    private func activate() {
        guard let win = window else { return }
        windowTransition += 1
        let g = windowTransition
        win.collectionBehavior = LaunchpadWindow.stageBehavior
        centerOnActiveScreen(win)
        // 台前调度下**不要**调用 NSApp.activate / NSRunningApplication.activate。
        // 强制激活 app 会让系统把原本在中央的程序收进左侧「最近应用」栏，
        // 正是用户不想要的效果。nonactivatingPanel 可以在不激活 app 的前提下
        // 成为 key window，搜索、方向键、Esc 等键盘交互照常可用。
        let appearing = !windowShouldBeVisible || !win.isVisible
        windowShouldBeVisible = true
        if appearing {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            frontmostPIDWhenShown = pid == NSRunningApplication.current.processIdentifier ? nil : pid
            frontmostWindowIDsWhenShown = pid.map(visibleWindowIDs(for:)) ?? []
            ignoreFocusLossUntil = Date().addingTimeInterval(0.35)
            startFocusWindowMonitor()
            scrollRouter = ScrollGestureRouter()
            cancelWheelScrollEnd()
        }
        // 显示动画**只用缩放**，窗口和内容层从第一帧起就完全不透明。
        // 无论把 window.alphaValue 还是 content layer.opacity 从 0 淡入，
        // 任何系统玻璃材质在透明状态下初始化都不会立刻正常渲染，
        // 之后要等用户点击窗口（成为 key）才恢复。
        win.alphaValue = 1
        hosting?.view.layer?.opacity = 1
        if appearing {
            setWindowScale(win, 0.96)
        } else {
            // 隐藏动画还没播完就被重新唤起：取消缩放回弹，保持原尺寸
            setWindowScale(win, 1)
        }
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        // 尽量让面板成为 key window（搜索/方向键、玻璃活跃态都依赖它）
        win.makeKey()
        if appearing {
            animateWindowScale(win, from: 0.96, to: 1, duration: 0.10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.windowTransition == g else { return }
                self.setWindowScale(win, 1)
            }
            // 玻璃刷新单独调度：冷启动时 activate() 会被连续调用多次，
            // windowTransition 被后续调用推进会让上面的收尾提前 return，
            // 所以这里只以「窗口确实可见」为条件，不依赖动画代数。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                win.makeKey()
                if #available(macOS 26.0, *) { self.refreshGlassAppearance() }
            }
        }
        // 每次窗口回到前台都让布局按磁盘现状刷新一次：
        // 卸载的程序移除、新安装的追加到末尾（不重启也生效）
        NotificationCenter.default.post(name: .launchpadDidActivate, object: nil)
    }

    /// 统一隐藏入口：淡出 + 轻微缩小，动画结束才 orderOut。
    /// 所有「关闭启动台」路径都走这里，避免各处直接 orderOut 导致没有动画。
    private func hideWindow() {
        guard let win = window, windowShouldBeVisible else { return }
        windowShouldBeVisible = false
        stopFocusWindowMonitor()
        scrollRouter = ScrollGestureRouter()
        cancelWheelScrollEnd()
        NotificationCenter.default.post(name: .pagingInputReset, object: nil)
        windowTransition += 1
        let g = windowTransition
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            win.animator().alphaValue = 0
        }
        animateWindowScale(win, from: 1, to: 0.96, duration: 0.10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.windowTransition == g else { return }
            win.orderOut(nil)
            win.alphaValue = 1
            self.setWindowScale(win, 1)
        }
    }

    /// 重复启动的实例转发桌面图标点击：按当前期望状态切换窗口。
    @objc private func handleReopenRequest() {
        DispatchQueue.main.async { [weak self] in self?.toggleForReopen() }
    }

    private func toggleForReopen() {
        let now = Date()
        guard now.timeIntervalSince(lastReopenToggle) > 1.0 else { return }
        lastReopenToggle = now
        suppressReactivateUntil = now.addingTimeInterval(0.5)
        toggleLaunchpad()
    }

    /// 以鼠标当前所在显示器为准居中：多屏 / 多桌面时窗口不会串到另一个屏幕
    private func centerOnActiveScreen(_ win: NSWindow) {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        guard let screen else { win.center(); return }
        let vf = screen.visibleFrame
        let sz = win.frame.size
        win.setFrameOrigin(NSPoint(x: vf.midX - sz.width / 2,
                                   y: vf.midY - sz.height / 2))
    }

    // MARK: - 全局四指捏合：在任何桌面都能把窗口叫到当前桌面
    private var globalPinchMonitor: Any?
    private var localPinchMonitor: Any?
    private var pinchAccum: CGFloat = 0
    private var lastPinchSample = Date.distantPast
    private var lastPinchOpen = Date.distantPast

    private func setupPinchGestureMonitor() {
        // .magnify / .gesture 是触控板捏合事件；global 收其它应用前台的事件，
        // local 收本应用前台的事件，两者合并才能做到「全局」。
        let mask: NSEvent.EventTypeMask = [.gesture, .magnify]
        let handle: (NSEvent) -> Void = { [weak self] ev in
            guard let self else { return }
            let m = ev.magnification
            guard m != 0 else { return }
            let now = Date()
            // 增量间隔过长视为另一次手势，避免把多次小捏合累加误触发
            if now.timeIntervalSince(self.lastPinchSample) > 0.35 { self.pinchAccum = 0 }
            self.lastPinchSample = now
            guard m < 0 else { self.pinchAccum = 0; return }   // 只认捏合（缩小）
            self.pinchAccum += m
            guard self.pinchAccum < -0.20,
                  now.timeIntervalSince(self.lastPinchOpen) > 0.9 else { return }
            self.lastPinchOpen = now
            self.pinchAccum = 0
            DispatchQueue.main.async { self.activate() }
        }
        globalPinchMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { handle($0) }
        localPinchMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
            return event
        }
    }

    private func bindSettings() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      app.processIdentifier != NSRunningApplication.current.processIdentifier,
                      self.windowShouldBeVisible,
                      self.window?.isVisible == true else { return }
                self.hideForFocusLoss(requireWindowResigned: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .launchpadSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let target: NSWindow.Level = self.settings.alwaysOnTop ? .floating : .normal
                if self.window?.level != target { self.window?.level = target }
                // 玻璃强度滑杆实时生效（窗口尺寸保持不变）
                if #available(macOS 26.0, *), let glass = self.glassView {
                    self.applyGlassAppearance(glass)
                }
            }
            .store(in: &cancellables)

        // 分辨率 / 外接显示器变化后才重新适配尺寸并居中
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, let win = self.window else { return }
            self.fitWindowToContent(win)
        }
        .store(in: &cancellables)

        // 启动某个应用后隐藏启动台窗口
        NotificationCenter.default.publisher(for: .hideLaunchpad)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.suppressReactivateUntil = Date().addingTimeInterval(1.5)
                self.hideWindow()
                // 不再主动清空图标缓存：NSCache 有 160 张 / 24MB 上限，且系统
                // 会在内存压力下自动回收（实测 CG Image 已全部 swapped）。
                // 主动 purge 只会让下次打开重新解码 100+ 张图，造成重开卡顿。
            }
            .store(in: &cancellables)

        // Esc / 菜单「关闭窗口」：只淡出，不清图标缓存、不设置抑制重激活
        NotificationCenter.default.publisher(for: .hideWindowAnimated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hideWindow() }
            .store(in: &cancellables)
    }

    private func visibleWindowIDs(for pid: pid_t) -> [UInt32] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return number.uint32Value
        }
    }

    private func startFocusWindowMonitor() {
        stopFocusWindowMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            guard let self, self.windowShouldBeVisible,
                  Date() >= self.ignoreFocusLossUntil,
                  let pid = self.frontmostPIDWhenShown,
                  let frontmost = NSWorkspace.shared.frontmostApplication else { return }
            if frontmost.processIdentifier != pid
                || self.visibleWindowIDs(for: pid) != self.frontmostWindowIDsWhenShown {
                self.hideForFocusLoss(requireWindowResigned: false)
            }
        }
        focusWindowTimer = timer
        timer.resume()
    }

    private func stopFocusWindowMonitor() {
        focusWindowTimer?.cancel()
        focusWindowTimer = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let transition = windowTransition
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowTransition == transition else { return }
            self.hideForFocusLoss()
        }
    }

    private func hideForFocusLoss(requireWindowResigned: Bool = true) {
        guard windowShouldBeVisible,
              let win = window,
              win.isVisible,
              Date() >= ignoreFocusLossUntil else { return }
        guard !requireWindowResigned || !win.isKeyWindow else { return }
        suppressReactivateUntil = Date().addingTimeInterval(1.5)
        hideWindow()
    }

    // MARK: - 标准主菜单（纯代码 app 没有 MainMenu.nib）
    private func setupMainMenu() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "启动台"
        let main = NSMenu()

        // 1) 应用菜单
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: appName)
        appItem.submenu = appMenu

        func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                 _ key: String = "", _ target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }

        add(appMenu, "关于 \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())
        add(appMenu, "偏好设置…", #selector(openPreferences), ",", self)
        appMenu.addItem(.separator())

        // 服务子菜单（系统会自动填充已安装的服务）
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())

        add(appMenu, "隐藏 \(appName)", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = NSMenuItem(title: "隐藏其他",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        add(appMenu, "显示全部", #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        add(appMenu, "退出 \(appName)", #selector(NSApplication.terminate(_:)), "q")

        // 2) 文件
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        add(fileMenu, "关闭窗口", #selector(closeLaunchpadWindow), "w", self)

        // 3) 编辑：target 留空，交给第一响应者（搜索框的 field editor）处理，
        //    这样 ⌘A/C/V/X/Z 等标准编辑快捷键也能从菜单触发。
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        add(editMenu, "撤销", NSSelectorFromString("undo:"), "z")
        let redo = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        add(editMenu, "剪切", NSSelectorFromString("cut:"), "x")
        add(editMenu, "拷贝", NSSelectorFromString("copy:"), "c")
        add(editMenu, "粘贴", NSSelectorFromString("paste:"), "v")
        add(editMenu, "全选", NSSelectorFromString("selectAll:"), "a")
        editMenu.addItem(.separator())
        // 不设 keyEquivalent：⌘F 由全局键盘监听统一处理，避免两处重复触发
        add(editMenu, "查找…", #selector(focusSearchField), "", self)

        // 4) 窗口
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        add(windowMenu, "最小化", #selector(NSWindow.miniaturize(_:)), "m")
        add(windowMenu, "缩放", #selector(NSWindow.zoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu

        // 5) 帮助
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        helpItem.submenu = helpMenu
        add(helpMenu, "\(appName) 使用说明", #selector(showHelp), "?", self)

        NSApp.mainMenu = main
    }

    @objc private func openPreferences() {
        activate()
        NotificationCenter.default.post(name: .openSettingsPage, object: nil)
    }

    @objc private func closeLaunchpadWindow() {
        hideWindow()
    }

    @objc private func focusSearchField() {
        activate()
        NotificationCenter.default.post(name: .focusSearch, object: nil)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "启动台使用说明"
        alert.informativeText = """
        • 搜索：支持中文、拼音全拼与首字母、英文原名，大小写不敏感（⌘F / ⌘L 聚焦）
        • 翻页：左右拖动、触控板双指横划、滚轮、← →、点底部页码点
        • 长按图标：进入抖动编辑模式，可拖动排序、拖到另一个程序上合并成文件夹；可卸载的程序右上角会出现删除按钮
        • 点击空白或按 Esc：退出抖动模式
        • 偏好设置：⌘,
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 当前是否有文本输入框处于编辑态（SwiftUI TextField 的 field editor 是 NSTextView）
    private func isTextEditing() -> Bool {
        guard let fr = NSApp.keyWindow?.firstResponder else { return false }
        return fr is NSTextView || fr is NSTextField
    }

    // MARK: - 键盘：输入框编辑态放行所有标准编辑快捷键；非编辑态才翻页
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let editing = self.isTextEditing()
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // ⌘F / ⌘L：随时聚焦搜索框（常见「查找」快捷键）
            if flags.contains(.command), key == "f" || key == "l" {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
                return nil
            }
            if flags.contains(.command), key == "," {
                NotificationCenter.default.post(name: .openSettingsPage, object: nil)
                return nil
            }

            if event.keyCode == 53 { // Esc
                NotificationCenter.default.post(name: .escapePressed, object: nil)
                return nil
            }

            // 方向键：编辑态交回文本框（←→ 移动光标、⌥←→ 按词、⌘←→ 到行首行尾），
            // 不翻页；⌘A/C/V/X/Z、⌘⇧Z、Delete、Tab 等标准编辑键一律放行。
            if event.keyCode == 123 || event.keyCode == 124 {
                let mods = flags.intersection([.option, .command, .control, .shift])
                if editing || !mods.isEmpty { return event }
                NotificationCenter.default.post(
                    name: .pageStep, object: event.keyCode == 123 ? -1 : 1)
                return nil
            }
            // 编辑态：所有其它按键都交给 field editor（系统原生快捷键菜单）
            if editing { return event }
            return event
        }
    }

/// 把一次 scrollWheel 事件映射成路由决策。抽出来是为了能针对真实事件序列做回归：
/// 真触控板和精确滚轮都沿连续位移驱动画布；离散滚轮则保留按齿翻页。
struct ScrollGestureRouter {
    private enum Gesture { case idle, trackpad, wheel }
    private var gesture = Gesture.idle

    struct Decision {
        var allowsDelta = false
        var trackpadPath = false
        var postEnd = false
        var cancelled = false
        var gestureEnded = false
        var wheelMotion = false
    }

    /// continuous 来自官方字段 scrollWheelEventIsContinuous（非 0 = pixel-based）。
    mutating func decide(phase: NSEvent.Phase, momentum: NSEvent.Phase,
                         continuous: Bool, delta: CGFloat) -> Decision {
        let hasDelta = delta.isFinite && abs(delta) > 0.001
        let isMomentum = !momentum.isEmpty
        let ended = phase.contains(.ended) || phase.contains(.cancelled)
        var out = Decision()
        out.trackpadPath = continuous || !phase.isEmpty || isMomentum

        // 惯性只负责结束尚未吸附的触控板手势，不能重新武装或触发滚轮。
        if isMomentum {
            out.postEnd = gesture == .trackpad || gesture == .wheel
            out.gestureEnded = out.postEnd
            out.wheelMotion = gesture == .wheel
            gesture = .idle
            return out
        }
        // 先处理结束，再考虑新位移：ended 本身可以带 delta，重复 ended
        // 也可能到达；它们都不能被当作「新一串的首个非零事件」。
        if ended {
            out.cancelled = phase.contains(.cancelled)
            out.postEnd = gesture == .trackpad || gesture == .wheel
            out.allowsDelta = out.postEnd && !out.cancelled && hasDelta
            out.gestureEnded = out.postEnd
            out.wheelMotion = gesture == .wheel
            gesture = .idle
            return out
        }
        // mayBegin / changed 同样能证明是真手势，覆盖鼠标进入窗口时
        // began 已经发给其它视图的情况，不把半途进入的触控板误认成滚轮。
        if !phase.intersection([.mayBegin, .began]).isEmpty {
            gesture = .trackpad
        } else if gesture != .wheel,
                  !phase.intersection([.changed, .stationary]).isEmpty {
            gesture = .trackpad
        }
        if !continuous, phase.isEmpty {
            gesture = .idle         // 换回离散鼠标时清掉上一设备的状态
            out.allowsDelta = hasDelta
        } else if gesture == .trackpad {
            out.allowsDelta = hasDelta
        } else if gesture == .wheel {
            out.allowsDelta = hasDelta
            out.wheelMotion = true
        } else if hasDelta {
            // 精确滚轮也提供连续像素位移，按触控板方式驱动画布。
            gesture = .wheel
            out.allowsDelta = true
            out.trackpadPath = true
            out.wheelMotion = true
        }
        return out
    }
}

// MARK: - 触控板 / 滚轮
    private func setupScrollMonitor() {
        /// 有齿滚轮：一次事件翻译成一个齿
        let classifier = WheelDetentClassifier()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard let window = self.window, event.window === window,
                  window.isVisible else {
                self.scrollRouter = ScrollGestureRouter()
                self.cancelWheelScrollEnd()
                return event
            }
            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            // 垂直滚轮与水平触控板都映射到同一套水平页面位移
            let horizontal = abs(dx) > abs(dy)
            let d = horizontal ? dx : dy

            // 官方字段 scrollWheelEventIsContinuous：
            // 0 = line-based（有齿滚轮），非 0 = pixel-based（连续设备，无「齿」概念）。
            // CGEvent 不可用时回退到 NSEvent.hasPreciseScrollingDeltas。
            let isContinuous: Bool = {
                if let cg = event.cgEvent {
                    return cg.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                }
                return event.hasPreciseScrollingDeltas
            }()
            let route = self.scrollRouter.decide(phase: event.phase,
                                                 momentum: event.momentumPhase,
                                                 continuous: isContinuous,
                                                 delta: d)
            if route.postEnd || !route.wheelMotion {
                self.cancelWheelScrollEnd()
            }
            if route.allowsDelta {
                if route.trackpadPath {
                    if abs(d) > 0.001 {
                        NotificationCenter.default.post(
                            name: .pageScrollDelta, object: d,
                            userInfo: ["wheelMotion": route.wheelMotion]
                        )
                        if route.wheelMotion && !route.postEnd {
                            self.scheduleWheelScrollEnd()
                        }
                    }
                } else {
                    // 行增量与点位移必须取同一轴，避免横向滚动被纵向噪声反转。
                    var lineDelta = 0
                    if let cg = event.cgEvent {
                        lineDelta = Int(cg.getIntegerValueField(horizontal
                            ? .scrollWheelEventDeltaAxis2 : .scrollWheelEventDeltaAxis1))
                    }
                    let steps = classifier.feed(lineDelta: lineDelta, pixelDelta: d)
                    if steps != 0 {
                        NotificationCenter.default.post(
                            name: .pageScrollWheelDelta,
                            object: NSNumber(value: steps)
                        )
                        self.scheduleWheelScrollEnd()
                    }
                }
            }
            // 连续输入结束时吸附；离散滚轮仍按齿通知，不发送结束事件。
            if route.postEnd {
                NotificationCenter.default.post(name: .pageScrollEnd, object: nil,
                    userInfo: ["cancelled": route.cancelled,
                               "wheelMotion": route.wheelMotion])
            }
            if route.gestureEnded, !route.cancelled {
                self.scrollRouter = ScrollGestureRouter()
            }
            return event
        }
    }

    /// Some precise mouse wheels omit or delay AppKit's ended phase. End only
    /// wheel-like continuous input after a brief quiet period; trackpads keep
    /// their native finger-up and momentum lifecycle.
    private func scheduleWheelScrollEnd() {
        cancelWheelScrollEnd()
        let token = wheelScrollEndToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wheelScrollEndToken == token else { return }
            self.wheelScrollEndWorkItem = nil
            self.scrollRouter = ScrollGestureRouter()
            NotificationCenter.default.post(name: .pageScrollEnd, object: nil,
                                            userInfo: ["cancelled": false,
                                                       "wheelMotion": true])
        }
        wheelScrollEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1),
                                      execute: work)
    }

    private func cancelWheelScrollEnd() {
        wheelScrollEndWorkItem?.cancel()
        wheelScrollEndWorkItem = nil
        wheelScrollEndToken = UUID()
    }

    // MARK: - 点击窗口之外自动隐藏
    // 全局监听只接收「发给其它应用」的鼠标事件；发给本窗口的事件走 local monitor，
    // 所以这里基本等价于「点击了非启动台窗口/桌面」。
    private func setupGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.settings.autoHideOnOutsideClick,
                  let win = self.window, win.isVisible else { return }

            // 优先用事件自带坐标（Quartz 原点左上 → AppKit 原点左下）
            var p = NSEvent.mouseLocation
            if let cg = event.cgEvent, let screen = NSScreen.main {
                let q = cg.location
                p = NSPoint(x: q.x, y: screen.frame.maxY - q.y)
            }
            // 菜单栏 / 状态栏操作（打开菜单、恢复窗口）不触发隐藏
            if let screen = NSScreen.main, p.y >= screen.frame.maxY - 30 { return }
            // 保险：落在窗口（含圆角外扩）内也不隐藏
            if win.frame.insetBy(dx: -14, dy: -14).contains(p) { return }

            DispatchQueue.main.async { [weak self] in self?.hideWindow() }
        }
    }

    /// 兜底：点击别的窗口后本应用失焦，同样隐藏（覆盖合成点击 / 触控板等场景）
    func applicationDidResignActive(_ notification: Notification) {
        // accessory 模式（台前调度修复）下 app 本来就不参与前台竞争，
        // 系统把焦点自动还给上一个应用也会触发这里，**不代表用户点了窗口外**。
        // 若继续自动隐藏，刚打开的启动台会在 1~2s 后自己消失。
        // 点击窗口外的隐藏交给 setupGlobalClickMonitor 精确判定。
        guard NSApp.activationPolicy() == .regular,
              settings.autoHideOnOutsideClick else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !NSApp.isActive,
                  self.window?.isVisible == true else { return }
            self.hideWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Finder 双击 / Dock 图标重新唤起时按当前可见状态切换窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        toggleForReopen()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 刚因「点击应用」隐藏过窗口时，不让重新激活把窗口弹回来
        guard Date() > suppressReactivateUntil else { return }
        // 隐藏窗口只由明确的打开入口（Dock reopen、菜单栏、手势）重新显示。
        guard windowShouldBeVisible, window?.isVisible == true else { return }
        activate()
    }
}

/// 视图层调用：启动目标应用后只隐藏窗口，保留后台进程。
/// 只发通知，隐藏动作统一由 AppDelegate.hideWindow() 走淡出动画；
/// 这里不再直接 orderOut，否则会绕过动画并重复隐藏。
/// 下次点 Dock 图标由 applicationShouldHandleReopen → activate() 淡入。
func hideLaunchpadWindow() {
    NotificationCenter.default.post(name: .hideLaunchpad, object: nil)
}

extension Notification.Name {
    static let openSettingsPage = Notification.Name("openSettingsPage")
    static let focusSearch = Notification.Name("focusSearch")
    static let escapePressed = Notification.Name("escapePressed")
    static let pageStep = Notification.Name("pageStep")   // object: Int
    static let pageScrollDelta = Notification.Name("pageScrollDelta")       // 触控板手势位移
    static let pageScrollWheelDelta = Notification.Name("pageScrollWheelDelta") // 传统滚轮
    static let pageScrollEnd = Notification.Name("pageScrollEnd")           // 触控板手指抬起
    static let pagingInputReset = Notification.Name("pagingInputReset")     // 窗口隐藏，丢弃旧输入
    static let hideLaunchpad = Notification.Name("hideLaunchpad")
    /// 只淡出窗口（Esc / 关闭窗口），不清缓存、不抑制重激活
    static let hideWindowAnimated = Notification.Name("hideWindowAnimated")
    static let launchpadDidActivate = Notification.Name("launchpadDidActivate")
    static let installedAppsDidChange = Notification.Name("installedAppsDidChange")
    /// 跨进程：重复启动的实例请求已有实例显示窗口
    static let launchpadReopenRequest = Notification.Name("com.local.launchpad.reopen")
}

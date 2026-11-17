import SwiftUI
import AppKit
import Combine

/// 果冻弹性进度曲线：轻微冲过目标再收回（easeOutBack）+ 一次衰减摆动，
/// 模仿鼠标拖拽 settlePaging 的低阻尼 spring。
/// 逐帧曲线严格在 duration 内结束，避免不同设备的动画收敛时长不一致。
/// 过冲控制在约 1~2% 位移（≈ 10~20pt），不会露出三页画布外的空白。
func jellyProgress(_ p: CGFloat, jelly: CGFloat) -> CGFloat {
    let j = min(max(jelly, 0), 1)
    let c1 = 0.35 + 0.45 * j
    let c3 = c1 + 1
    let q = p - 1
    let back = 1 + c3 * q * q * q + c1 * q * q
    let wobble = (0.004 + 0.008 * j) * CGFloat(sin(Double(p) * 2 * .pi)) * (1 - p)
    return back + wobble
}

/// 主启动台视图：老 Launchpad 式分页，拖动时两页并排且完全跟手
struct LaunchpadView: View {
    @StateObject private var store = LaunchpadStore()
    @ObservedObject private var settings = SettingsStore.shared

    @State private var showSettings = false
    @State private var openedFolder: (name: String, items: [AppItem])? = nil
    @FocusState private var searchFocused: Bool

    // 普通引用（不是 @StateObject）：主视图不订阅位移变更，
    // 只有 PagingCanvas 用 @ObservedObject 订阅 → 每帧仅更新一次 transform
    private let motion = PagingMotion.shared
    @State private var pagingActive = false
    @State private var pagingSnapshot: PagingSnapshot?
    @State private var pagingRevision = 0
    @State private var pageDragging = false
    @State private var iconDragging = false
    @State private var areaSize: CGSize = CGSize(width: 840, height: 484)
    /// 网格可用区在根窗口坐标系中的位置，用于把文件夹拖出的松手点换算成插槽
    @State private var gridFrameInRoot: CGRect = .zero
    /// 当前分页画布正在吸附
    @State private var settling = false
    @State private var pendingWheelSteps = 0
    @State private var pendingWheelEnded = false
    /// 动画尚未提交时，新的滚轮请求应以即将到达的页为基准。
    @State private var pagingTarget: Int?
    /// 跨页拖动：当前被拖的项（由 DraggableGrid 报告）
    @State private var draggedID: String?
    /// 拖图标时触控板累计的切页位移
    @State private var dragSwipe: CGFloat = 0
    /// 跨页拖动时整页容器的滑入位移（与翻页动画同方向、同时长）
    @State private var crossSlide: CGFloat = 0
    /// 跨页滑入进行中：防止边缘计时器 / 惯性事件重复触发翻页把状态搅乱
    @State private var crossAnimating = false
    /// 从文件夹内拖出时的实时落点（全局索引），网格据此让位补位
    @State private var externalDropIndex: Int?
    /// 拖到左右边缘的悬停计时
    @State private var edgeTimer: DispatchSourceTimer?

    /// 两页之间额外的留白，用来明确区分不同页
    private let pageGap: CGFloat = 140
    private var jelly: CGFloat { CGFloat(settings.jellyStrength) }
    /// 设置面板 / 文件夹弹窗在前台时，主网格不响应任何翻页输入
    /// （鼠标拖动、触控板、滚轮、方向键都锁住）
    private var pagingLocked: Bool { showSettings || openedFolder != nil }

    var body: some View {
        ZStack {
            LiquidGlassBackground(intensity: CGFloat(settings.glassIntensity))
                .equatable()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 26)

                if settings.showCategories {
                    CategoryPills(store: store)
                        .padding(.top, 14)
                }

                GeometryReader { geo in
                    pagingArea(width: geo.size.width, height: geo.size.height)
                        .onAppear {
                            areaSize = geo.size
                            gridFrameInRoot = geo.frame(in: .named("launchpadRoot"))
                            refreshSnapshot()
                        }
                        .onChange(of: geo.size.width) { _, _ in
                            areaSize = geo.size
                            gridFrameInRoot = geo.frame(in: .named("launchpadRoot"))
                            refreshSnapshot()
                        }
                        .onChange(of: geo.size.height) { _, _ in
                            areaSize = geo.size
                            gridFrameInRoot = geo.frame(in: .named("launchpadRoot"))
                            refreshSnapshot()
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.horizontal, 30)
                .padding(.top, 18)

                if settings.multiPage, store.pageCount > 1 {
                    pageDots
                        .padding(.top, 6)
                        .padding(.bottom, 20)
                } else {
                    Color.clear.frame(height: 26)
                }
            }

            if let f = openedFolder {
                FolderPanel(
                    name: f.name, items: f.items, store: store,
                    onClose: {
                        externalDropIndex = nil
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            openedFolder = nil
                        }
                    },
                    onCloseImmediate: {
                        // 拖出成功：不做关闭动画，避免面板 / 遮罩回弹一帧再淡出
                        externalDropIndex = nil
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { openedFolder = nil }
                    },
                    onPullDrag: { _, point in
                        // 只有跨格子时才改 @State，避免每帧重建主视图
                        let idx = point.flatMap { insertionIndex(for: $0) }
                        if externalDropIndex != idx { externalDropIndex = idx }
                    },
                    onPullEnd: { app, point in
                        // 松手落在哪个格子，就插到那里，后面的图标依次后移；
                        // 多页时超出本页容量的项由分页切片自然挤到下一页。
                        store.removeFromFolder(app.id, folderName: f.name,
                                               fallback: app,
                                               insertAt: insertionIndex(for: point))
                        externalDropIndex = nil
                        // 兜底再上一次点击锁：定时器收尾可能晚于 mouseUp
                        store.suppressGridTapUntil = Date().addingTimeInterval(0.5)
                    },
                    onRenamed: { new in
                        openedFolder = (name: new, items: f.items)
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.86).combined(with: .opacity),
                    removal: .scale(scale: 0.92).combined(with: .opacity)
                ))
                .zIndex(80)
            }

            if showSettings {
                SettingsView(settings: settings, store: store) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        showSettings = false
                    }
                }
                .zIndex(100)
            }
        }
        .coordinateSpace(name: "launchpadRoot")
        .frame(minWidth: 700, minHeight: 500)
        .modifier(GlassWindowFrame(intensity: CGFloat(settings.glassIntensity)))
        .onAppear {
            if CommandLine.arguments.contains("--open-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        showSettings = true
                    }
                }
            }
            if CommandLine.arguments.contains("--open-folder") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // 调试入口：打开成员最多的真实文件夹，方便验证多页 / 3×3 布局
                    let folders: [(String, [AppItem])] = store.items.compactMap { gi in
                        if case .folder(let n, let apps) = gi { return (n, apps) }
                        return nil
                    }
                    if let f = folders.max(by: { $0.1.count < $1.1.count }) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            openedFolder = f
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsPage)) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { showSettings = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchpadDidActivate)) { _ in
            refreshAppsIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .installedAppsDidChange)) { _ in
            // 应用目录变了（安装 / 卸载 / 移动 .app）：窗口即使藏在后台也同步。
            refreshAppsIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            // ⌘F / ⌘L 聚焦搜索框并选中已有内容，方便直接改关键词
            showSettings = false
            openedFolder = nil
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .escapePressed)) { _ in
            if showSettings {
                withAnimation { showSettings = false }
            } else if openedFolder != nil {
                withAnimation { openedFolder = nil }
            } else if searchFocused || !store.searchText.isEmpty {
                // 老 Launchpad 手感：Esc 先清空搜索并退出编辑，不直接隐藏窗口
                store.searchText = ""
                searchFocused = false
            } else {
                // 统一走淡出动画，不再直接隐藏整个 app
                NotificationCenter.default.post(name: .hideWindowAnimated, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageStep)) { note in
            let d = (note.object as? Int) ?? 0
            if d != 0, !pagingLocked { animateToPage(store.page + d) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageScrollDelta)) { note in
            // 弹窗在前台时滚轮/触控板归弹窗自己处理，绝不翻主窗口页
            guard !pagingLocked else { return }
            // 连续输入跟手位移，结束事件到达时再吸附
            handleScroll(delta(from: note))
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageScrollWheelDelta)) { note in
            guard !pagingLocked else { return }
            // 传统滚轮：收到的已经是归一化翻页请求
            handleWheelStep(wheelSteps(from: note))
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageScrollEnd)) { note in
            guard !pagingLocked else { return }
            if settling, note.userInfo?["wheelMotion"] as? Bool == true {
                pendingWheelEnded = true
                return
            }
            guard pagingActive, !settling, !pageDragging else { return }
            settlePaging(cancelled: note.userInfo?["cancelled"] as? Bool ?? false,
                         fromScroll: true,
                         wheelMotion: note.userInfo?["wheelMotion"] as? Bool ?? false)
        }
        .onChange(of: settings.multiPage) { _, _ in
            resetPagingInput()
            store.page = 0
            store.clampPage()
        }
        .onChange(of: pagingLocked) { _, locked in
            if locked { resetPagingInput() }
        }
        .onChange(of: store.searchText) { _, _ in
            resetPagingInput()
            store.page = 0
        }
        .onChange(of: store.selectedCategory) { _, _ in
            resetPagingInput()
            store.page = 0
        }
        .onChange(of: store.pageCount) { _, _ in resetPagingInput() }
        .onReceive(NotificationCenter.default.publisher(for: .pagingInputReset)) { _ in
            resetPagingInput()
        }
    }

    /// 按磁盘现状同步程序列表。拖拽中 / 翻页中 / 弹窗开着时先跳过，
    /// 免得刷新把正在进行的排序或文件夹内容打乱；下次事件会再补上。
    private func refreshAppsIfIdle() {
        guard !iconDragging, !pageDragging, !showSettings,
              openedFolder == nil else { return }
        store.refreshInstalledApps()
    }

    // MARK: - 顶部
    private var topBar: some View {
        ZStack {
            searchField
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 32, height: 32)
                        .glassSurface(intensity: CGFloat(settings.glassIntensity),
                                      cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 34)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.65))
                .font(.system(size: 14))
            TextField("搜索", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 400)
        .glassSurface(intensity: CGFloat(settings.glassIntensity), cornerRadius: 12)
    }

    // MARK: - 几何
    private struct Metrics {
        let icon: CGFloat, cw: CGFloat, ch: CGFloat
        let gw: CGFloat, gh: CGFloat
        let leftPad: CGFloat, topPad: CGFloat, stride: CGFloat
    }

    private func metrics(width w: CGFloat, height h: CGFloat) -> Metrics {
        let iconSize = CGFloat(settings.iconSize)
        let cw = GridMetrics.cellW(iconSize: iconSize, width: w)
        let ch = GridMetrics.cellH(iconSize: iconSize, height: h)
        let icon = GridMetrics.displayIcon(iconSize: iconSize, cellHeight: ch)
        let gw = CGFloat(GridMetrics.cols) * cw
        let gh = CGFloat(GridMetrics.rows) * ch
        return Metrics(
            icon: icon, cw: cw, ch: ch, gw: gw, gh: gh,
            leftPad: (w - gw) / 2,
            topPad: max(0, (h - gh) / 2),
            stride: w + pageGap
        )
    }

    /// 把「拖出文件夹时的松手点」换算成全局扁平索引；
    /// 插到该索引会让该位置及之后的图标依次后移，即挤开效果。
    private func insertionIndex(for point: CGPoint) -> Int? {
        let f = gridFrameInRoot
        guard f.width > 1, f.height > 1 else { return nil }
        let x = point.x - f.minX
        let y = point.y - f.minY
        // 只把「拖到网格左 / 上方之外」当作放弃；右 / 下方（例如压在
        // 页码点或底部留白）一律吸附到最后一格，避免松手后图标凭空回到
        // 文件夹旁边、看起来像没拖成功。
        guard x >= 0, y >= 0 else { return nil }
        let cw = f.width / CGFloat(GridMetrics.cols)
        let ch = f.height / CGFloat(GridMetrics.rows)
        let col = min(GridMetrics.cols - 1, max(0, Int(x / cw)))
        let row = min(GridMetrics.rows - 1, max(0, Int(y / ch)))
        return store.page * kPageSize + row * GridMetrics.cols + col
    }

    /// 拖图标到网格左右边缘：悬停 0.45s 后翻到相邻页，继续停留则继续翻
    private func handlePageEdge(_ edge: DragEdge?) {
        edgeTimer?.cancel()
        edgeTimer = nil
        guard let edge, draggedID != nil, settings.multiPage,
              edge == .left || edge == .right else { return }
        let dir = edge == .right ? 1 : -1
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(450),
                   repeating: .milliseconds(750))
        t.setEventHandler {
            guard self.draggedID != nil else {
                self.edgeTimer?.cancel()
                self.edgeTimer = nil
                return
            }
            self.crossPageDrag(to: self.store.page + dir)
        }
        edgeTimer = t
        t.resume()
    }

    /// 跨页移动：先切页、再把被拖项挪到新页。顺序不能反 ——
    /// 否则切页前当前页会短暂不含被拖项，DraggableGrid 会清掉拖拽状态。
    private func crossPageDrag(to newPage: Int) {
        guard let id = draggedID, newPage >= 0, newPage < store.pageCount,
              !crossAnimating else { return }
        crossAnimating = true
        let m = metrics(width: areaSize.width, height: areaSize.height)
        let dir: CGFloat = newPage > store.page ? -1 : 1
        // 下一页从右侧滑入、上一页从左侧滑入，与 animateToPage 的方向和时长一致
        let startOffset = -dir * m.stride * 0.35
        store.commitPage(newPage)
        store.relocate(itemID: id, toGlobalIndex: newPage * kPageSize)
        dragSwipe = 0
        // 动画交给渲染层（只改 2 次 @State），主视图不会逐帧重算
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { crossSlide = startOffset }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.26)) { self.crossSlide = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            self.crossAnimating = false
            self.consumeWheelSteps()
        }
    }

    private func currentPageView() -> some View {
        DraggableGrid(
            store: store,
            settings: settings,
            iconDragging: $iconDragging,
            draggedID: $draggedID,
            onPageEdge: { edge in handlePageEdge(edge) },
            externalDropIndex: externalDropIndex,
            pageItems: store.pageItems(store.page),
            page: store.page,
            onOpenFolder: { name, items in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    openedFolder = (name, items)
                }
            }
        )
        // 刻意不加 .id(page)：跨页拖动时保持视图身份，长按+拖动手势才不会中断
    }

    /// 进入分页时冻结三页内容；拖动全程只读 motion.offset，不重建图标
    private func refreshSnapshot() {
        let m = metrics(width: areaSize.width, height: areaSize.height)
        let p = store.page
        let previous = p > 0 ? store.pageItems(p - 1) : nil
        let current = store.pageItems(p)
        let next = p + 1 < store.pageCount ? store.pageItems(p + 1) : nil
        if let existing = pagingSnapshot,
           existing.page == p,
           existing.prev == previous,
           existing.current == current,
           existing.next == next,
           existing.icon == m.icon, existing.cw == m.cw, existing.ch == m.ch,
           existing.width == areaSize.width, existing.height == areaSize.height,
           existing.stride == m.stride {
            return
        }
        pagingRevision += 1
        pagingSnapshot = PagingSnapshot(
            revision: pagingRevision,
            page: p,
            prev: previous,
            current: current,
            next: next,
            icon: m.icon, cw: m.cw, ch: m.ch,
            width: areaSize.width, height: areaSize.height,
            stride: m.stride
        )
    }

    private func beginPaging() {
        refreshSnapshot()
        motion.offset = 0
        pagingActive = true
    }

    private func endPaging() {
        motion.stopFrames()
        pagingActive = false
        pagingTarget = nil
        motion.offset = 0
        settling = false
        // 让上一轮滚动的「停止判定」回调全部失效，避免紧接着新手势时被旧回调清场
        motion.generation += 1
    }

    private func finishPageTransition() {
        let current = store.page
        let target = pagingTarget ?? current
        guard let snap = pagingSnapshot else {
            endPaging()
            consumeWheelSteps()
            return
        }

        let m = metrics(width: areaSize.width, height: areaSize.height)
        let shift = target - snap.page
        let destination = target + shift
        let currentItems: [GridItem]
        if shift > 0 {
            currentItems = snap.next ?? snap.current
        } else if shift < 0 {
            currentItems = snap.prev ?? snap.current
        } else {
            currentItems = snap.current
        }
        pagingRevision += 1
        pagingSnapshot = PagingSnapshot(
            revision: pagingRevision,
            page: target,
            prev: target > 0
                ? (shift > 0 ? snap.current : store.pageItems(target - 1)) : nil,
            current: currentItems,
            next: destination >= 0 && destination < store.pageCount
                ? store.pageItems(destination) : nil,
            icon: m.icon, cw: m.cw, ch: m.ch,
            width: areaSize.width, height: areaSize.height,
            stride: m.stride
        )
        pagingTarget = nil
        motion.offset = 0
        settling = false
        pagingActive = false
        let ended = pendingWheelEnded
        pendingWheelEnded = false
        if ended {
            DispatchQueue.main.async {
                if self.pagingActive {
                    self.settlePaging(fromScroll: true, wheelMotion: true)
                }
            }
        }
        if pendingWheelSteps != 0 {
            DispatchQueue.main.async { self.consumeWheelSteps() }
        }
    }

    private func resetPagingInput() {
        pendingWheelSteps = 0
        pendingWheelEnded = false
        pageDragging = false
        dragSwipe = 0
        endPaging()
    }

    private func pagingArea(width w: CGFloat, height h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 保留交互网格的视图身份：分页时只将其隐藏，由冻结的静态画布覆盖。
            // 条件式移除/重建会销毁 AsyncIcon 的 StateObject，缓存未命中时图标会闪成占位。
            currentPageView()
                .offset(x: crossSlide)
                .opacity(pagingActive ? 0 : 1)
                .allowsHitTesting(!pagingActive)

            if let snap = pagingSnapshot {
                PagingCanvas(snap: snap, motion: motion)
                    .opacity(pagingActive ? 1 : 0)
                    .allowsHitTesting(pagingActive)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .contentShape(Rectangle())
        .simultaneousGesture(pagingGesture(width: w, height: h))
    }

    private func pagingGesture(width w: CGFloat, height h: CGFloat) -> some Gesture {
        return DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard settings.multiPage, store.pageCount > 1,
                      !iconDragging, !pagingLocked, !settling else { return }
                let t = v.translation
                guard abs(t.width) > abs(t.height) * 1.3 else { return }
                if !pageDragging {
                    pendingWheelSteps = 0
                    beginPaging()
                    pageDragging = true
                }
                var x = t.width
                if (x > 0 && store.page == 0) ||
                    (x < 0 && store.page == store.pageCount - 1) { x *= 0.3 }
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { motion.offset = x }
            }
            .onEnded { _ in
                guard settings.multiPage, pageDragging, !pagingLocked else { return }
                settlePaging()
            }
    }

    private func delta(from note: Notification) -> CGFloat {
        if let v = note.object as? CGFloat { return v }
        if let n = note.object as? NSNumber { return CGFloat(n.doubleValue) }
        return 0
    }

    /// 滚轮通知携带归一化的翻页步数（向下滚为负）
    private func wheelSteps(from note: Notification) -> Int {
        if let v = note.object as? Int { return v }
        if let n = note.object as? NSNumber { return n.intValue }
        return 0
    }

    /// 连续滚动直接驱动画布；跨页时刷新页快照并保留剩余位移。
    private func handleScroll(_ d: CGFloat, smoothWheelStep: Bool = false) {
        // 拖图标期间触控板也能切页：不走分页画布（会中断手势），
        // 累计位移越过阈值就直接跨页，手势继续在新页排序。
        if iconDragging {
            guard settings.multiPage, store.pageCount > 1, !pagingLocked,
                  d != 0 else { return }
            dragSwipe += d
            if abs(dragSwipe) > 140 {
                let dir = dragSwipe < 0 ? 1 : -1
                crossPageDrag(to: store.page + dir)
            }
            return
        }
        guard settings.multiPage, store.pageCount > 1, !pagingLocked,
              !pageDragging, d != 0 else { return }
        if settling {
            guard pagingTarget != nil else { return }
            motion.stopFrames()
            settling = false
            pagingTarget = nil
            pendingWheelEnded = false
            motion.generation += 1
        }
        let started = !pagingActive
        if started { beginPaging() }
        let m = metrics(width: areaSize.width, height: areaSize.height)
        let startingPage = store.page
        let startingOffset = motion.offset
        let rawOffset = motion.offset + d
        let advanced = advancePagingOffset(page: store.page,
                                            pageCount: store.pageCount,
                                            offset: rawOffset,
                                            stride: m.stride)
        if advanced.page != store.page {
            store.commitPage(advanced.page)
            refreshSnapshot()
        }
        var next = advanced.offset
        if (store.page == 0 && next > 0) ||
            (store.page == store.pageCount - 1 && next < 0) {
            next *= 0.2
        }

        if smoothWheelStep {
            motion.stopFrames()
            motion.generation += 1
            let pageShift = advanced.page - startingPage
            // 快照跨页后换算到新页坐标，动画起点保持在原来的屏幕位置。
            motion.offset = startingOffset + CGFloat(pageShift) * m.stride
            let g = motion.generation
            motion.animateOffset(to: next, duration: 0.045, jelly: 0,
                                generation: g, linear: true, completion: {})
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                motion.offset = max(-m.stride, min(m.stride, next))
            }
            motion.generation += 1
        }
        // 连续位移不使用超时吸附，等待触控板或精确滚轮发出结束事件。
    }

    /// 接收源头归一化的离散请求，不再用像素大小猜物理齿数。
    private func handleWheelStep(_ steps: Int) {
        guard settings.multiPage, store.pageCount > 1, !pagingLocked,
              !pageDragging, steps != 0 else { return }
        let m = metrics(width: areaSize.width, height: areaSize.height)
        handleScroll(wheelPagingDelta(steps: steps, stride: m.stride),
                     smoothWheelStep: true)
    }

    /// 逐页消费有效请求：一次只跑一页动画，反向或内容变化会清理旧请求。
    private func consumeWheelSteps() {
        guard settings.multiPage, store.pageCount > 1, !pagingLocked,
              !pageDragging, !pagingActive, !settling else { return }
        // 跨页拖动还没结束时先保留请求，不提前消费。
        guard !iconDragging || !crossAnimating, pendingWheelSteps != 0 else { return }
        let step = pendingWheelSteps > 0 ? 1 : -1
        let target = store.page + step
        guard target >= 0, target < store.pageCount else {
            pendingWheelSteps = 0
            return
        }
        if iconDragging {
            pendingWheelSteps -= step
            crossPageDrag(to: target)
        } else {
            pendingWheelSteps -= step
            animateToPage(target, respectCooldown: false)
        }
    }

    /// 鼠标松手 / 滚动停止共用的果冻吸附
    private func settlePaging(cancelled: Bool = false, fromScroll: Bool = false,
                              wheelMotion: Bool = false) {
        settling = true          // 吸附期间不再接收位移，避免打断弹簧动画
        let m = metrics(width: areaSize.width, height: areaSize.height)
        let x = motion.offset
        let threshold = fromScroll ? pagingSettleThreshold(stride: m.stride)
                                   : m.stride * 0.16
        let reached = !cancelled && abs(x) >= threshold

        var target = store.page
        var settle: CGFloat = 0
        if reached, x < 0, store.page < store.pageCount - 1 {
            target = store.page + 1
            settle = -m.stride
        } else if reached, x > 0, store.page > 0 {
            target = store.page - 1
            settle = m.stride
        }
        pageDragging = false
        pagingTarget = target
        let g = motion.generation
        let duration = pagingSettleDuration(fromScroll: fromScroll, wheelMotion: wheelMotion)
        motion.animateOffset(to: settle, duration: duration, jelly: jelly,
                             generation: g) {
            guard self.motion.generation == g else { return }
            if target != store.page { store.commitPage(target) }
            self.finishPageTransition()
            self.consumeWheelSteps()
        }
    }

    /// 方向键 / 点页码点 / 有齿滚轮：使用与拖拽吸附一致的 spring。
    private func animateToPage(_ target: Int, respectCooldown: Bool = true) {
        guard settings.multiPage, !pageDragging, !pagingActive,
              target >= 0, target < store.pageCount,
              target != store.page,
              (respectCooldown ? store.canChangePage : true) else { return }
        let m = metrics(width: areaSize.width, height: areaSize.height)
        let dir: CGFloat = target > store.page ? -1 : 1
        beginPaging()
        pagingTarget = target
        settling = true
        motion.generation += 1
        let g = motion.generation
        let end = dir * m.stride
        motion.stopFrames()
        motion.animateOffset(to: end, duration: respectCooldown ? 0.21 : 0.26, jelly: jelly,
                             generation: g) {
            guard self.motion.generation == g else { return }
            self.store.commitPage(target)
            self.finishPageTransition()
            self.consumeWheelSteps()
        }
    }

    // MARK: - 底部页码点
    private var pageDots: some View {
        HStack(spacing: 9) {
            ForEach(0..<store.pageCount, id: \.self) { i in
                let active = i == store.page
                Circle()
                    .fill(active ? Color.white : Color.white.opacity(0.30))
                    .frame(width: active ? 8 : 7, height: active ? 8 : 7)
                    .overlay(
                        Circle().stroke(Color.white.opacity(active ? 0.9 : 0.12), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .animation(.easeInOut(duration: 0.10), value: store.page)
                    .contentShape(Circle().size(CGSize(width: 16, height: 16)))
                    .onTapGesture { animateToPage(i) }
            }
        }
    }
}

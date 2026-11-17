import SwiftUI
import AppKit
import Combine

/// 设置页 / 文件夹面板的圆形关闭按钮：官方液态玻璃圆底 + 深灰叉。
/// 不用 SF Symbol 的 `xmark.circle.fill`：它的叉是挖空的，压在浅色内容上
/// 会连叉一起糊掉。自绘叉在任何底色上都清晰。
struct CircleXButton: View {
    var size: CGFloat = 17
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                XMarkShape()
                    .stroke(Color(white: 0.20, opacity: 0.9),
                            style: StrokeStyle(lineWidth: size * 0.10,
                                               lineCap: .round))
                    .padding(size * 0.33)
            }
            .frame(width: size, height: size)
            .glassSurface(intensity: 0.7, cornerRadius: size / 2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct XMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

/// 分类 pills（可点击筛选）
struct CategoryPills: View {
    @ObservedObject var store: LaunchpadStore
    @ObservedObject var settings = SettingsStore.shared

    private let categories = [
        "开发者工具", "工具", "效率与财务", "社交",
        "娱乐", "信息与阅读", "创意", "其他",
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // 不再用 GlassEffectContainer：融合渲染会把胶囊里的文字一起
            // 卷进折射层，字看起来发虚。每颗胶囊各自一块玻璃更清晰。
            pillsRow
                .padding(.horizontal, 34)
                // 给选中态的投影 / 轻微放大留出空间，别被 ScrollView 裁掉
                .padding(.vertical, 8)
        }
    }

    private var pillsRow: some View {
        HStack(spacing: 8) {
            pill("全部", selected: store.selectedCategory == nil) {
                store.selectedCategory = nil
                store.page = 0
            }
            ForEach(categories, id: \.self) { cat in
                pill(cat, selected: store.selectedCategory == cat) {
                    store.selectedCategory = cat
                    store.page = 0
                }
            }
        }
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? Color.black.opacity(0.88)
                                          : Color.white.opacity(0.88))
                // 白底上的深色字不能再叠暗影，否则边缘发虚
                .shadow(color: selected ? .clear : .black.opacity(0.42),
                        radius: 0.8, y: 0.4)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        // 选中态做成实心亮胶囊 + 深色文字，与液态玻璃强度无关。
                        // 旧版只把 intensity 乘 1.4，强度拉到 0 时两者完全一样，
                        // 用户就看不到「当前选中的是哪一个」。
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.94))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.95), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.32), radius: 7, y: 2)
                    } else {
                        // 未选中：保持官方液态玻璃，字体仍是白色
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                            .glassSurface(intensity: CGFloat(settings.glassIntensity) * 0.8,
                                          cornerRadius: 20, interactive: false)
                    }
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(selected ? 1.04 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: selected)
    }
}

/// 文件夹展开面板：3×3 分页，切页位移与主窗口翻页一致（跟手 + 果冻吸附）；
/// 分页与否跟随设置里的「多页显示」开关。
struct FolderPanel: View {
    let name: String
    let items: [AppItem]
    @ObservedObject var store: LaunchpadStore
    @ObservedObject var settings = SettingsStore.shared
    var onClose: () -> Void
    /// 拖出成功后的关闭：不走消失动画，面板直接移除
    var onCloseImmediate: () -> Void = {}
    /// 拖离文件夹的过程中持续上报位置（根窗口坐标系），nil 表示清除落点预览
    var onPullDrag: (AppItem, CGPoint?) -> Void
    /// 松手：把应用插入当前落点
    var onPullEnd: (AppItem, CGPoint) -> Void
    /// 点击标题重命名后，通知上层同步面板标题
    var onRenamed: (String) -> Void

    private let cols = 3
    private let pageSize = 9                 // 3 × 3
    private let panelW: CGFloat = 390
    private let pageW: CGFloat = 354
    /// 面板高度按实际行数收紧：小文件夹不再留一大片空白
    private var maxRows: Int {
        guard settings.multiPage else { return 3 }
        return min(3, max(1, (displayItems.count + cols - 1) / cols))
    }
    /// 每行约 97pt（58 图标 + 5 间距 + 28 标签 + 6 行距）
    private var contentH: CGFloat { CGFloat(maxRows) * 97 + 8 }
    private var effectivePanelH: CGFloat {
        43 + contentH + (folderPageCount > 1 ? 26 : 12)
    }

    @State private var folderPage = 0
    /// 切页跟手位移：0 时停在 activePage，拖动中随手指平移
    @State private var folderOffset: CGFloat = 0
    @State private var wheelAccum: CGFloat = 0
    @State private var lastPageSwitch = Date.distantPast
    @State private var draggingApp: AppItem?
    @State private var dragPoint: CGPoint = .zero
    /// 面板内排序用的本地顺序（松手才写回 store）
    @State private var localItems: [AppItem] = []
    /// 图标是否已拖出面板（此时弹窗收起，网格接管落点）
    @State private var pulledOut = false
    /// 面板出现时间：忽略「点开文件夹的那一下」落在遮罩上导致的立即关闭
    @State private var appearedAt = Date.distantPast
    /// 拖出面板时最后一次事件时间：手势被系统取消后强制收尾，避免浮层卡住
    @State private var lastPullAt = Date.distantPast
    /// 最后一次拖动位置（根窗口坐标系）。手势被取消时用这个点完成落点，
    /// 不会拿不到 onEnded 的 location 而把图标永远留在半空。
    @State private var lastPullPoint: CGPoint = .zero
    /// 一次拖拽只允许收尾一次：onEnded 与定时器兜底可能同时到达
    @State private var pullFinalized = false
    /// 拖出成功、面板正在消失：只有这时才整体关闭点击命中
    @State private var dismissing = false
    private let pullTicker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var jelly: CGFloat { CGFloat(settings.jellyStrength) }
    private var displayItems: [AppItem] { localItems.isEmpty ? items : localItems }

    /// 单页开关与文件夹同步：多页开 → 文件夹分页；关 → 全部成员一页滚动
    private var folderPageCount: Int {
        guard settings.multiPage else { return 1 }
        return max(1, (displayItems.count + pageSize - 1) / pageSize)
    }

    private var activePage: Int { min(max(folderPage, 0), folderPageCount - 1) }

    private func items(onPage p: Int) -> [AppItem] {
        if !settings.multiPage { return displayItems }
        let start = p * pageSize
        guard start < displayItems.count else { return [] }
        return Array(displayItems[start..<min(start + pageSize, displayItems.count)])
    }

    // MARK: - 切页：位移连续 + spring 吸附，与主窗口手感一致

    /// 提交到某一页：先补偿 offset 让画面位置不跳，再 spring 归零
    private func commitFolderPage(_ target: Int) {
        let t = min(max(target, 0), folderPageCount - 1)
        let oldBase = -CGFloat(activePage) * pageW + folderOffset
        folderPage = t
        folderOffset = oldBase + CGFloat(t) * pageW
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84 - 0.18 * jelly)) {
            folderOffset = 0
        }
    }

    /// 滚轮 / 触控板切页（带冷却，避免一次手势连翻）
    private func switchFolderPage(by d: Int) {
        guard folderPageCount > 1 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPageSwitch) > 0.30 else { return }
        let t = activePage + d
        guard t >= 0, t < folderPageCount else { return }
        lastPageSwitch = now
        commitFolderPage(t)
    }

    private func switchFolderPage(to p: Int) {
        guard p != activePage else { return }
        commitFolderPage(p)
    }

    private func scrollDelta(_ note: Notification) -> CGFloat {
        if let v = note.object as? CGFloat { return v }
        if let n = note.object as? NSNumber { return CGFloat(n.doubleValue) }
        return 0
    }

    /// 面板在根窗口坐标系中的矩形（外扩 12pt 避免边缘误判）
    private func panelRect() -> CGRect {
        let win = NSApp.windows.first(where: { $0.frame.width >= 600 })?.contentView?.bounds
            ?? CGRect(x: 0, y: 0, width: 900, height: 640)
        return CGRect(x: (win.width - panelW) / 2,
                      y: (win.height - effectivePanelH) / 2,
                      width: panelW, height: effectivePanelH).insetBy(dx: -12, dy: -12)
    }

    /// 面板内拖动：按 3 列网格把图标插到指针所在格子，实时重排
    private func reorderInside(app: AppItem, point: CGPoint) {
        let r = panelRect()
        let lx = point.x - r.minX - 18
        let ly = point.y - r.minY - 52
        guard lx >= 0, ly >= 0 else { return }
        let col = min(cols - 1, max(0, Int(lx / 118)))
        let row = max(0, Int(ly / 97))
        let pageBase = settings.multiPage ? activePage * pageSize : 0
        let target = min(pageBase + row * cols + col, max(0, displayItems.count - 1))
        var arr = displayItems
        guard let from = arr.firstIndex(where: { $0.id == app.id }), from != target else { return }
        let moved = arr.remove(at: from)
        arr.insert(moved, at: min(target, arr.count))
        localItems = arr
    }

    /// 一次拖动的唯一收尾入口。
    /// onEnded 与「鼠标已松开」定时器都会调它，用 pullFinalized 去重。
    /// 面板在拖出时会缩放 / 淡出，SwiftUI 有时会直接取消手势、不给 onEnded，
    /// 这时定时器仍会兜底完成落点并关闭面板，图标不会卡在半空。
    private func finishPull() {
        guard let app = draggingApp, !pullFinalized else { return }
        pullFinalized = true
        let point = lastPullPoint
        let wasOut = pulledOut
        if wasOut {
            dismissing = true
            // 松手的 mouseUp 会落到主网格图标上：先上锁，
            // 免得它把目标应用启动 / 把另一个文件夹打开。
            store.suppressGridTapUntil = Date().addingTimeInterval(0.5)
            onPullDrag(app, nil)
            onPullEnd(app, point)
            onCloseImmediate()
        } else {
            onPullDrag(app, nil)
            store.reorderFolder(name, order: displayItems.map { $0.id })
        }
        draggingApp = nil
        // 拖出成功时面板正在被移除：不要把 pulledOut 复位。
        // 否则 .animation(value: pulledOut) 会把面板从 0.6 / 透明弹回
        // 1 / 不透明，遮罩也跟着从全透明跳回半透明，紧接着播放关闭淡出
        // —— 就是用户看到的「文件夹窗口闪一下」。
        if !wasOut { pulledOut = false }
    }

    /// 打开文件夹后点标题即可重命名（与右键菜单同一套逻辑）
    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = name
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let new = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !new.isEmpty, new != name else { return }
            store.renameFolder(name, to: new)
            onRenamed(new)
        }
    }

    /// 跟手拖动切页：边界阻尼 + 松手按阈值吸附，跟主窗口翻页同一套逻辑
    private var folderPagingGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard draggingApp == nil, settings.multiPage, folderPageCount > 1 else { return }
                var x = v.translation.width
                if (x > 0 && activePage == 0) ||
                    (x < 0 && activePage == folderPageCount - 1) { x *= 0.3 }
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { folderOffset = x }
            }
            .onEnded { v in
                guard draggingApp == nil, settings.multiPage, folderPageCount > 1 else { return }
                let x = v.translation.width
                let threshold = pageW * 0.18
                var target = activePage
                if x < -threshold, activePage < folderPageCount - 1 { target += 1 }
                else if x > threshold, activePage > 0 { target -= 1 }
                commitFolderPage(target)
            }
    }

    /// 单页 3×3 网格（含文件夹内排序 / 拖出面板 / 右键移出）
    @ViewBuilder
    private func pageGrid(page: Int) -> some View {
        let list = items(onPage: page)
        LazyVGrid(
            columns: Array(repeating: SwiftUI.GridItem(.fixed(104), spacing: 14),
                           count: cols),
            spacing: 6
        ) {
            ForEach(list) { app in
                let isDragging = draggingApp?.id == app.id
                AppIconView(item: app, size: 58)
                    .opacity(isDragging ? 0 : 1)
                    .onTapGesture {
                        // 拖出面板时松手的 mouseUp 也可能被当成一次点击
                        guard !pulledOut, draggingApp == nil else { return }
                        AppLauncher.launch(app)
                        onClose()
                        hideLaunchpadWindow()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 12,
                                    coordinateSpace: .named("launchpadRoot"))
                            .onChanged { v in
                                if draggingApp == nil {
                                    pullFinalized = false
                                    dismissing = false
                                }
                                draggingApp = app
                                dragPoint = v.location
                                lastPullPoint = v.location
                                lastPullAt = Date()
                                if panelRect().contains(v.location) {
                                    pulledOut = false
                                    onPullDrag(app, nil)
                                    reorderInside(app: app, point: v.location)
                                } else {
                                    pulledOut = true
                                    // 拖出过程中持续上锁：定时器兜底可能晚于
                                    // mouseUp 到达，提前上锁才能挡住那一下误点击。
                                    store.suppressGridTapUntil =
                                        Date().addingTimeInterval(0.5)
                                    onPullDrag(app, v.location)
                                }
                            }
                            .onEnded { v in
                                lastPullPoint = v.location
                                finishPull()
                            }
                    )
                    .contextMenu {
                        Button("移出文件夹") {
                            store.removeFromFolder(app.id, folderName: name, fallback: app)
                            onClose()
                        }
                    }
            }
        }
        .padding(.horizontal, 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.85),
                   value: displayItems.map { $0.id })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(pulledOut ? 0.0 : 0.34)
                .ignoresSafeArea()
                // 拖出后这层全屏遮罩虽然透明，但仍会截获点击；
                // 一旦失手没关掉面板，整个主网格都会「点不动」。
                .allowsHitTesting(!pulledOut && draggingApp == nil)
                .onTapGesture {
                    guard !pulledOut, draggingApp == nil,
                          Date().timeIntervalSince(appearedAt) > 0.25 else { return }
                    onClose()
                }

            VStack(spacing: 0) {
                HStack {
                    Text(name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .onTapGesture {
                            guard !pulledOut else { return }
                            promptRename()
                        }
                        .help("点击重命名文件夹")
                    Spacer()
                    CircleXButton(action: {
                        guard !pulledOut else { return }
                        onClose()
                    })
                        .padding(.leading, 6)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)

                // 图标直接浮在面板的液态玻璃上，不再给格子 / 内容区垫矩形玻璃底片
                Group {
                    if settings.multiPage {
                        // 多页并排 + 整体位移，切页时不瞬切
                        HStack(spacing: 0) {
                            ForEach(0..<folderPageCount, id: \.self) { p in
                                pageGrid(page: p)
                                    .frame(width: pageW)
                            }
                        }
                        .offset(x: -CGFloat(activePage) * pageW + folderOffset)
                        .frame(width: pageW, alignment: .leading)
                        .clipped()
                    } else {
                        // 单页：全部成员一页内上下滚动，不分页
                        ScrollView(.vertical, showsIndicators: false) {
                            pageGrid(page: 0)
                        }
                    }
                }
                .frame(width: pageW, height: contentH)
                .contentShape(Rectangle())
                .simultaneousGesture(folderPagingGesture)
                .padding(.horizontal, 18)

                if folderPageCount > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<folderPageCount, id: \.self) { i in
                            Circle()
                                .fill(i == activePage
                                      ? Color.white.opacity(0.9)
                                      : Color.white.opacity(0.32))
                                .frame(width: 7, height: 7)
                                .padding(5)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !pulledOut else { return }
                                    switchFolderPage(to: i)
                                }
                        }
                    }
                    .frame(height: 26)
                } else {
                    Color.clear.frame(height: 12)
                }
            }
            .frame(width: panelW, height: effectivePanelH)
            // 拖出成功后面板还在做消失动画，这期间不再截获任何点击，
            // 否则主网格会短暂「点不动」。面板内排序不触发。
            .allowsHitTesting(!dismissing)
            .background(
                // 面板本身是唯一一块液态玻璃：压暗极淡，让官方玻璃真正透出来
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.08))
                    .glassSurface(intensity: CGFloat(settings.glassIntensity), cornerRadius: 22)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
            .scaleEffect(pulledOut ? 0.6 : (draggingApp == nil ? 1 : 0.94))
            .opacity(pulledOut ? 0 : (draggingApp == nil ? 1 : 0.92))
            // 收尾期间关掉这两条动画，避免 draggedApp / pulledOut 归零时
            // 面板在移除前先「回弹」一帧
            .animation(dismissing ? nil : .easeOut(duration: 0.18), value: pulledOut)
            .animation(dismissing ? nil : .easeOut(duration: 0.18), value: draggingApp?.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onAppear {
                appearedAt = Date()
                folderPage = 0
                folderOffset = 0
                wheelAccum = 0
                localItems = items
            }

            // 被拖出的图标脱离面板，始终跟在鼠标上
            if let app = draggingApp {
                IconTile(item: .app(app), size: 76, showLabel: false)
                    .scaleEffect(1.1)
                    .shadow(color: .black.opacity(0.55), radius: 16, y: 10)
                    .position(dragPoint)
                    .allowsHitTesting(false)
                    .zIndex(50)
            }
        }
        // 弹窗在前台时滚轮 / 触控板只切「文件夹内的页」：
        // LaunchpadView 收到同样通知但被 pagingLocked 挡掉，主窗口不会跟着翻页。
        .onReceive(NotificationCenter.default.publisher(for: .pageScrollWheelDelta)) { note in
            guard folderPageCount > 1 else { return }
            // 通知携带的是物理格数（向下为负）：按格数算目标页，
            // 不走 switchFolderPage 的 0.30s 冷却，否则连滚几格会被吞。
            let steps = Int(scrollDelta(note))
            guard steps != 0 else { return }
            let dir = steps < 0 ? 1 : -1
            let target = min(max(activePage + dir * abs(steps), 0),
                             folderPageCount - 1)
            if target != activePage { commitFolderPage(target) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageScrollDelta)) { note in
            guard folderPageCount > 1 else { return }
            wheelAccum += scrollDelta(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageScrollEnd)) { note in
            let d = wheelAccum
            wheelAccum = 0
            guard note.userInfo?["cancelled"] as? Bool != true else { return }
            guard abs(d) > 60 else { return }
            switchFolderPage(by: d < 0 ? 1 : -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pagingInputReset)) { _ in
            wheelAccum = 0
        }
        .onReceive(pullTicker) { _ in
            // 面板拖出时会缩放 / 淡出，系统的 DragGesture 可能被直接取消、
            // onEnded 永远不来，于是浮层图标卡在半空、面板也关不掉。
            // 这里按硬件鼠标状态兜底：主键已松开且短暂没有新拖动事件就收尾。
            guard draggingApp != nil, !pullFinalized else { return }
            let mouseDown = (NSEvent.pressedMouseButtons & 1) != 0
            if !mouseDown, Date().timeIntervalSince(lastPullAt) > 0.12 {
                finishPull()
            }
        }
        .coordinateSpace(name: "folderRoot")
    }
}

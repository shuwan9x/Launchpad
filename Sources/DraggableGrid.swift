import SwiftUI
import AppKit
import Combine

/// 拖动图标碰到的网格边缘
enum DragEdge { case left, right, up, down }

/// 单页模式下拖到上/下边缘时，直接驱动窗口里的 NSScrollView 自动滚动。
/// 网格内容是 SwiftUI 绝对定位的 ZStack，用 AppKit 滚动容器最省事、也不改布局。
/// 返回实际滚动量，供拖拽落点跟着换算（与多页跨页拖拽一致）
@discardableResult
private func autoScrollGrid(by dy: CGFloat) -> CGFloat {
    func find(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = find(sub) { return s } }
        return nil
    }
    guard let win = NSApp.windows.first(where: { $0.frame.width >= 600 }),
          let root = win.contentView,
          let sv = find(root), let doc = sv.documentView else { return 0 }
    let oldY = sv.contentView.bounds.origin.y
    var origin = sv.contentView.bounds.origin
    origin.y += doc.isFlipped ? dy : -dy
    let maxY = max(0, doc.bounds.height - sv.contentView.bounds.height)
    origin.y = min(max(origin.y, 0), maxY)
    guard origin.y != oldY else { return 0 }
    sv.contentView.setBoundsOrigin(origin)
    sv.reflectScrolledClipView(sv.contentView)
    return origin.y - oldY
}

/// 7 列可拖拽网格
/// - 多页：固定 4 行、整块在可用区域内上下左右居中
/// - 单页：按应用数量动态增行，超高时可滚动
/// - 果冻动画仅在拖拽期间生效；切换分类/翻页时图标直接换，不弹跳
struct DraggableGrid: View {
    @ObservedObject var store: LaunchpadStore
    @ObservedObject var settings: SettingsStore
    /// 告诉外层：正在拖图标，此时不要响应翻页手势
    @Binding var iconDragging: Bool
    /// 当前被拖的项 id：跨页拖动时外层需要它来做 relocate
    @Binding var draggedID: String?
    /// 拖到网格边缘（左/右）时通知外层翻页；离开边缘传 nil
    var onPageEdge: (DragEdge?) -> Void
    /// 从文件夹内拖出时的实时落点（全局索引）：网格据此让出空位、其他图标自动补位
    let externalDropIndex: Int?

    let pageItems: [GridItem]
    let page: Int
    var onOpenFolder: (String, [AppItem]) -> Void

    private let cols = GridMetrics.cols
    private let fixedRows = GridMetrics.rows

    // MARK: 拖拽状态
    @State private var dragID: String?
    /// 当前停留的边缘（只在变化时通知外层，避免每个手势事件都重置翻页计时）
    @State private var currentEdge: DragEdge?
    /// 跨页后手势若被系统打断，用于快速收尾（避免浮层卡住）
    @State private var crossPageAt: Date?
    @State private var lastDragSize: CGSize = .zero
    @State private var lastDragRows: Int = GridMetrics.rows
    @State private var dragPoint: CGPoint = .zero
    @State private var lastPoint: CGPoint = .zero
    @State private var dragVelocity: CGFloat = 0
    @State private var insertIndex: Int = 0
    @State private var hoverID: String?
    @State private var hoverSince: Date?
    @State private var hoverArmed = false
    @State private var dropping = false
    /// 合并写入布局后继续保持一小段「拖拽态」，让其他图标的顺次补位带果冻动画
    @State private var mergeAnimating = false
    /// 被拖图标吸入目标文件夹时的缩小 / 淡出
    @State private var absorbing = false
    /// 手势被系统打断时的兜底：记录最后一次拖动事件时间
    @State private var lastDragTime = Date()
    /// 只有真的拖动过才抑制紧随其后的那一次「松手 = 点击启动」。
    /// 之前用「长按达成时间戳 + 0.45s 判断」，SwiftUI 在普通单击时也会误置位，
    /// 结果把每一次单击都拦掉（图标与文件夹都点不开）。
    @State private var suppressNextTap = false

    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var jelly: CGFloat { CGFloat(settings.jellyStrength) }
    private var iconSize: CGFloat { CGFloat(settings.iconSize) }

    private var preferredCellW: CGFloat { iconSize + 36 }
    private var preferredCellH: CGFloat { iconSize + 40 }

    /// 单页时按实际数量算行数
    private var rowCount: Int {
        if !settings.multiPage {
            return max(fixedRows, (pageItems.count + cols - 1) / cols)
        }
        return fixedRows
    }

    // MARK: 顺序与几何
    private func order(insertAt: Int, drag: String?) -> [String] {
        let ids = pageItems.map { $0.id }
        guard let d = drag else { return ids }
        var arr = ids.filter { $0 != d }
        arr.insert(d, at: min(max(insertAt, 0), arr.count))
        return arr
    }

    /// 拖动中的显示顺序：被拖项完全脱离布局，不再占原来的格子；
    /// 用一个不渲染的空位标记表示落点，其余图标依次补位。
    private let gapID = "__lp_gap__"
    private func displayOrder(rows: Int) -> [String] {
        let ids = pageItems.map { $0.id }
        var arr: [String] = []
        var trailingID: String? = nil

        if let d = dragID {
            arr = ids.filter { $0 != d }
            arr.insert(gapID, at: min(max(insertIndex, 0), arr.count))
            // 末尾保留被拖项的视图身份：跨页时 ForEach 不会销毁长按+拖动手势的宿主，
            // 否则手势被系统取消、onEnded 不来，浮层会一直卡在半空。
            // 它本身透明（.opacity(0)），不占可见格子。
            trailingID = d
        } else if let g = externalDropIndex {
            // 从文件夹内拖出：按实时落点让出一个空位，其余图标依次补位
            arr = ids
            let local = g - page * kPageSize
            arr.insert(gapID, at: min(max(local, 0), arr.count))
        } else {
            return ids
        }

        // 每页容量硬上限：多页时插入空位会让当前页变成 29 项，
        // 多出来的那一项必须交给分页切片挤到下一页，绝不能在
        // 当前页第 5 行画出来（ZStack 不裁剪，会漏到页码点上方）。
        let cap = settings.multiPage ? kPageSize : rows * cols
        if arr.count > cap { arr = Array(arr.prefix(cap)) }
        // 透明的手势宿主不能参与容量裁剪，否则跨页拖拽会被系统取消
        if let t = trailingID, !arr.contains(t) { arr.append(t) }
        return arr
    }

    private func center(for index: Int, size: CGSize, rows: Int) -> CGPoint {
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        let c = index % cols, r = index / cols
        return CGPoint(x: (CGFloat(c) + 0.5) * cw, y: (CGFloat(r) + 0.5) * ch)
    }

    private func slot(at p: CGPoint, size: CGSize, rows: Int) -> Int {
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        let c = min(max(Int(p.x / cw), 0), cols - 1)
        let r = min(max(Int(p.y / ch), 0), rows - 1)
        return r * cols + c
    }

    /// 合并目标判定：拖到「已有文件夹」加入，拖到「另一个程序」新建文件夹。
    /// 命中框严格限制在目标图标本体的矩形内（略留一点外扩方便触发），
    /// 不会像圆形半径那样在格子边缘甚至相邻格误命中。
    /// 位置一律用拖动前的原始布局，不受补位影响。
    private func hoverTarget(at p: CGPoint, drag: String, size: CGSize, rows: Int) -> String? {
        // 文件夹本身不参与合并（不支持文件夹嵌套）
        if let dragged = pageItems.first(where: { $0.id == drag }), dragged.isFolder {
            return nil
        }
        let ch = size.height / CGFloat(rows)
        let icon = GridMetrics.displayIcon(iconSize: iconSize, cellHeight: ch)
        // 外扩 14pt：格子中心相距约 120pt，两个命中框合计 108pt 不重叠，
        // 因此不会误命中相邻格，但更容易「压到」目标图标上。
        let half = icon / 2 + 14
        var best: (String, CGFloat)?
        for (idx, gi) in pageItems.enumerated() where gi.id != drag {
            let c = center(for: idx, size: size, rows: rows)
            let iconY = c.y - 16          // 与命中层 .offset(y: -16) 对齐
            let dx = abs(p.x - c.x), dy = abs(p.y - iconY)
            if dx <= half, dy <= half {
                let d = hypot(dx, dy)
                if best == nil || d < best!.1 { best = (gi.id, d) }
            }
        }
        return best?.0
    }

    private func jellySpring(_ extraDelay: Double = 0) -> Animation {
        .spring(response: 0.40,
                dampingFraction: 0.88 - 0.32 * jelly,
                blendDuration: 0.08)
            .delay(extraDelay)
    }

    // MARK: - 外层：居中 + 可滚动
    var body: some View {
        GeometryReader { geo in
            let rows = rowCount
            let cw = GridMetrics.cellW(iconSize: iconSize, width: geo.size.width)
            let ch = settings.multiPage
                ? GridMetrics.cellH(iconSize: iconSize, height: geo.size.height)
                : preferredCellH
            let gSize = CGSize(width: CGFloat(cols) * cw, height: CGFloat(rows) * ch)
            let topPad = max(0, (geo.size.height - gSize.height) / 2)

            let content = gridContent(size: gSize, rows: rows)
                .frame(width: gSize.width, height: gSize.height)
                // 显式指定与可用区等宽 + 居中对齐，确保左右严格居中
                .frame(width: geo.size.width, alignment: .center)
                .padding(.top, topPad)   // 上下留白由 topPad 承担

            Group {
                if settings.multiPage {
                    // 多页：不包 ScrollView，彻底禁用上下滑动
                    content
                } else {
                    // 单页：全部应用一页，拖图标到上/下边缘时由
                    // autoScrollGrid 程序化滚屏，所以这里不能 scrollDisabled，
                    // 否则 SwiftUI 会把滚动容器整体冻结、边缘自动滚动失效。
                    ScrollView(.vertical, showsIndicators: false) { content }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: - 网格本体
    private func gridContent(size s: CGSize, rows: Int) -> some View {
        let ord = displayOrder(rows: rows)
        // 格子尺寸固定；图标只在自己的格子里按 iconSize 缩放
        let shownIcon = GridMetrics.displayIcon(
            iconSize: iconSize, cellHeight: s.height / CGFloat(rows)
        )
        let itemMap: [String: GridItem] = Dictionary(
            uniqueKeysWithValues: pageItems.map { ($0.id, $0) }
        )

        return ZStack(alignment: .topLeading) {
            ForEach(Array(ord.enumerated()), id: \.element) { index, id in
                if let item = itemMap[id] {
                    let c = center(for: index, size: s, rows: rows)
                    let dist: CGFloat = dragID == nil ? 9999 :
                        hypot(dragPoint.x - c.x, dragPoint.y - c.y)
                    let push: CGFloat = dragID == nil ? 1 :
                        1 + 0.055 * jelly * exp(-dist / 85)
                    let dragging = dragID != nil || externalDropIndex != nil
                        || mergeAnimating

                    ZStack {
                        // 合并预览：灰色轮廓初现 → 有限放大到 1.18（不循环）
                        if hoverID == id, dragging {
                            RoundedRectangle(cornerRadius: shownIcon * 0.2237 + 4,
                                             style: .continuous)
                                .fill(Color.gray.opacity(hoverArmed ? 0.30 : 0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: shownIcon * 0.2237 + 4,
                                                     style: .continuous)
                                        .stroke(Color.gray.opacity(hoverArmed ? 0.95 : 0.5),
                                                lineWidth: 2)
                                )
                                .frame(width: shownIcon + 8, height: shownIcon + 8)
                                .scaleEffect(hoverArmed ? 1.10 : 0.90)
                                .opacity(hoverArmed ? 1 : 0.45)
                                .animation(.spring(response: 0.42, dampingFraction: 0.82),
                                           value: hoverArmed)
                                .offset(y: -14)
                        }

                        IconTile(item: item, size: shownIcon)
                            .scaleEffect(hoverID == id && hoverArmed ? 1.0 : push)

                        // 命中层只覆盖图标本体：标签文字、格子空白都不触发
                        // 点击或拖动，符合老 Launchpad 的手感。
                        Color.clear
                            .frame(width: shownIcon, height: shownIcon)
                            .contentShape(Rectangle())
                            .offset(y: -16)
                            .onTapGesture {
                                // 文件夹拖出时，松手的 mouseUp 会落到目标图标上，
                                // 不抑制就会误启动应用 / 误打开另一个文件夹。
                                // 时间戳窗口自动过期，不会永久吞掉下一次正常单击。
                                let blocked = suppressNextTap
                                    || Date() < store.suppressGridTapUntil
                                if blocked {
                                    suppressNextTap = false
                                    store.suppressGridTapUntil = .distantPast
                                    return
                                }
                                activate(item)
                            }
                            .gesture(dragGesture(for: item, size: s, rows: rows))
                    }
                    .frame(width: s.width / CGFloat(cols), height: s.height / CGFloat(rows))
                    // 用 offset 把格子左上角移到目标位置（不用 .position，
                    // 它会让每个格子占据整个网格，后层会吃掉前层点击）。
                    .offset(x: c.x - s.width / CGFloat(cols) / 2,
                            y: c.y - s.height / CGFloat(rows) / 2)
                    .opacity(dragID == id ? 0 : 1)
                    // 果冻只在拖拽期间生效，分类切换/翻页时不做弹性动画
                    .animation(dragging ? jellySpring(Double(index) * 0.010) : nil,
                               value: ord)
                    .animation(dragging
                               ? .spring(response: 0.28, dampingFraction: 0.72 - 0.15 * jelly)
                               : nil,
                               value: dragPoint)
                    .contextMenu { contextMenu(for: item) }
                }
            }

            if let d = dragID, let item = itemMap[d] {
                let tilt = min(max(dragVelocity / 26, -8), 8)
                IconTile(item: item, size: shownIcon, showLabel: false)
                    .scaleEffect(x: (1.10 + abs(tilt) * 0.004) * (absorbing ? 0.32 : 1),
                                 y: (1.10 - abs(tilt) * 0.003) * (absorbing ? 0.32 : 1))
                    .rotationEffect(.degrees(Double(tilt)))
                    .opacity(absorbing ? 0 : 1)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
                    .position(x: dragPoint.x, y: dragPoint.y - 15)
                    .allowsHitTesting(false)
                    .zIndex(50)
            }
        }
        .frame(width: s.width, height: s.height, alignment: .topLeading)
        .coordinateSpace(name: "grid")
        .onReceive(ticker) { _ in
            let now = Date()
            // 拖到普通程序上停留 0.22s 才新建文件夹；
            // 快速划过只排序，停住才合并。armed 之前已有浅灰轮廓作提示。
            if let h = hoverID, !hoverArmed, let since = hoverSince,
               dragID != nil,
               !(pageItems.first(where: { $0.id == h })?.isFolder ?? false),
               now.timeIntervalSince(since) >= 0.22 {
                hoverArmed = true
            }
            // 单页模式：拖到上/下边缘时持续自动滚动，直到离开边缘或松手。
            // 滚动量换算回网格坐标重算落点，让其它图标继续顺次补位，
            // 效果与多页模式「拖到边缘跨页后继续调整排序」一致。
            if dragID != nil, !settings.multiPage, let e = currentEdge {
                let dy: CGFloat = e == .up ? -18 : 18
                let moved = autoScrollGrid(by: dy)
                if moved != 0, hoverID == nil {
                    let p = CGPoint(x: dragPoint.x, y: dragPoint.y + moved)
                    insertIndex = min(slot(at: p, size: lastDragSize, rows: lastDragRows),
                                      max(0, pageItems.count - 1))
                }
            }
            // 跨页切换可能让系统取消手势（onEnded 不来）：
            // 跨页后 1.6s 内若 0.8s 没有新拖动事件，主动收尾，避免浮层卡在半空。
            if dragID != nil, !dropping, let at = crossPageAt,
               now.timeIntervalSince(at) < 1.6,
               now.timeIntervalSince(lastDragTime) > 0.8,
               let item = pageItems.first(where: { $0.id == dragID }) {
                crossPageAt = nil
                applyDragEnd(item: item, size: lastDragSize, rows: lastDragRows)
            }
            // 手势被系统打断导致 onEnded 没来时，4 秒后自动收尾，
            // 避免拖拽浮层永远卡在屏幕上造成「图标重叠」
            if dragID != nil, !dropping, now.timeIntervalSince(lastDragTime) > 4 {
                dragID = nil
                draggedID = nil
                currentEdge = nil
                onPageEdge(nil)
                hoverID = nil
                hoverSince = nil
                hoverArmed = false
                iconDragging = false
            }
        }
        .onChange(of: page) { _, _ in
            // 记录跨页时刻；之后若手势被系统打断，用短兜底快速收尾
            if dragID != nil { crossPageAt = Date() }
        }
        .onChange(of: pageItems.count) { _, _ in
            // 跨页拖动期间（先切页、再 relocate）当前页数量会短暂变化，
            // 一律保留 dragID，手势不断才能在新页继续调整排序。
            if draggedID != nil { return }
            // 合并成文件夹等真实数量变化才清空中间态
            dragID = nil
            draggedID = nil
            currentEdge = nil
            onPageEdge(nil)
            hoverID = nil
            hoverSince = nil
            hoverArmed = false
            dropping = false
            iconDragging = false
        }
        .onChange(of: store.isFiltering) { _, filtering in
            // 搜索 / 分类切换时不再重建视图（跨页拖动需要保留身份），
            // 这里主动清掉拖拽中间态，避免浮层残留。
            if filtering {
                dragID = nil
                draggedID = nil
                currentEdge = nil
                onPageEdge(nil)
                hoverID = nil
                hoverSince = nil
                hoverArmed = false
                dropping = false
                iconDragging = false
            }
        }
        .onDisappear {
            dragID = nil
            draggedID = nil
            currentEdge = nil
            onPageEdge(nil)
            hoverID = nil
            hoverSince = nil
            hoverArmed = false
            iconDragging = false
        }
    }

    // MARK: - 拖拽手势（长按阈值 0.30s，比原来的 0.35s 短，又不至于鼠标停留误触发）
    //
    // 长按只作为「开始拖动排序 / 合并文件夹」的门槛，不再进入任何编辑态；
    // LongPressGesture 达成后 DragGesture 接管，可直接排序 / 合并 / 跨页，
    // 视图身份保持不变，避免手势被系统取消导致「图标卡在半空」。
    private func dragGesture(for item: GridItem, size: CGSize, rows: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.30)
            .sequenced(before: DragGesture(minimumDistance: 0,
                                           coordinateSpace: .named("grid")))
            .onChanged { value in
                switch value {
                case .first(true):
                    // 长按达成只是拖拽门槛，不写任何状态：
                    // 普通单击也会走到这里，写状态会误吞点击
                    break
                case .second(_, let drag):
                    if let drag {
                        applyDragChange(drag, item: item, size: size, rows: rows)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .second(_, let drag):
                    if drag != nil { applyDragEnd(item: item, size: size, rows: rows) }
                default:
                    break
                }
            }
    }

    private func applyDragChange(_ v: DragGesture.Value, item: GridItem,
                                 size: CGSize, rows: Int) {
        guard !store.isFiltering, !dropping else { return }
        iconDragging = true
        suppressNextTap = true     // 真的开始拖动了，抑制松手时可能被误发的 tap
        lastDragSize = size
        lastDragRows = rows
        let p = v.location
        if dragID == nil {
            dragID = item.id
            draggedID = item.id
            dragPoint = p
            lastPoint = p
            insertIndex = pageItems.firstIndex(where: { $0.id == item.id }) ?? 0
            hoverID = nil
            hoverArmed = false
            hoverSince = nil
        }
        dragVelocity = p.x - lastPoint.x
        lastPoint = p
        dragPoint = p
        lastDragTime = Date()

        // 被拖项在原始布局中的位置
        let origIndex = pageItems.firstIndex(where: { $0.id == item.id }) ?? 0
        let rawSlot = slot(at: p, size: size, rows: rows)
        let othersCount = pageItems.count - 1
        // 合并判定始终基于「拖动前的原始布局」，不受补位影响
        let hit = hoverTarget(at: p, drag: item.id, size: size, rows: rows)

        if let h = hit {
            let targetIsFolder = pageItems.first(where: { $0.id == h })?.isFolder ?? false
            if hoverID != h {
                hoverID = h
                hoverSince = Date()
                // 拖到已有文件夹：立刻进入合并态（最容易触发）
                // 拖到普通程序：短暂停留才新建文件夹，避免排序划过时误合并
                hoverArmed = targetIsFolder
            }
            // 指针进入目标图标本体即冻结补位：空位放回被拖项原位，
            // 所有其它图标（含目标文件夹）保持原始位置不被挤走。
            // 判定用原始布局、显示也是原始布局，两者自洽不会抖。
            // hoverArmed 只决定松手时是「合并」还是「排序」。
            insertIndex = origIndex
        } else {
            hoverID = nil
            hoverSince = nil
            hoverArmed = false
            insertIndex = min(rawSlot, othersCount)
        }

        // 边缘吸附：多页左右翻页交给外层；单页上下自动滚动由 ticker 驱动
        let edge: DragEdge?
        if settings.multiPage {
            if p.x < 44 { edge = .left }
            else if p.x > size.width - 44 { edge = .right }
            else { edge = nil }
        } else {
            if p.y < 44 { edge = .up }
            else if p.y > size.height - 44 { edge = .down }
            else { edge = nil }
        }
        if edge != currentEdge {
            currentEdge = edge
            if settings.multiPage { onPageEdge(edge) }
        }
    }

    private func applyDragEnd(item: GridItem, size: CGSize, rows: Int) {
        iconDragging = false
        // 手势若被系统取消、没有紧随的 tap 来消费抑制标记，兜底清掉，
        // 避免下一次正常单击被误吞（只留很短的窗口）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            suppressNextTap = false
        }
        draggedID = nil
        currentEdge = nil
        onPageEdge(nil)
        guard let d = dragID else { return }
        if dropping {
            dragID = nil
            hoverID = nil
            hoverSince = nil
            hoverArmed = false
            dropping = false
            return
        }
        let mergeTarget = hoverArmed ? hoverID : nil
        // 冻结补位时 insertIndex 是「被拖项原位」，若没合并就不能拿它当排序落点，
        // 否则图标会弹回原处。按指针所在格重新算落点。
        let sortAt = mergeTarget == nil
            ? min(slot(at: dragPoint, size: size, rows: rows), pageItems.count - 1)
            : insertIndex
        let ord = order(insertAt: sortAt, drag: d)
        let finalIndex = ord.firstIndex(of: d) ?? 0
        let ch = size.height / CGFloat(rows)
        let cw = size.width / CGFloat(cols)
        var target = CGPoint(
            x: (CGFloat(finalIndex % cols) + 0.5) * cw,
            y: (CGFloat(finalIndex / cols) + 0.5) * ch
        )
        // 合并时让被拖图标吸入目标图标本体（而不是自己排序后的落点）
        if let t = mergeTarget,
           let ti = pageItems.firstIndex(where: { $0.id == t }) {
            // 图标本体在格子中心偏上 16pt，吸入点对齐它才不会「飞到图标下方」
            target = CGPoint(x: (CGFloat(ti % cols) + 0.5) * cw,
                             y: (CGFloat(ti / cols) + 0.5) * ch - 16)
        }

        let merging = mergeTarget != nil
        dropping = true
        withAnimation(.spring(response: merging ? 0.28 : 0.38,
                              dampingFraction: 0.86 - 0.30 * jelly)) {
            dragPoint = target
            dragVelocity = 0
            absorbing = merging       // 吸入时缩小淡出
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (merging ? 0.24 : 0.30)) {
            if let t = mergeTarget {
                // 保持「拖拽态」一小段，让合并后其余图标的顺次补位走果冻动画，
                // 而不是瞬间跳到新位置。
                mergeAnimating = true
                store.merge(dragID: d, onto: t)
            } else {
                store.commitReorder(page: page, orderedIDs: ord)
            }
            dragID = nil
            hoverID = nil
            hoverSince = nil
            hoverArmed = false
            dropping = false
            absorbing = false
            if merging {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    mergeAnimating = false
                }
            }
        }
    }

    // MARK: - 交互
    private func activate(_ item: GridItem) {
        switch item {
        case .app(let a):
            AppLauncher.launch(a)
            hideLaunchpadWindow()
        case .folder(let name, let items):
            onOpenFolder(name, items)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: GridItem) -> some View {
        switch item {
        case .app(let a):
            Button("在访达中显示") {
                if let path = a.path {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button("重置所有排序") { store.resetLayout() }
        case .folder(let name, _):
            Button("重命名文件夹") { renameFolder(name) }
            Button("重置所有排序") { store.resetLayout() }
        }
    }

    private func renameFolder(_ old: String) {
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = old
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameFolder(old, to: tf.stringValue)
        }
    }
}

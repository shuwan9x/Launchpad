import SwiftUI
import Dispatch

struct PagingOffsetAdvance: Equatable {
    let page: Int
    let offset: CGFloat
}

func pagingSettleThreshold(stride: CGFloat) -> CGFloat {
    max(1, stride * 0.04)
}

func wheelPagingDelta(steps: Int, stride: CGFloat) -> CGFloat {
    -CGFloat(steps) * stride * 0.52
}

func pagingSettleDuration(fromScroll: Bool, wheelMotion: Bool) -> TimeInterval {
    0.26
}

func advancePagingOffset(page: Int, pageCount: Int, offset: CGFloat,
                         stride: CGFloat) -> PagingOffsetAdvance {
    guard pageCount > 0, stride.isFinite, stride > 0, offset.isFinite else {
        return PagingOffsetAdvance(page: max(0, page), offset: 0)
    }

    var nextPage = min(max(page, 0), pageCount - 1)
    var remainder = offset
    while remainder <= -stride, nextPage < pageCount - 1 {
        nextPage += 1
        remainder += stride
    }
    while remainder >= stride, nextPage > 0 {
        nextPage -= 1
        remainder -= stride
    }
    return PagingOffsetAdvance(page: nextPage,
                               offset: min(stride, max(-stride, remainder)))
}

/// 分页偏移只写入宿主图层，不发布 SwiftUI 状态。
/// 页面内容由 SwiftUI 托管，逐帧位移不触发布局或视图树更新。
final class PagingMotion {
    static let shared = PagingMotion()
    var offset: CGFloat = 0 {
        didSet { applyOffset?(offset) }
    }
    var applyOffset: ((CGFloat) -> Void)?
    /// 手势代数：让被中断的旧动画回调失效。
    var generation = 0
    /// 整页翻页的逐帧驱动（GCD 定时源，不受 runloop mode / App Nap 节流影响）
    var frameTimer: DispatchSourceTimer?

    func stopFrames() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    func animateOffset(to target: CGFloat, duration: TimeInterval, jelly: CGFloat,
                       generation expectedGeneration: Int,
                       linear: Bool = false,
                       completion: @escaping () -> Void) {
        stopFrames()
        let from = offset
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        frameTimer = timer
        timer.schedule(deadline: .now() + .milliseconds(1),
                       repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            let progress = min(1, max(0, Date().timeIntervalSince(start) / duration))
            let eased = linear ? CGFloat(progress)
                               : jellyProgress(CGFloat(progress), jelly: jelly)
            self.offset = from + (target - from) * eased
            if progress >= 1 {
                self.stopFrames()
                completion()
            }
        }
        timer.resume()
    }
}

/// 进入分页时冻结的页面快照：拖动全程不再读 store，也不重建图标视图。
/// revision 递增才代表内容需要刷新，数组本身不参与比较（GridItem 非 Equatable）。
struct PagingSnapshot: Equatable {
    let revision: Int
    let page: Int
    let prev: [GridItem]?
    let current: [GridItem]
    let next: [GridItem]?
    let icon: CGFloat
    let cw: CGFloat
    let ch: CGFloat
    let width: CGFloat
    let height: CGFloat
    let stride: CGFloat

    static func == (lhs: PagingSnapshot, rhs: PagingSnapshot) -> Bool {
        lhs.revision == rhs.revision && lhs.page == rhs.page
            && lhs.icon == rhs.icon && lhs.cw == rhs.cw && lhs.ch == rhs.ch
            && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.stride == rhs.stride
    }
}

/// 上一页 / 当前页 / 下一页一次画好，位移由外层整体平移。
/// 不随 offset 改变而重算 body：Equatable 命中后 SwiftUI 直接复用渲染树。
struct PagingPages: View, Equatable {
    let snap: PagingSnapshot

    static func == (lhs: PagingPages, rhs: PagingPages) -> Bool {
        lhs.snap == rhs.snap
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let prev = snap.prev { page(prev, offset: -snap.stride) }
            page(snap.current, offset: 0)
            if let next = snap.next { page(next, offset: snap.stride) }
        }
        .frame(width: snap.width, height: snap.height, alignment: .topLeading)
    }

    private func page(_ items: [GridItem], offset: CGFloat) -> some View {
        StaticGrid(items: items, iconSize: snap.icon, cw: snap.cw, ch: snap.ch)
            .equatable()
            .frame(width: snap.width, height: snap.height, alignment: .center)
            .offset(x: offset, y: 0)
    }
}

/// 页面快照由 SwiftUI 托管，逐帧位移直接更新宿主图层变换。
struct PagingCanvas: NSViewRepresentable {
    let snap: PagingSnapshot
    let motion: PagingMotion

    func makeNSView(context: Context) -> PagingCanvasHostView {
        let view = PagingCanvasHostView(frame: NSRect(x: 0, y: 0,
                                                       width: snap.width,
                                                       height: snap.height))
        view.setSnapshot(snap)
        motion.applyOffset = { [weak view] value in view?.setOffset(value) }
        view.setOffset(motion.offset)
        return view
    }

    func updateNSView(_ nsView: PagingCanvasHostView, context: Context) {
        nsView.setSnapshot(snap)
        motion.applyOffset = { [weak nsView] value in nsView?.setOffset(value) }
        nsView.setOffset(motion.offset)
    }

    static func dismantleNSView(_ nsView: PagingCanvasHostView, coordinator: ()) {
        PagingMotion.shared.applyOffset = nil
    }
}

final class PagingCanvasHostView: NSView {
    private var hostedView: NSHostingView<PagingPages>?
    private var snapshot: PagingSnapshot?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        hostedView?.frame = bounds
    }

    func setSnapshot(_ newSnapshot: PagingSnapshot) {
        guard snapshot != newSnapshot else { return }
        snapshot = newSnapshot
        if let hostedView {
            hostedView.rootView = PagingPages(snap: newSnapshot)
            hostedView.frame = bounds
        } else {
            let hosted = NSHostingView(rootView: PagingPages(snap: newSnapshot))
            hosted.frame = bounds
            hosted.autoresizingMask = [.width, .height]
            hosted.wantsLayer = true
            addSubview(hosted)
            hostedView = hosted
        }
    }

    func setOffset(_ value: CGFloat) {
        guard let layer = hostedView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(value, 0, 0)
        CATransaction.commit()
    }
}

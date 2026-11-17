import Foundation
import AppKit
import SwiftUI

/// 应用图标缓存。
///
/// `NSWorkspace.icon(forFile:)` 会带回一个含多种尺寸 representation 的 NSImage
/// （常见到 1024×1024），把 100 多个这样的原图常驻内存会占掉上百 MB。
/// 这里统一降采样成一份 160px（80pt @2x）的小图再缓存，
/// 并用 NSCache 限制总量、在内存压力下自动回收。
final class IconProvider {
    static let shared = IconProvider()

    /// 统一缓存尺寸：主网格 80pt @2x；文件夹缩略直接由 SwiftUI 缩放这张图
    private let targetPixels = 160
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// 串行解码队列：图标生成（取 NSImage + 降采样绘制）全部不占主线程。
    /// 串行足够快（每张约 1ms），也避免 100+ 个并发任务把 CPU 打满。
    private let loadQueue = DispatchQueue(label: "com.local.launchpad.icon",
                                          qos: .userInitiated)

    private init() {
        cache.countLimit = 160
        // 160×160×4B ≈ 100KB/个，24MB 足够覆盖全部应用且留有余量
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    /// 只查缓存，绝不触发解码 —— 视图 body 里用它判断是否已有图可用。
    func cachedIcon(for item: AppItem) -> NSImage? {
        let key = item.id as NSString
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key)
    }

    /// 同步取图（含解码）。只应从后台队列或预热路径调用，主线程请用 `loadIcon`。
    func icon(for item: AppItem, size: CGFloat = 80) -> NSImage {
        let key = item.id as NSString
        lock.lock()
        if let cached = cache.object(forKey: key) { lock.unlock(); return cached }
        lock.unlock()

        let big: NSImage
        if let path = item.path {
            big = NSWorkspace.shared.icon(forFile: path)
        } else {
            big = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        let small = downsample(big, pixels: targetPixels)
        lock.lock()
        cache.setObject(small, forKey: key, cost: targetPixels * targetPixels * 4)
        lock.unlock()
        return small
    }

    /// 异步取图：缓存命中立即回调（主线程），未命中则后台解码后回主线程。
    /// 视图用这个接口就不会在首次显示时串行解码 100+ 张图而卡住主线程。
    func loadIcon(for item: AppItem, completion: @escaping (NSImage) -> Void) {
        if let hit = cachedIcon(for: item) {
            completion(hit)
            return
        }
        loadQueue.async { [self] in
            let img = self.icon(for: item)
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// 生成单一 bitmap representation 的小图，原图（含所有大尺寸 rep）随即释放
    private func downsample(_ src: NSImage, pixels: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return src }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                 from: NSRect(origin: .zero, size: src.size),
                 operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pixels, height: pixels))
        out.addRepresentation(rep)
        return out
    }

    /// 保留作内存警告时的兜底；正常隐藏窗口不再调用 —— NSCache 有上限且
    /// 系统会在内存压力下自动回收，主动清空只会造成下次打开重新解码全部图标。
    func purge() { cache.removeAllObjects() }
}

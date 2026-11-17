import Foundation
import SwiftUI
import AppKit
import Combine

/// 单个图标的异步加载器：缓存命中立即出图，未命中后台解码后回主线程刷新。
/// 用 class 而不是视图里的 @State，避免 ForEach 复用时旧闭包把新图标覆盖。
final class IconLoader: ObservableObject {
    @Published var image: NSImage?
    private var generation = 0
    private var loadedID: String?

    init(item: AppItem) {
        loadedID = item.id
        image = IconProvider.shared.cachedIcon(for: item)
    }

    func load(_ item: AppItem) {
        guard loadedID != item.id || image == nil else { return }
        loadedID = item.id
        generation += 1
        let g = generation
        if let hit = IconProvider.shared.cachedIcon(for: item) {
            image = hit
            return
        }
        image = nil
        IconProvider.shared.loadIcon(for: item) { [weak self] img in
            guard let self, self.generation == g else { return }
            self.image = img
        }
    }
}

/// 异步图标：先显示淡占位，图标解码完成后替换。主线程完全不做图标生成。
struct AsyncIcon: View {
    let item: AppItem
    var size: CGFloat = 80
    var cornerRatio: CGFloat = 0.2237

    @StateObject private var loader: IconLoader

    init(item: AppItem, size: CGFloat = 80, cornerRatio: CGFloat = 0.2237) {
        self.item = item
        self.size = size
        self.cornerRatio = cornerRatio
        _loader = StateObject(wrappedValue: IconLoader(item: item))
    }

    var body: some View {
        Group {
            if let img = loader.image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous))
        .onAppear { loader.load(item) }
        .onChange(of: item.id) { _, _ in loader.load(item) }
    }
}

/// 单个格子的纯视觉内容（应用图标或文件夹缩略）
struct IconTile: View {
    let item: GridItem
    var size: CGFloat = 80
    var showLabel: Bool = true

    var body: some View {
        switch item {
        case .app(let a):
            appTile(a, showLabel: showLabel)
        case .folder(let name, let items):
            folderTile(name: name, items: items, showLabel: showLabel)
        }
    }

    private func appTile(_ a: AppItem, showLabel: Bool) -> some View {
        VStack(spacing: 5) {
            AsyncIcon(item: a, size: size)
                // 阴影直接加在图标形状上，不再垫任何矩形底片/描边
                .shadow(color: .black.opacity(0.32), radius: 6, y: 3)

            if showLabel {
                Text(a.name)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(width: size + 26, height: 28, alignment: .top)
                    .shadow(color: .black.opacity(0.75), radius: 1.5, y: 0.5)
            }
        }
    }

    private func folderTile(name: String, items: [AppItem], showLabel: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                // 文件夹底板改用官方液态玻璃：去掉半透明白板与自绘描边，
                // 只留极淡底色供玻璃采样，程序缩略图直接浮在玻璃上。
                // 底板不需要指针跟随，关掉 interactive 少注册一层追踪。
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .glassSurface(intensity: 0.78,
                                  cornerRadius: size * 0.2237,
                                  highlight: true,
                                  interactive: false)

                let preview = Array(items.prefix(9))
                if !preview.isEmpty {
                    // 与主网格程序图标对齐：留出按图标比例计算的内边距，
                    // 3×3 缩略整体居中，不再贴着文件夹边框
                    let inset = size * 0.105
                    let sp = size * 0.055
                    let inner = size - inset * 2
                    let cell = (inner - sp * 2) / 3
                    VStack(spacing: sp) {
                        ForEach(0..<3, id: \.self) { r in
                            HStack(spacing: sp) {
                                ForEach(0..<3, id: \.self) { c in
                                    let idx = r * 3 + c
                                    if idx < preview.count {
                                        AsyncIcon(item: preview[idx], size: cell)
                                    } else {
                                        Color.clear.frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: inner, height: inner)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.32), radius: 6, y: 3)

            if showLabel {
                Text(name)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(width: size + 26, height: 28, alignment: .top)
                    .shadow(color: .black.opacity(0.75), radius: 1.5, y: 0.5)
            }
        }
    }
}

/// 兼容旧调用
struct AppIconView: View {
    let item: AppItem
    var size: CGFloat = 80
    var body: some View { IconTile(item: .app(item), size: size) }
}

struct FolderIconView: View {
    let name: String
    let items: [AppItem]
    var size: CGFloat = 80
    var body: some View { IconTile(item: .folder(name: name, items: items), size: size) }
}

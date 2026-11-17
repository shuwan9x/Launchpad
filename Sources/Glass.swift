import SwiftUI
import AppKit

/// 背景玻璃由 AppKit 官方 `NSGlassEffectView` 提供（见 AppDelegate）。
/// 它会采样窗口后面的真实桌面内容并做折射 / 高光，这才是原生液态玻璃。
///
/// 这里只留一层固定的可读性保护，保证白色标签在亮桌面上仍清晰；
/// 不做模糊、不铺壁纸、不画假的边缘高光，也不再提供明暗调色。
struct LiquidGlassBackground: View, Equatable {
    var intensity: CGFloat

    static func == (lhs: LiquidGlassBackground, rhs: LiquidGlassBackground) -> Bool {
        lhs.intensity == rhs.intensity
    }

    private var clamped: CGFloat { min(max(intensity, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 顶部一道极淡的光泽 + 底部极淡的压暗，模拟玻璃厚度
                // 三档压暗固定，去掉明暗调色后观感不变
                LinearGradient(
                    colors: [Color.white.opacity(0.04 + 0.04 * clamped),
                             Color.black.opacity(0.09),
                             Color.black.opacity(0.16)],
                    startPoint: .top, endPoint: .bottom
                )
                // 四周极轻的暗角，仅保证白色程序名可读
                RadialGradient(
                    colors: [Color.clear,
                             Color.black.opacity(0.13)],
                    center: .center,
                    startRadius: min(geo.size.width, geo.size.height) * 0.32,
                    endRadius: max(geo.size.width, geo.size.height) * 0.72
                )
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// 控件级官方液态玻璃：搜索框 / 分类按钮 / 设置面板 / 文件夹图标 / 文件夹面板。
///
/// 直接用 macOS 26 的 `.glassEffect`，由系统采样背后的桌面与相邻玻璃，
/// 不再叠自绘渐变「假高光」，也不再用 opacity 把玻璃效果削弱。
struct GlassSurface: ViewModifier {
    var intensity: CGFloat
    var cornerRadius: CGFloat = 14
    var highlight: Bool = true
    /// 指针跟随的交互玻璃会让胶囊随鼠标折射形变，文字容易发虚；
    /// 纯标签类控件（分类按钮）关掉它，仍保留官方液态玻璃材质。
    var interactive: Bool = true

    private var clamped: CGFloat { min(max(intensity, 0), 1) }

    func body(content: Content) -> some View {
        content.background {
            if #available(macOS 26.0, *) {
                ZStack {
                    // 极淡底色给玻璃一点可采样内容；形状本身由官方玻璃渲染
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.03 + 0.06 * clamped))
                        .glassEffect(
                            interactive ? .regular.interactive() : .regular,
                            in: RoundedRectangle(cornerRadius: cornerRadius,
                                                 style: .continuous)
                        )
                    if highlight {
                        // 只勾一圈细边，替掉原来的渐变小高光
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.22 + 0.12 * clamped),
                                    lineWidth: 0.8)
                    }
                }
                // 玻璃只做视觉：交互式 .glassEffect 会在视图树里注册指针追踪层，
                // 不关掉 hit testing 会抢走文件夹图标 / 按钮的点击。
                .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.5 + 0.4 * clamped)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func glassSurface(intensity: CGFloat, cornerRadius: CGFloat = 14,
                      highlight: Bool = true, interactive: Bool = true) -> some View {
        modifier(GlassSurface(intensity: intensity, cornerRadius: cornerRadius,
                              highlight: highlight, interactive: interactive))
    }
}

/// 视图层不再叠加任何投影；四角由 AppDelegate 的 layer.masksToBounds 裁掉
struct GlassWindowFrame: ViewModifier {
    var intensity: CGFloat
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

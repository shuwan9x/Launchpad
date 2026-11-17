import SwiftUI
import AppKit

/// 设置页：以置顶玻璃面板呈现（浮于网格之上）
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: LaunchpadStore
    var onClose: () -> Void

    /// 面板出现动画期间先禁用交互，避免控件被入场事件误触
    @State private var interactive = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                VStack(spacing: 0) {
                    header

                    // 设置项固定且不多，直接铺在面板里：去掉 ScrollView 后
                    // 高度才会真正按内容收紧，不再留一大片底部空白
                    VStack(alignment: .leading, spacing: 12) {
                                section("外观") {
                                    SmoothSlider(title: "液态玻璃强度",
                                                 value: settings.glassIntensity,
                                                 range: 0...1, step: 0.01,
                                                 suffix: "%", scale: 100) {
                                        settings.glassIntensity = $0
                                    }
                                }

                                section("窗口与页面") {
                                    toggleRow("多页显示", isOn: $settings.multiPage)
                                    toggleRow("窗口置顶显示", isOn: $settings.alwaysOnTop)
                                    toggleRow("点击窗口外自动隐藏", isOn: $settings.autoHideOnOutsideClick)
                                    toggleRow("显示分类栏", isOn: $settings.showCategories)
                                }

                                section("通用") {
                                    toggleRow("开机自动启动", isOn: Binding(
                                        get: { settings.launchAtLogin },
                                        set: { newValue in confirmLoginItem(newValue) }
                                    ))
                                }

                                section("布局") {
                                    glassButton("重置所有排序与文件夹") {
                                        confirmResetLayout()
                                    }
                                }

                                HStack {
                                    Spacer()
                                    glassButton("退出启动台", tint: Color.red.opacity(0.9)) {
                                        NSApp.terminate(nil)
                                    }
                                    Spacer()
                                }
                            }
                    .padding(16)
                }
                // 高度完全跟随内容：fixedSize 让 VStack 采用理想高度。
                // 注意不能再叠 .frame(maxHeight:)，它会把 maxHeight 当提案高度
                // 反过来把面板撑回接近窗口高，底部留白又回来了。
                .frame(width: 430)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    // 压暗降到 0.30，让面板的官方液态玻璃真正透出来
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                        .glassSurface(intensity: CGFloat(settings.glassIntensity),
                                      cornerRadius: 22)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
                .allowsHitTesting(interactive)
                // 纯淡入：横向 move 会在动画期间改变 ScrollView 布局，导致滚动位置漂移
                .transition(.opacity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                interactive = true
            }
        }
    }

    /// 自定义排序 / 文件夹是用户数据，重置前二次确认，避免误删
    private func confirmResetLayout() {
        let alert = NSAlert()
        alert.messageText = "重置所有排序与文件夹？"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            store.resetLayout()
        }
    }

    private func confirmLoginItem(_ newValue: Bool) {
        let alert = NSAlert()
        alert.messageText = newValue ? "启用开机自动启动？" : "关闭开机自动启动？"
        alert.addButton(withTitle: newValue ? "启用" : "关闭")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.launchAtLogin = newValue
        }
    }

    // MARK: - 组件

    /// 设置页按钮统一改用官方液态玻璃底，不再是系统 .bordered 的灰板
    private func glassButton(_ title: String, tint: Color? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(tint ?? Color.white.opacity(0.88))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassSurface(intensity: CGFloat(settings.glassIntensity),
                              cornerRadius: 9)
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.white.opacity(0.9))
            Text("设置")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            CircleXButton(action: onClose)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.12)),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    /// 文字钉在左侧、开关钉在右侧。
    /// 直接用 `Toggle(title) { ... }` 在 macOS 上开关会紧跟文字，
    /// 一行行看起来参差、也不像系统设置；这里显式用 Spacer 撑开，
    /// 并把标题隐藏掉只留开关本体。
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.white.opacity(0.8))
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 滑轨：拖动中按 60ms 节流提交，松手最终落值 → 实时生效又不卡顿
private struct SmoothSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let scale: Double
    let onCommit: (Double) -> Void

    @State private var local: Double
    @State private var editing = false
    @State private var lastCommit = Date.distantPast

    init(title: String, value: Double, range: ClosedRange<Double>, step: Double,
         suffix: String, scale: Double, onCommit: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.suffix = suffix
        self.scale = scale
        self.onCommit = onCommit
        _local = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "%.0f%@", local * scale, suffix))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            Slider(value: $local, in: range, step: step) { editing in
                self.editing = editing
                if !editing {
                    onCommit(local)
                    lastCommit = Date()
                }
            }
            .tint(.white.opacity(0.85))
            // 拖动中按 60ms 节流实时提交：效果跟着滑杆走，又不会每帧重算玻璃
            .onChange(of: local) { _, new in
                guard editing else { return }
                let now = Date()
                if now.timeIntervalSince(lastCommit) >= 0.06 {
                    lastCommit = now
                    onCommit(new)
                }
            }
        }
        .onChange(of: value) { _, new in
            if !editing { local = new }
        }
    }
}

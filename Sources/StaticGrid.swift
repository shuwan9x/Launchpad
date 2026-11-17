import SwiftUI

/// 可交互网格与跟手翻页静态网格共用的几何，保证两页行对齐、不错位
enum GridMetrics {
    static let cols = 7
    static let rows = 4

    /// 把整个网格可用区域固定均分成 7×4 个格子；
    /// 格子不随图标大小变化，图标只在自己的格子里缩放。
    static func cellW(iconSize: CGFloat, width: CGFloat) -> CGFloat {
        width / CGFloat(cols)
    }

    static func cellH(iconSize: CGFloat, height: CGFloat) -> CGFloat {
        height / CGFloat(rows)
    }

    /// 图标在格子里的实际显示尺寸，给标签留出「间距 5 + 两行 28」
    static func displayIcon(iconSize: CGFloat, cellHeight: CGFloat) -> CGFloat {
        min(iconSize, max(32, cellHeight - 34))
    }
}

/// 跟手翻页时的单页渲染：几何与 DraggableGrid 完全一致，
/// 但不带拖拽手势、右键菜单、补位动画，两页并排也不掉帧。
struct StaticGrid: View, Equatable {
    let items: [GridItem]
    let iconSize: CGFloat
    let cw: CGFloat
    let ch: CGFloat

    static func == (lhs: StaticGrid, rhs: StaticGrid) -> Bool {
        lhs.items == rhs.items && lhs.iconSize == rhs.iconSize
            && lhs.cw == rhs.cw && lhs.ch == rhs.ch
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<GridMetrics.rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<GridMetrics.cols, id: \.self) { c in
                        let idx = r * GridMetrics.cols + c
                        Group {
                            if idx < items.count {
                                IconTile(item: items[idx], size: iconSize)
                                    .id(items[idx].id)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: cw, height: ch)
                    }
                }
            }
        }
        .frame(width: CGFloat(GridMetrics.cols) * cw,
               height: CGFloat(GridMetrics.rows) * ch)
    }
}

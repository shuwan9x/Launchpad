# 启动台 · Launchpad

一个用 Swift + AppKit 写的 macOS 启动台替代品。7×4 分页网格、跟手翻页、拼音模糊搜索、分类与文件夹，界面用系统原生液态玻璃。

## 功能

- **分页网格**：7 列 × 4 行，按容量自动分页；滚轮、触控板、拖拽、屏幕边缘悬停、方向键、点击页码点都能翻页，翻页带果冻回弹，周期约 0.1s。
- **台前调度友好**：以 nonactivating auxiliary panel 呈现，打开时不会把原本在中央的应用收进左侧「最近应用」栏。
- **液态玻璃**：主窗口用 `NSGlassEffectView`，搜索框、分类栏、设置面板、文件夹图标用系统 `.glassEffect`；强度可在设置里调。
- **搜索**：中英文、大小写、拼音全拼/首字母、模糊子序列匹配（如 `cltr` → Calculator），支持按分类筛选。
- **文件夹**：拖拽建文件夹、拖入拖出、重命名，缩略图按 3×3 排布。
- **持久化**：应用顺序与文件夹结构写入 Application Support；应用目录用 FSEvents 监听，安装/卸载自动更新布局。
- **性能**：图标统一降采样到 160px 并用 NSCache 限流、后台解码；布局写盘去抖；`-O` 优化编译。

## 环境

- macOS 26 及以上（用到 `NSGlassEffectView` / `.glassEffect`）
- Swift 6（Xcode 命令行工具）

应用以 `.accessory` 模式运行，没有 Dock 图标：**点菜单栏的九宫格图标打开**，或者在 Finder 里双击 `启动台.app`、用 `open -a` 启动。支持全局四指捏合唤出。

## 构建

```bash
./build.sh
```

产物为 `Launchpad.app`，同时复制到 `~/Desktop/启动台.app`。脚本从 `AppIcon.png` 生成 icns，ad-hoc 签名。

`build.sh` 用 `swiftc -O` 全模块优化编译（相比默认 `-Onone`，搜索路径快约 1.6×，二进制小约 44%）。

## 测试

```bash
./Tests/run.sh
```

覆盖滚轮齿数换算、触控板手势路由、动量取消、翻页边界、果冻曲线端点、搜索与分类等。测试会把源码编到临时目录运行，不碰用户真实布局文件。

## 打 DMG

```bash
./make-dmg.sh
```

生成 `Launchpad-2.0.dmg`，包含应用和 `Applications` 快捷方式，可直接拖入安装。

DMG 内应用是 ad-hoc 签名、未经公证。首次打开若被 Gatekeeper 拦截，右键 → 打开；或在终端执行：

```bash
xattr -cr /Applications/启动台.app
```

## 源码结构

| 文件 | 作用 |
|---|---|
| `Sources/AppDelegate.swift` | 窗口、菜单栏入口、全局手势与键盘/滚轮监听、玻璃外观 |
| `Sources/LaunchpadView.swift` | 主视图、翻页状态机、果冻动画曲线、页码点 |
| `Sources/DraggableGrid.swift` | 拖拽排序、文件夹交互、应用启动 |
| `Sources/LaunchpadStore.swift` | 布局持久化、FSEvents 监听、搜索过滤 |
| `Sources/FuzzyMatcher.swift` | 拼音/模糊匹配与缓存 |
| `Sources/IconProvider.swift` | 图标降采样与 NSCache |
| `Sources/Glass.swift` | 背景可读性层与控件级玻璃 |
| `Sources/Components.swift` | 分类栏、设置面板、文件夹面板等 |
| `Sources/Model.swift` | 应用扫描、分类启发式、AppLauncher |
| `Tests/PagingInputTests.swift` | 分页输入回归测试 |

## 许可

未指定，按需使用。

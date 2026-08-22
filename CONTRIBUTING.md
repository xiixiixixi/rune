# 如何维护 Rune

感谢你愿意为这个项目出力。这份指南会告诉你怎么上手。

## 快速开始

```bash
# 1. 进入本地代码目录
cd /Users/tc/git/snapshot/rune

# 2. 编译并运行
make run
```

就这样。Makefile 会处理一切，不需要额外装工具。

> **另一种方式**：用 Xcode 打开 `Rune.xcodeproj`，按 `⌘R` 运行。工程内部名称统一为 `Rune`，编译出的产品名称是“Rune”。

### 如果你改了 `project.yml`

Xcode 工程文件是从 `project.yml` 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 这个工具生成的。如果你改了 `project.yml`，需要重新生成工程：

```bash
brew install xcodegen   # 只需要装一次
xcodegen generate
```

绝大多数贡献都不需要动这个。

> 小白说明：`project.yml` 是一份"工程配置说明书"，描述了项目怎么编译、包含哪些文件。XcodeGen 把它翻译成 Xcode 能识别的 `.xcodeproj` 工程文件。

### 环境要求

- macOS 14.0 或更高版本
- Xcode 16.0 或更高版本（含 Swift 6）

### 权限

首次启动时，需要授予**屏幕与系统音频录制**权限。全局快捷键已经使用系统级热键方式实现，不需要辅助功能权限。

## 项目结构

```
Sources/
  App/                   应用入口和委托（app delegate）
  Capture/               截图、区域选择、取色、倒计时
  Editor/                标注编辑器：画布、检查器面板、工具、渲染
  Models/                数据类型：标注、背景、偏好设置、配置
  Preview/               浮动预览层和钉住的截图
  History/               截图历史（存在 Application Support 里的 JSON）
  Recording/             屏幕/窗口录制、视频编辑器、裁剪时间轴、特效导出
  Services/              美化渲染器、快捷键、隐私打码和显式上传
  Settings/              设置窗口（侧边栏导航）和设置窗口控制器
  Views/                 菜单栏弹出框、提示通知
Resources/
  Assets.xcassets/       应用图标、菜单栏图标
  Backgrounds/           内置壁纸和渐变图片
  Info.plist
  Rune.entitlements
```

### 关键文件

| 文件 | 作用 |
|---|---|
| `EditorModel.swift` | 编辑器的所有状态：标注交互、撤销/重做、配置 |
| `EditorCanvasView.swift` | 实时画布渲染，处理拖拽手势 |
| `EditorInspectorView.swift` | 左侧面板：工具、颜色、文字、特效、背景 |
| `AnnotationDrawing.swift` | 用 CoreGraphics 渲染最终导出图像（Y 轴朝下翻转的上下文） |
| `BeautifierRenderer.swift` | 合成背景 + 阴影 + 圆角 + 标注（为标注翻转 CG 上下文） |
| `AnnotationItem.swift` | 标注数据模型：矩形、点、工具、命中检测、用于裁剪的 `remapped(from:)` |
| `CaptureOrchestrator.swift` | 协调整个截图流水线：截图 > 播放声音 > 存历史 > 显示预览 |
| `ShortcutService.swift` | 通过 CGEvent tap 实现全局快捷键 |
| `PreviewOverlay.swift` | 截图后的浮动预览卡片（截图和录制都适用） |
| `ScreenRecordingManager.swift` | 通过 ScreenCaptureKit 录制屏幕和窗口 |
| `VideoEditorModel.swift` | 视频编辑器状态：裁剪、特效配置、用 AVMutableVideoComposition 导出 |
| `VideoEditorView.swift` | 视频编辑器界面：检查器侧栏、预览、时间轴、播放控件 |
| `RecordingStatusBar.swift` | 录制时的浮动状态栏，含计时器、暂停、停止、放弃 |
| `PreferencesView.swift` | 设置窗口，侧边栏导航（通用、截图、录制、历史、视频、关于） |
| `SettingsWindowController.swift` | 创建并管理设置窗口 NSWindow（模仿 EditorWindowController） |
| `MenuBarPopoverController.swift` | 自定义的 NSPanel 菜单栏弹出框，带箭头、点击外部消失、`originScreen` 用于定位窗口 |
| `ToastWindow.swift` | 浮动提示通知（保存确认、文字识别/取色反馈） |
| `AppPreferences.swift` | 所有存在 UserDefaults 里的偏好设置 |

## 代码是怎么工作的

### 截图流程

```
用户按下 ⌘⇧4
  → ShortcutService（CGEvent tap 拦截按键，记录是哪个屏幕触发的）
  → CaptureOrchestrator.performCapture(.region, on: screen)
  → ScreenCapture.captureRegion()（调用系统自带的 screencapture 命令行）
  → HistoryStore.importCapture()（保存到 Application Support）
  → PreviewOverlay.show(on: screen)（在同一个屏幕显示浮动卡片）
  → 用户点预览 → EditorWindowController.open(on: screen)
```

所有窗口（编辑器、视频编辑器、设置、预览、提示、钉住的截图）都打开在触发操作的那个屏幕上，而不是主屏幕。

### 录制流程

```
用户按下 ⌘⇧2（或点击 录制 / 录制窗口）
  → ShortcutService（CGEvent tap 拦截按键）
  → ScreenRecordingManager.startRecording()（录全屏）
     或 .startWindowRecording()（悬停并点击的窗口选择器）
  → RecordingStatusBarController.show()（浮动状态栏，不会被录进去）
  → 用户点停止 → HistoryStore.importCapture(kind: .recording, deleteSource: false)
  → PreviewOverlay.show()（带原始视频的浮动卡片）
  → 用户点预览 → VideoEditorWindowController.open()
  → 用户编辑特效 → VideoEditorModel.exportWithEffects()
     （AVMutableVideoComposition + Core Animation 图层）
```

### 编辑器流程

```
EditorModel（所有状态）
  ├── EditorInspectorView   左侧面板：工具、样式、文字、特效、布局、背景
  ├── EditorCanvasView      渲染图像 + 实时标注视图，处理手势
  │     └── AnnotationItemView   每个标注一个（形状、文字、打码）
  └── AnnotationKeyboard    工具和动作的键盘快捷键
```

标注使用**归一化坐标**（0.0 到 1.0），所以它们和分辨率无关。画布把它们渲染成 SwiftUI 视图用于交互编辑。`AnnotationDrawing` 再用 CoreGraphics 重新渲染用于最终导出。

> 小白说明："归一化坐标"就是不管图片多大，位置都用 0 到 1 的小数表示。比如 0.5 就是正中间。这样图片放大缩小，标注位置都不会跑偏。

**坐标系**：画布预览使用 SwiftUI 的"Y 轴朝下"坐标。导出渲染器在画标注前会先把 CG 上下文翻转为 Y 轴朝下，所以两条代码路径用的是完全相同的坐标计算（`imageRect.minY + point.y * imageRect.height`）。当有裁剪时，`AnnotationItem.remapped(from:)` 会把标注从"原图坐标空间"转换到"裁剪后图像坐标空间"再导出。

### 设置

设置窗口由 `SettingsWindowController` 管理，它创建一个 `NSWindow`，里面用 `NSHostingView` 装 `PreferencesView`。这模仿了 `EditorWindowController` 的模式。视图用侧边栏列表（通用、截图、录制、历史、视频、关于）加内容面板。偏好设置通过 `@AppStorage` 和集中的 `AppPreferences` 枚举存储。截图和录制有各自的历史标签——"历史"只显示截图，"视频"只显示录制。

### 菜单栏

菜单栏弹出框由 `MenuBarPopoverController` 管理，它创建一个自定义的 `NSPanel`（不是 SwiftUI 的 `MenuBarExtra`），以便完全控制外观和动画。这个面板装的是 `MenuBarPanelView`，带箭头指示器和弹性动画。

## 常见任务

### 添加一个新的标注工具

1. 在 `Models/AnnotationItem.swift` 的 `AnnotationTool` 里加上新的 case
2. 设置它的 `systemImage`（系统图标）和 `title`（标题）
3. 在 `Editor/AnnotationItemView.swift` 加上实时渲染（用 `viewRect`/`viewPoint`——Y 轴朝下）
4. 在 `Editor/AnnotationDrawing.swift` 加上导出渲染（用 `renderedRect`/`renderedPoint` 配 `flipped: true`——和画布一样的 Y 轴朝下计算）
5. 在 `EditorModel.beginDraftItem` 处理创建
6. 在 `EditorModel.updateDraftItem` 处理更新
7. 在 `Editor/AnnotationKeyboard.swift` 加上键盘快捷键
8. 如果这个工具用到 `rect` 或 `points`，确保 `AnnotationItem.remapped(from:)` 能正确处理它（为了支持裁剪）

### 添加一个新的背景类型

1. 在 `Models/BackgroundStyle.swift` 的 `BackgroundStyle` 里加上新的 case
2. 在 `BeautifierRenderer.drawBackground` 处理渲染
3. 在 `EditorInspectorView.swift` 的 `BackgroundPickerSection` 加上选择界面
4. 在 `PreferencesView.swift` 的 `DefaultBackgroundPicker` 加上选择界面

### 添加一个新的偏好设置

1. 在 `Models/AppPreferences.swift` 加上 `@AppStorage` 的键和属性
2. 在 `Settings/PreferencesView.swift` 对应的章节加上界面控件

## 代码风格

- **Swift 6 严格并发** —— 所有代码必须能不带并发警告地编译通过
- **`@Observable`** 用于模型类，视图里用 `@Bindable`
- **不写注释**，除非是为了解释不显然的东西（一个隐藏的约束、一个 workaround）
- **不要为了抽象而抽象** —— 三行相似的代码比一个过早的辅助函数更好
- **系统颜色** —— 用 `NSColor.controlBackgroundColor`、`.separatorColor` 等等，保持原生外观
- **主线程（Main actor）** —— 所有 UI 类型都是 `@MainActor`

> 小白说明："并发（concurrency）"指的是程序同时做多件事的能力。Swift 6 会对可能出错的并发操作发出警告，这里要求代码必须能避开所有这些警告。"主线程"是程序里负责处理界面的那条主线，所有界面相关的代码都必须在主线程上跑。

## 提交 Pull Request（合并请求）

1. 建一个分支：`git checkout -b feat/这个功能是什么` 或 `fix/修了什么`
2. 保持改动聚焦——一个 PR 只做一件事
3. 确保能编译：`make build`
4. 在 App 里手动测试：`make run`
5. 写清楚的 PR 标题和描述

> 小白说明："Pull Request（PR）"是你请求别人把你的改动合并到主项目里。"分支（branch）"是你从主线复制出来的一个独立工作区，改完再合并回去，不会影响主线。

### 提交信息（commit message）

用简短、描述性的信息：

```
feat: 给打码工具加一个模糊强度滑块
fix: 修复副显示器上窗口截图失败的问题
chore: 更新依赖
```

## 版本管理

版本号在三个地方记录（要保持同步）：

| 文件 | 字段 |
|---|---|
| `version.json` | `version`、`build` |
| `project.yml` | `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` |
| `Rune.xcodeproj/project.pbxproj` | `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`（Debug 和 Release 都要） |

`CHANGELOG.md` 记录每个版本改了什么。

## 开源协议

提交贡献即表示你同意，你的贡献将按本项目的 [BSD 3-Clause 协议](LICENSE)授权。

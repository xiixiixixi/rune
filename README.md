# BetterShot

[![macOS](https://img.shields.io/badge/macOS-14.0+-black.svg)](https://github.com/KartikLabhshetwar/better-shot)
[![License](https://img.shields.io/badge/license-BSD%203--Clause-green.svg)](LICENSE)
[![X (Twitter)](https://img.shields.io/badge/X-%231DA1F2.svg?style=flat&logo=X&logoColor=white)](https://x.com/code_kartik)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-%23FFDD00.svg?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/code_kartik)

CleanShot X 的开源替代品。一款用 Swift 原生开发的 macOS 应用——快速、轻量、本地优先。没有订阅制，没有云端，没有数据上报。

> 小白说明：CleanShot X 是一款很有名的付费 Mac 截图软件，这个项目是想做一个免费开源的同类工具。"本地优先"的意思是所有操作都在你的电脑上完成，不依赖网络服务器。"数据上报"（telemetry）是指软件偷偷把你的使用数据发回给开发商。

## 它能做什么

### 截图

| 动作 | 快捷键 |
|---|---|
| 区域截图 | `⌘⇧4` |
| 全屏截图 | `⌘⇧3` |
| 窗口截图 | `⌘⇧5` |
| 录屏 | `⌘⇧2` |
| 文字识别（OCR） | `⌘⇧O` |
| 取色（取屏幕上某个点的颜色值） | `⌘⇧C` |

区域截图、全屏截图、窗口截图都使用 macOS 自带的 `screencapture` 命令行工具，以保证最大的稳定性。文字识别可以从屏幕任意区域提取文字。取色器可以采集屏幕上任意一个像素点，并复制它的颜色编码（十六进制 hex 值）。所有快捷键都可以在"设置 > 截图"里自定义。

> 小白说明：`screencapture` 是 macOS 系统自带的截图命令，在"终端"里输入它就能截图。这里用它的原因是它最稳定，不容易出问题。

### 屏幕录制

- **录制全屏** —— 把整个屏幕录制成 MP4 视频（用的是苹果的 ScreenCaptureKit 技术）
- **悬浮状态栏** —— 录制时显示一个计时器，可以暂停/继续、停止、重录、放弃，而且这些控件不会被录进视频里
- **视频编辑器** —— 可以裁剪、加边距、加圆角、加阴影、加背景（纯色、渐变、系统壁纸、自定义图片）。导出成带特效的 MP4
- **可配置** —— 在"设置 > 录制"里可以调帧率（24/30/60）、是否显示鼠标、是否录声音

> 小白说明：帧率（FPS）就是每秒钟画面刷新多少次，数字越大越流畅，文件也越大。

### 美化

- **背景** —— 12 种纯色预设、16 种渐变预设、系统自带的 macOS 壁纸，或者你自己的图片
- **特效** —— 边距、圆角、阴影强度，全部实时预览
- **裁剪** —— 用可拖动的把手裁剪截图和录制，有暗色遮罩和"九宫格"参考线
- **布局** —— 宽高比（自动、1:1、4:3、3:2、16:9、9:16）、九点对齐网格，带智能圆角
- **默认值** —— 在"设置"里配置你喜欢的特效和背景，带实时预览
- **导出** —— 截图导出为 PNG 或 JPEG，录制导出为 MP4

### 标注

> 小白说明："标注"就是在截图上画箭头、框框、写字这些。

矩形、实心矩形、椭圆、直线、曲线箭头、自由画笔、文字、编号圆圈、模糊、聚光灯。每种工具在编辑器里都有单键快捷键（`R`、`F`、`O`、`L`、`A`、`D`、`T`、`N`、`B`、`G`）。文字标注支持选字体、字号、加粗、斜体、下划线、对齐方式。

### 工作流程

- **点一下就编辑** —— 点浮动预览图就能打开编辑器（图片或视频都行）
- **拖到别的 App** —— 从预览面板直接拖到 Figma、Slack 或任何 App 里
- **钉住截图** —— 把任意截图钉成一个始终在最上层的悬浮窗口，可以从菜单栏一键取消所有钉住的图
- **自动套用** —— 每次截图/录制都自动套用你设好的默认背景、边距、圆角、阴影
- **定时器** —— 截图前倒计时（3 秒、5 秒、10 秒）
- **截图历史** —— "设置"里截图和录制分开展示
- **最近菜单** —— 从菜单栏快速访问最近的截图和录制
- **提示通知** —— 文字识别、取色、保存到图库时会有提示
- **App 内更新** —— 不用退出 App 就能检查、下载、安装更新
- **可配置的悬浮层** —— 可以选预览图的位置和自动消失的时间

## 安装

### 用 Homebrew 安装

> 小白说明：Homebrew 是 Mac 上一个很流行的"软件管家"，在终端里输入命令就能装软件。

```bash
brew install --cask bettershot
```

### 直接下载

1. 去 [Releases 发布页](https://github.com/KartikLabhshetwar/better-shot/releases)
2. 下载对应你电脑芯片（Apple Silicon 或 Intel）的最新 `.dmg` 文件
3. 打开 DMG，把 BetterShot 拖到"应用程序"文件夹
4. 启动，按提示授权

> 小白说明：Apple Silicon 是 M1/M2/M3 这些芯片的 Mac；Intel 就是老款的 Intel 芯片 Mac。不确定的话，点屏幕左上角苹果图标 >"关于本机"就能看到。

### 从源码编译

```bash
git clone https://github.com/KartikLabhshetwar/better-shot.git
cd better-shot
make run
```

这会编译一个调试版本并启动它。所有 make 命令见下文[编译命令一览](#编译命令一览)。

> 小白说明："调试版本"（debug build）是给开发者用的，运行慢一点但能报告错误信息，方便找 bug。

### 权限

BetterShot 首次启动需要两个 macOS 权限：

1. **屏幕录制** —— 系统设置 > 隐私与安全性 > 屏幕录制
2. **辅助功能** —— 系统设置 > 隐私与安全性 > 辅助功能

"屏幕录制"让 App 能截取你的屏幕。"辅助功能"让它能用自己的快捷键替换掉 macOS 默认的截图快捷键。

## 用法

1. 启动 BetterShot —— 它会出现在**菜单栏**（屏幕右上角）
2. 用快捷键，或者从菜单里点一个截图动作
3. 出现浮动预览图 —— **点它就能打开编辑器**
4. 调整背景、特效，加标注
5. `⌘S` 保存，`⇧⌘C` 复制到剪贴板

### 编辑器快捷键

| 动作 | 按键 |
|---|---|
| 选择工具 | `V` |
| 矩形 | `R` |
| 实心矩形 | `F` |
| 椭圆 | `O` |
| 直线 | `L` |
| 箭头 | `A` |
| 自由画笔 | `D` |
| 文字 | `T` |
| 编号圆圈 | `N` |
| 模糊 | `B` |
| 聚光灯 | `G` |
| 保存 / 导出 | `⌘S` |
| 复制到剪贴板 | `⇧⌘C` |
| 撤销 / 重做 | `⌘Z` / `⇧⌘Z` |
| 删除标注 | `Delete` |
| 全选 | `⌘A` |
| 关闭编辑器 | `Esc` |

### 设置

从菜单栏 > **Settings（设置）** 打开（或按 `⌘,`）。

- **通用** —— 保存位置、剪贴板行为、外观、默认特效（带实时预览：边距、圆角、阴影、背景，含 macOS 壁纸和自定义图片）、导出格式
- **截图** —— 定时器延时、键盘快捷键（点任意快捷键可重新录制，包括录屏）、悬浮层位置和消失时间
- **录制** —— 帧率（24/30/60）、显示鼠标、录制声音、录制后打开编辑器
- **历史** —— 浏览和删除历史截图
- **视频** —— 浏览和删除历史录制，在视频编辑器里打开
- **关于** —— 版本信息、App 内更新检查、项目链接（GitHub、X）

## 编译命令一览

| 命令 | 作用 |
|---|---|
| `make build` | 编译调试版 |
| `make release` | 编译发布版（不签名） |
| `make run` | 编译并启动 |
| `make dmg` | 生成本地测试用的 DMG 安装包 |
| `make clean` | 清除编译产物 |
| `make lint` | 检查编译警告 |
| `make test-build` | 完整清理 + 编译发布版 |
| `make version` | 打印当前版本号 |

## 架构

原生 Swift 6 / SwiftUI。不用 Electron，不用网页视图，没有外部依赖。

> 小白说明："Electron"是一种用网页技术做桌面软件的方案，优点是开发快，缺点是很吃内存、启动慢。这里强调"原生"是说它用的是苹果系统自家的技术，所以又快又轻。

| 框架 | 用来做什么 |
|---|---|
| CoreGraphics | 图像合成、标注渲染、美化处理流水线 |
| CoreImage | 高斯模糊（用于打码） |
| Vision | 文字识别（OCR） |
| ScreenCaptureKit | 屏幕和窗口录制 |
| AVFoundation | 视频编辑、裁剪、通过 AVMutableVideoComposition 合成特效 |
| AppKit | 取色、浮动面板、钉住的窗口、通过命令行截图 |
| Carbon | 通过 CGEvent tap 实现全局快捷键 |

## 贡献

欢迎贡献。详见 [CONTRIBUTING.md](CONTRIBUTING.md)（环境搭建、项目结构、代码规范）。

## 开源协议

BSD 3-Clause。详见 [LICENSE](LICENSE)。

> 小白说明：BSD 3-Clause 是一种很宽松的开源协议，允许你免费使用、修改、甚至闭源商用，只要保留版权声明。这也是本项目选它做基座的原因。

## Star 历史

<a href="https://www.star-history.com/#KartikLabhshetwar/better-shot&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=KartikLabhshetwar/better-shot&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=KartikLabhshetwar/better-shot&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=KartikLabhshetwar/better-shot&type=date&legend=top-left" />
 </picture>
</a>

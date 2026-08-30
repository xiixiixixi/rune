import AppKit
import SwiftUI

// MARK: - 数据模型

/// 一条菜单项
struct RuneMenuItem: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String?
    var shortcut: String?
    var isDestructive: Bool = false
    /// 当前生效的选项画对钩（用于选择器型菜单）
    var isSelected: Bool = false
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        shortcut: String? = nil,
        isDestructive: Bool = false,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isSelected = isSelected
        self.action = action
    }
}

/// 菜单内容：条目或分隔线
enum RuneMenuEntry {
    case item(RuneMenuItem)
    case divider
}

/// 菜单浮在哪种表面上：纸面（窗口里）或石墨（悬浮在画面上的工具条）。
/// 重新设计后全机统一石墨声部，两种取值渲染相同；保留枚举让调用处
/// 继续读出"这个菜单长在窗口里还是压在画面上"的意图。
enum RuneMenuSurface {
    case paper
    case chrome
}

// MARK: - SwiftUI 触发组件

/// 校样台的下拉菜单：触发按钮 + 自绘浮层菜单。
///
/// 与系统 NSMenu 的取舍：换来完全的视觉控制（纸面/石墨两班配色、
/// 对钩与快捷键徽章、圆角细边卡片）。关闭方式是菜单交互的惯例：
/// 点菜单外任意处（一层全屏透明接点层收下这次点击）、按 Esc、或选中条目。
/// 右键上下文菜单仍走系统，保持平台习惯。
struct RuneMenu<Label: View>: View {
    var surface: RuneMenuSurface = .paper
    /// 菜单最小宽度（图标型触发器也需要可读的菜单宽度）
    var menuWidth: CGFloat = 208
    /// 打开时求值，保证菜单内容反映最新状态
    var entries: () -> [RuneMenuEntry]
    @ViewBuilder var label: () -> Label

    @State private var anchorBox = RuneMenuAnchorBox()

    var body: some View {
        Button {
            if let anchorView = anchorBox.view, let window = anchorView.window {
                RuneMenuController.shared.present(
                    entries: entries(),
                    surface: surface,
                    menuWidth: menuWidth,
                    anchorView: anchorView,
                    in: window
                )
            }
        } label: {
            label()
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .background(RuneMenuAnchorFinder(box: anchorBox))
    }
}

/// 触发按钮背后的 NSView 引用盒，供浮层定位。
/// 只在 MainActor 上下文读写（makeNSView 与按钮回调都在主线程）。
private final class RuneMenuAnchorBox {
    fileprivate weak var view: NSView?
}

/// 找到触发按钮背后的 NSView，供浮层定位。
private struct RuneMenuAnchorFinder: NSViewRepresentable {
    let box: RuneMenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 选择器型菜单：一组互斥选项，当前值画对钩。
/// 给设置页与检查器替换系统 Picker(menu) 用。
struct RunePicker<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var menuWidth: CGFloat = 208

    @State private var isHovered = false

    var body: some View {
        RuneMenu(menuWidth: menuWidth, entries: {
            options.map { option in
                .item(
                    RuneMenuItem(option.label, isSelected: option.value == selection) {
                        selection = option.value
                    }
                )
            }
        }) {
            HStack(spacing: 7) {
                Text(currentLabel)
                    .font(RuneFont.swiftUI(size: 12, weight: .medium))
                    .foregroundStyle(RuneTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.up.chevron.down")
                    .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(minWidth: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous)
                    .fill(isHovered ? RuneTheme.card.opacity(0.92) : RuneTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous)
                    .strokeBorder(
                        isHovered ? RuneTheme.separator.opacity(0.9) : RuneTheme.separator,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous))
        }
        .onHover { isHovered = $0 }
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }
}

// MARK: - 浮层窗口管理

/// 同一时刻只开一个菜单浮层：再点其他触发器时先换掉旧的。
@MainActor
final class RuneMenuController: NSObject {
    static let shared = RuneMenuController()

    private var panel: NSPanel?
    /// 全屏透明接点击层：比菜单低一级、比其他一切都高，
    /// 菜单打开期间收下"点到菜单外"的那次点击。
    private var catcher: NSWindow?

    private override init() { super.init() }

    func present(
        entries: [RuneMenuEntry],
        surface: RuneMenuSurface,
        menuWidth: CGFloat,
        anchorView: NSView,
        in window: NSWindow
    ) {
        close()

        let list = RuneMenuList(entries: entries, surface: surface) {
            self.close()
        }
        let hosting = NSHostingView(rootView: list)
        hosting.translatesAutoresizingMaskIntoConstraints = true

        // 先量尺寸再定位置：宽度至少盖住触发器并保持菜单可读
        let anchorRectInView = anchorView.convert(anchorView.bounds, to: nil)
        let anchorWidth = window.convertToScreen(anchorRectInView).width
        var width = max(menuWidth, ceil(anchorWidth))
        if let screen = window.screen ?? NSScreen.main {
            width = min(width, screen.visibleFrame.width - 24)
        }
        hosting.setFrameSize(NSSize(width: width, height: 10000))
        hosting.layoutSubtreeIfNeeded()
        let fittingHeight = hosting.fittingSize.height
        let clamped = NSSize(width: width, height: min(ceil(fittingHeight), 360))
        hosting.setFrameSize(clamped)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: clamped),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        self.panel = panel

        // 定位：默认落在触发器下方；空间不够翻到上方；水平方向夹在屏内
        let anchorScreenRect = window.convertToScreen(anchorRectInView)
        var origin = NSPoint(
            x: anchorScreenRect.midX - clamped.width / 2,
            y: anchorScreenRect.minY - clamped.height - 5
        )
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = anchorScreenRect.maxY + 5
            }
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - clamped.width - 6)
        }
        panel.setFrameOrigin(origin)

        if let screen = window.screen ?? NSScreen.main {
            let catcher = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            let catcherView = RuneMenuCatcherView()
            catcherView.onDismiss = { [weak self] in
                self?.close()
            }
            catcher.contentView = catcherView
            catcher.isOpaque = false
            catcher.backgroundColor = .clear
            catcher.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
            catcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            catcher.ignoresMouseEvents = false
            catcher.isReleasedWhenClosed = false
            catcher.setFrameOrigin(screen.frame.origin)
            self.catcher = catcher
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            catcher?.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        } else {
            // 从锚点方向轻轻落下来，140ms 收束，跟 RunePressStyle 一个脾气
            let restFrame = panel.frame
            let startFrame = NSRect(
                x: restFrame.origin.x,
                y: restFrame.origin.y + 3,
                width: restFrame.width,
                height: restFrame.height
            )
            panel.setFrame(startFrame, display: false)
            panel.alphaValue = 0
            catcher?.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(restFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        catcher?.orderOut(nil)
        catcher = nil
    }
}

/// 全屏透明接点击层：任何鼠标按下都只是收起菜单。
private final class RuneMenuCatcherView: NSView {
    var onDismiss: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
    override func otherMouseDown(with event: NSEvent) { onDismiss?() }
}

// MARK: - 菜单列表

private struct RuneMenuList: View {
    let entries: [RuneMenuEntry]
    let surface: RuneMenuSurface
    let onDismiss: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    switch entry {
                    case let .item(item):
                        RuneMenuRow(item: item, surface: surface) {
                            item.action()
                            onDismiss()
                        }
                    case .divider:
                        RuneMenuDivider(surface: surface)
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: true, vertical: true)
        .runeGlassSurface(cornerRadius: 7, elevation: .floating)
        .padding(6)  // 给系统窗影留出内容外的透明边
        .onExitCommand(perform: onDismiss)
    }
}

private struct RuneMenuRow: View {
    let item: RuneMenuItem
    let surface: RuneMenuSurface
    let onPick: () -> Void

    @State private var isHovered = false

    // paper/chrome 词表已合并为单一动态声部（两个枚举值渲染相同）。
    // 菜单保持中性，光谱只作为选中项的微小折射记号。
    private var titleColor: Color {
        item.isDestructive ? RuneTheme.signal : RuneTheme.ink
    }

    private var iconColor: Color {
        item.isDestructive ? RuneTheme.signal : RuneTheme.textSecondary
    }

    private var hoverBackground: Color {
        item.isDestructive
            ? RuneTheme.signal.opacity(0.10)
            : Color.white.opacity(0.055)
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 0) {
                // 对钩槽位：有则画钩，无则留白——选中态对齐在同一条竖线上
                Image(systemName: "checkmark")
                    .font(RuneFont.swiftUI(size: 10, weight: .bold))
                    .foregroundStyle(RuneTheme.spectralGradient)
                    .opacity(item.isSelected ? 1 : 0)
                    .frame(width: 22)

                if let systemImage = item.systemImage {
                    Image(systemName: systemImage)
                        .font(RuneFont.swiftUI(size: 13, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 24)
                }

                Text(item.title)
                    .font(RuneFont.swiftUI(size: 12, weight: .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(RuneFont.mono(size: 10, weight: .medium))
                        .foregroundStyle(RuneTheme.textMuted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous)
                    .fill(isHovered ? hoverBackground : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(item.isSelected ? "已选中，\(item.title)" : item.title)
    }
}

private struct RuneMenuDivider: View {
    let surface: RuneMenuSurface

    var body: some View {
        Rectangle()
            .fill(RuneTheme.separator)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

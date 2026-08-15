import SwiftUI

/// 确认模式底部工具栏（红白设计 · v3 自适应版）。
///
/// 布局（宽度随内容自适应，面板由控制器按 fittingSize 调整，绝不裁切）：
/// - 紧凑态（默认·选择工具）：[6 工具] │ [↩撤销] │ [⧉复制][📌贴图] │ [取消] [保存🔴]
/// - 展开态（选中画图工具）：在工具组后多出 [5 色点 · 3 粗细] 属性组
/// - 分组用极淡竖线 + 留白；红色只出现在：激活工具图标 + 保存主按钮
struct ConfirmToolbarView: View {
    let controller: CaptureConfirmController

    private var canvas: ConfirmCanvasView? { controller.canvas }

    @State private var activeTool: AnnotationTool = .select
    @State private var swatch: AnnotationSwatch = .red
    @State private var widthRaw: Int = 1

    private let tools: [AnnotationTool] = [.select, .rectangle, .arrow, .text, .blur, .numberedCircle]
    private let swatches: [AnnotationSwatch] = [.red, .black, .white, .blue, .yellow]
    private let widths: [CGFloat] = [2, 4, 8]

    /// 画图工具才需要颜色/粗细；选择工具时收起属性组，保持一条短干净的条
    private var showsToolOptions: Bool { activeTool != .select }

    var body: some View {
        HStack(spacing: 0) {
            // ── 工具组
            HStack(spacing: 2) {
                ForEach(tools, id: \.self) { tool in
                    Button {
                        activeTool = tool
                        canvas?.selectedTool = tool
                        canvas?.selectedID = nil
                        canvas?.needsDisplay = true
                        canvas?.refreshCursor()
                    } label: {
                        QJTheme.toolIcon(iconName(for: tool), active: activeTool == tool)
                    }
                    .buttonStyle(QJTheme.QJPressStyle())
                    .help(tool.title)
                }
            }

            // ── 属性组（按需展开）
            if showsToolOptions {
                QJTheme.groupSeparator
                HStack(spacing: 14) {
                    // 色点：16pt 圆 + 白描边；选中=石墨环（红色只留给激活工具和保存）
                    HStack(spacing: 6) {
                        ForEach(swatches, id: \.self) { s in
                            Button {
                                swatch = s
                                canvas?.selectedSwatch = s
                            } label: {
                                Circle()
                                    .fill(Color(s.nsColor))
                                    .frame(width: 15, height: 15)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(swatch == s ? QJTheme.textPrimary.opacity(0.75) : .clear, lineWidth: 1.5)
                                            .frame(width: 19, height: 19)
                                    )
                                    .frame(width: 20, height: 24)
                            }
                            .buttonStyle(QJTheme.QJPressStyle())
                            .help(s.title)
                        }
                    }

                    // 粗细：小中大实心点，选中加深
                    HStack(spacing: 4) {
                        ForEach(widths.indices, id: \.self) { i in
                            Button {
                                widthRaw = i
                                canvas?.strokeWidth = widths[i]
                            } label: {
                                Circle()
                                    .fill(widthRaw == i ? QJTheme.textPrimary : QJTheme.textSecondary.opacity(0.45))
                                    .frame(width: CGFloat(4 + i * 3))
                                    .frame(width: 22, height: 24)
                            }
                            .buttonStyle(QJTheme.QJPressStyle())
                            .help("粗细")
                        }
                    }
                }
            }

            QJTheme.groupSeparator

            // ── 撤销
            Button {
                canvas?.undo()
                canvas?.needsDisplay = true
            } label: {
                QJTheme.toolIcon("arrow.uturn.backward", active: false)
            }
            .buttonStyle(QJTheme.QJPressStyle())
            .help("撤销 (⌘Z)")

            QJTheme.groupSeparator

            // ── 复制 / 贴图（纯图标，悬停有中文提示）
            Button {
                canvas?.copyImageToPasteboard()
            } label: {
                QJTheme.toolIcon("doc.on.doc", active: false)
            }
            .buttonStyle(QJTheme.QJPressStyle())
            .help("复制到剪贴板 (⌘C)")

            Button {
                canvas?.pinImage()
                controller.cancel()
            } label: {
                QJTheme.toolIcon("pin", active: false)
            }
            .buttonStyle(QJTheme.QJPressStyle())
            .help("钉在桌面上（贴图）")

            QJTheme.groupSeparator

            // ── 取消 / 保存
            HStack(spacing: 8) {
                Button {
                    controller.cancel()
                } label: {
                    QJTheme.secondaryButtonLabel("取消")
                }
                .buttonStyle(QJTheme.QJPressStyle())
                .help("放弃截图 (Esc)")

                Button {
                    controller.confirm()
                } label: {
                    QJTheme.primaryButtonLabel("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(QJTheme.QJPressStyle())
                .help("保存 (Enter)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: QJTheme.barHeight)
        .background(QJTheme.barBackground)
        .onChange(of: activeTool) { _, _ in
            controller.toolbarNeedsLayout()
        }
    }

    /// 精选图标映射（统一线性风格；覆盖编辑器的默认选型）
    private func iconName(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "arrow.up.and.down.and.arrow.left.and.right"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "character.cursor.ibeam"
        case .blur: "checkerboard.rectangle"
        case .numberedCircle: "1.circle"
        default: "circle"
        }
    }
}

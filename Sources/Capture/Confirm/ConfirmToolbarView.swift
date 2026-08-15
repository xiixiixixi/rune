import SwiftUI

/// 确认模式底部工具栏（红白设计 · docs/交互设计.md）。
///
/// [选择][矩形][箭头][文字][马赛克][序号] | 3色点+粗细 | [↩] | [复制][贴图] | [取消] [保存🔴]
struct ConfirmToolbarView: View {
    let controller: CaptureConfirmController

    /// 画布的实时驱动：工具/颜色/粗细直读直写 canvas（NSView 是引用类型，可变）
    private var canvas: ConfirmCanvasView? { controller.canvas }

    @State private var activeTool: AnnotationTool = .select
    @State private var swatch: AnnotationSwatch = .red
    @State private var widthRaw: Int = 1

    private let tools: [AnnotationTool] = [.select, .rectangle, .arrow, .text, .blur, .numberedCircle]
    private let swatches: [AnnotationSwatch] = [.red, .black, .white, .blue, .yellow]
    private let widths: [CGFloat] = [2, 4, 8]

    var body: some View {
        HStack(spacing: 10) {
            // 工具组
            HStack(spacing: 2) {
                ForEach(tools, id: \.self) { tool in
                    Button {
                        activeTool = tool
                        canvas?.selectedTool = tool
                        canvas?.selectedID = nil
                        canvas?.needsDisplay = true
                    } label: {
                        QJTheme.toolIcon(tool.systemImage, active: activeTool == tool)
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }

            QJToolbarDivider()

            // 颜色点
            HStack(spacing: 5) {
                ForEach(swatches, id: \.self) { s in
                    Button {
                        swatch = s
                        canvas?.selectedSwatch = s
                    } label: {
                        Circle()
                            .fill(Color(s.nsColor))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().strokeBorder(
                                    swatch == s ? QJTheme.accent : QJTheme.separator,
                                    lineWidth: swatch == s ? 2 : 0.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 粗细
            HStack(spacing: 2) {
                ForEach(widths.indices, id: \.self) { i in
                    Button {
                        widthRaw = i
                        canvas?.strokeWidth = widths[i]
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(widthRaw == i ? QJTheme.accent : QJTheme.textSecondary)
                            .frame(width: 16, height: CGFloat(2 + i * 3))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }

            QJToolbarDivider()

            // 撤销
            Button {
                canvas?.undo()
                canvas?.needsDisplay = true
            } label: {
                QJTheme.toolIcon("arrow.uturn.backward", active: false)
            }
            .buttonStyle(.plain)
            .help("撤销 (⌘Z)")

            Spacer(minLength: 4)

            // 动作组
            Button {
                canvas?.copyImageToPasteboard()
            } label: {
                QJTheme.secondaryButtonLabel("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)

            Button {
                // 贴图 = 钉出来对照，不落盘不进历史 → 对保存链路等同"取消"
                canvas?.pinImage()
                controller.cancel()
            } label: {
                QJTheme.secondaryButtonLabel("贴图", systemImage: "pin")
            }
            .buttonStyle(.plain)

            Button {
                controller.cancel()
            } label: {
                QJTheme.secondaryButtonLabel("取消", systemImage: "xmark")
            }
            .buttonStyle(.plain)

            Button {
                controller.confirm()
            } label: {
                QJTheme.primaryButtonLabel("保存", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: QJTheme.barHeight)
        .background(QJTheme.barBackground)
    }
}

/// 工具栏竖分隔线。
private struct QJToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(QJTheme.separator)
            .frame(width: 0.5, height: 22)
    }
}

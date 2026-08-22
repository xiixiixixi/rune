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
    @State private var swatch: AnnotationSwatch = .mustard
    @State private var widthRaw: Int = 1
    @State private var customColor: Color = Color(red: 0.85, green: 0.64, blue: 0.25)

    private let tools: [AnnotationTool] = [.select, .rectangle, .arrow, .text, .blur, .spotlight, .numberedCircle]
    /// 跨色系专业配色：芥末黄（默认）、珊瑚红、青碧、靛蓝 + 黑白基础
    private let swatches: [AnnotationSwatch] = [.mustard, .coral, .teal, .indigo, .black, .white]
    private let widths: [CGFloat] = [2, 4, 8]

    /// 属性组常驻（CleanShot 式）：画新标注用它，选中已有标注也能随时改色/改粗细
    private var showsToolOptions: Bool { true }

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
                        RuneTheme.toolIcon(iconName(for: tool), active: activeTool == tool)
                    }
                    .buttonStyle(RuneTheme.RunePressStyle())
                    .help(tooltip(for: tool))
                }
            }

            // ── 属性组（按需展开）
            if showsToolOptions {
                RuneTheme.groupSeparator
                HStack(spacing: 14) {
                    // 色点：16pt 圆 + 白描边；选中=石墨环（红色只留给激活工具和保存）
                    HStack(spacing: 6) {
                        ForEach(swatches, id: \.self) { s in
                            Button {
                                swatch = s
                                canvas?.selectedSwatch = s
                                canvas?.updateSelectedAnnotation(swatch: s)
                            } label: {
                                Circle()
                                    .fill(Color(s.nsColor))
                                    .frame(width: 15, height: 15)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(swatch == s ? RuneTheme.textPrimary.opacity(0.75) : .clear, lineWidth: 1.5)
                                            .frame(width: 19, height: 19)
                                    )
                                    .frame(width: 20, height: 24)
                            }
                            .buttonStyle(RuneTheme.RunePressStyle())
                            .help(s.title)
                        }
                    }

                    // 自定义颜色：系统取色器，不限于预设色板
                    ColorPicker("", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .scaleEffect(0.72)
                        .frame(width: 24, height: 24)
                        .help("自定义颜色：任选任意颜色")
                        .onChange(of: customColor) { _, newColor in
                            let custom = AnnotationSwatch.custom(from: newColor)
                            swatch = custom
                            canvas?.selectedSwatch = custom
                            canvas?.updateSelectedAnnotation(swatch: custom)
                        }

                    // 粗细：小中大实心点，选中加深
                    HStack(spacing: 4) {
                        ForEach(widths.indices, id: \.self) { i in
                            Button {
                                widthRaw = i
                                canvas?.strokeWidth = widths[i]
                                canvas?.updateSelectedAnnotation(strokeWidth: widths[i])
                            } label: {
                                Circle()
                                    .fill(widthRaw == i ? RuneTheme.textPrimary : RuneTheme.textSecondary.opacity(0.45))
                                    .frame(width: CGFloat(4 + i * 3))
                                    .frame(width: 22, height: 24)
                            }
                            .buttonStyle(RuneTheme.RunePressStyle())
                            .help("粗细：\(["细", "中", "粗"][min(i, 2)])")
                        }
                    }
                }
            }

            RuneTheme.groupSeparator

            // ── 撤销
            Button {
                canvas?.undo()
                canvas?.needsDisplay = true
            } label: {
                RuneTheme.toolIcon("arrow.uturn.backward", active: false)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("撤销 (⌘Z)")

            RuneTheme.groupSeparator

            // ── 功能组（截图之后展示的功能：选字复制 / 滚动长图）
            Button {
                canvas?.toggleOCRMode { message in
                    ToastWindow.shared.show(title: "文字识别", message: message, systemIcon: "doc.text.viewfinder")
                }
            } label: {
                RuneTheme.toolIcon("doc.text.viewfinder", active: canvas?.ocrMode == true)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("选字模式：识别图里的文字，点一块复制一块，拖动选一段；再点一次或 Esc 退出")

            Button {
                controller.requestScrollCapture()
            } label: {
                RuneTheme.toolIcon("arrow.down.doc", active: false)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("滚动长图：把当前选区转为滚动截图，往下滚完拼成一张长图")

            Button {
                controller.requestBurstCapture()
            } label: {
                RuneTheme.toolIcon("camera", active: false)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("连拍：对当前选区连续抓拍，随时点关闭停止")

            // ── 复制 / 贴图（纯图标，悬停有中文提示）
            Button {
                canvas?.copyImageToPasteboard()
            } label: {
                RuneTheme.toolIcon("doc.on.doc", active: false)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("复制到剪贴板 (⌘C)")

            Button {
                canvas?.pinImage()
                controller.cancel()
            } label: {
                RuneTheme.toolIcon("pin", active: false)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("钉在桌面上（贴图）")

            RuneTheme.groupSeparator

            // ── 取消 / 保存
            HStack(spacing: 8) {
                Button {
                    controller.cancel()
                } label: {
                    RuneTheme.secondaryButtonLabel("取消")
                }
                .buttonStyle(RuneTheme.RunePressStyle())
                .help("放弃截图 (Esc)")

                Button {
                    controller.confirm()
                } label: {
                    RuneTheme.primaryButtonLabel("保存")
                }
                .buttonStyle(RuneTheme.RunePressStyle())
                .help("保存 (Enter)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: RuneTheme.barHeight)
        .background(RuneTheme.barBackground)
        // 铁保险：内容绝不允许被横向压缩（宁可溢出也不压扁按钮）；
        // 真实宽度由 GeometryReader 量好后上报给控制器，面板照抄这个数。
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { controller.toolbarWidthChanged(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in
                        controller.toolbarWidthChanged(w)
                    }
            }
        )
    }

    /// 精选图标映射（统一线性风格；覆盖编辑器的默认选型）
    private func iconName(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "arrow.up.and.down.and.arrow.left.and.right"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "character.cursor.ibeam"
        case .blur: "checkerboard.rectangle"
        case .spotlight: "light.max"
        case .numberedCircle: "1.circle"
        default: "circle"
        }
    }

    /// 悬停说明：名称 + 一句话用法（小白也能看懂）
    private func tooltip(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "选择：点选已画的标注，拖动位置，按 Delete 删除"
        case .rectangle: "矩形：在图上拖拽画一个方框"
        case .arrow: "箭头：拖拽画一个指示箭头"
        case .text: "文字：点击图上任意位置输入文字"
        case .blur: "马赛克：拖拽框住想打码的区域"
        case .spotlight: "聚光灯：拖一块区域，其余部分压暗突出重点"
        case .numberedCircle: "编号圆点：点击放置编号（1、2、3…自动递增）"
        default: tool.title
        }
    }
}

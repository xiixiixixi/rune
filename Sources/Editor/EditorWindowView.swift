import SwiftUI

struct EditorWindowView: View {
    @Bindable var urlHolder: CurrentURL
    @State private var model = EditorModel()
    @State private var showsInspector = true
    @State private var confirmsMovingCaptureToTrash = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                EditorCanvasView(model: model)
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 112)
                    .frame(minWidth: 620, minHeight: 470)

                EditorToolShelf(model: model)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
            }
            .background(RuneTheme.editorWorkspace)

            if showsInspector {
                Rectangle()
                    .fill(RuneTheme.paperSeparator)
                    .frame(width: 1)

                EditorInspectorView(model: model)
                    .frame(width: 286)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .tint(RuneTheme.paperAccent)
        .environment(\.colorScheme, .light)
        .overlay(alignment: .bottom) {
            if let message = model.toastMessage {
                Text(message)
                    .font(RuneFont.swiftUI(size: 13, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RuneTheme.chromeBase.opacity(0.92), in: Capsule())
                    .overlay(Capsule().strokeBorder(RuneTheme.chromeLine, lineWidth: 1))
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation { model.toastMessage = nil }
                        }
                    }
            }
        }
        .background {
            AnnotationKeyCommandHandler(
                onDelete: { model.deleteSelectedAnnotation() },
                onUndo: { model.undo() },
                onRedo: { model.redo() },
                onSelectAll: { model.selectAllAnnotations() },
                onSelectTool: { tool in model.selectTool(tool) }
            )
        }
        .toolbarBackgroundHiddenIfAvailable()
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        showsInspector.toggle()
                    }
                } label: {
                    Label(
                        showsInspector ? "隐藏属性" : "显示属性",
                        systemImage: "sidebar.right"
                    )
                }
                .help(showsInspector ? "收起工具面板" : "显示工具面板")
                .accessibilityLabel(showsInspector ? "收起工具面板" : "显示工具面板")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Spacer()

                Menu {
                    Button {
                        Task {
                            let count = await model.autoRedactPII()
                            if count == 0 {
                                model.toastMessage = "未检测到敏感信息"
                            }
                        }
                    } label: {
                        Label("隐私信息打码", systemImage: "eye.slash")
                    }

                    Button {
                        Task { await model.autoRedactFaces() }
                    } label: {
                        Label("人脸打码", systemImage: "face.dashed")
                    }
                } label: {
                    Label("自动打码", systemImage: "eye.slash")
                }
                .help("自动处理隐私信息或人脸")
                .accessibilityLabel("自动打码")

                Button {
                    Task { await copyToClipboard() }
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Menu {
                    Button("删除这张截图", systemImage: "trash", role: .destructive) {
                        confirmsMovingCaptureToTrash = true
                    }
                    Divider()
                    Button("关闭编辑器", systemImage: "xmark") {
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("更多操作")
                .accessibilityLabel("更多操作")

                Button {
                    Task { await exportImage() }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(RuneTheme.paperInk)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear {
            model.loadImage(from: urlHolder.url)
        }
        .onChange(of: urlHolder.url) { _, newURL in
            model.loadImage(from: newURL)
        }
        .alert("把这张截图移到废纸篓？", isPresented: $confirmsMovingCaptureToTrash) {
            Button("移到废纸篓", role: .destructive) { deleteCapture() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("截图之后仍可以从废纸篓恢复。")
        }
    }

    private func exportImage() async {
        guard let rendered = model.renderFinal() else {
            withAnimation { model.toastMessage = "导出失败，无法生成图片" }
            return
        }

        let dir = AppPreferences.saveDirectory
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let ext = AppPreferences.exportFormat.fileExtension
        let path = "\(dir)/Rune_\(stamp).\(ext)"
        let url = URL(fileURLWithPath: path)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            AppPreferences.exportFormat.utType as CFString,
            1, nil
        ) else {
            withAnimation { model.toastMessage = "无法写入保存位置" }
            return
        }

        var options: [CFString: Any] = [:]
        if AppPreferences.exportFormat == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = AppPreferences.exportQuality
        }

        CGImageDestinationAddImage(dest, rendered, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            withAnimation { model.toastMessage = "导出失败，请检查磁盘空间" }
            return
        }

        if let sourceURL = model.sourceURL {
            let baseURL = CaptureOrchestrator.baseImageURL(for: url)
            try? FileManager.default.copyItem(at: sourceURL, to: baseURL)

            _ = await HistoryStore.shared.importCapture(from: url, deleteSource: false, kind: .screenshot)
        }

        if AppPreferences.copyAfterSave {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let nsImage = NSImage(contentsOf: url) {
                pb.writeObjects([nsImage])
            }
        }

        withAnimation { model.toastMessage = "已导出" }
        try? await Task.sleep(for: .seconds(1.0))
        NSApp.keyWindow?.close()
    }

    private func deleteCapture() {
        let url = urlHolder.url
        if let record = HistoryStore.shared.records.first(where: {
            HistoryStore.shared.urlForRecord($0) == url
                || HistoryStore.shared.displayURLForRecord($0) == url
        }) {
            HistoryStore.shared.deleteRecord(record)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        NSApp.keyWindow?.close()
    }

    private func copyToClipboard() async {
        guard let rendered = model.renderFinal() else { return }

        let nsImage = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
        withAnimation { model.toastMessage = "已复制到剪贴板" }
    }
}

// MARK: - Floating editor tool shelf

private struct EditorToolShelf: View {
    @Bindable var model: EditorModel

    private let tools: [AnnotationTool] = [
        .select, .rectangle, .arrow, .text, .blur, .spotlight,
        .numberedCircle, .ellipse, .line, .filledRectangle, .freehand,
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index == 7 {
                    Rectangle()
                        .fill(RuneTheme.chromeLine)
                        .frame(width: 1, height: 38)
                        .padding(.horizontal, 6)
                }

                EditorToolShelfButton(
                    tool: tool,
                    isSelected: model.selectedTool == tool
                ) {
                    model.selectTool(tool)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RuneTheme.barBackground)
        .fixedSize()
    }
}

private struct EditorToolShelfButton: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.systemImage)
                    .font(RuneFont.swiftUI(size: 17, weight: .medium))
                Text(tool.title)
                    .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? RuneTheme.annotationAccent : RuneTheme.chromeText.opacity(isHovered ? 1 : 0.78))
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? RuneTheme.annotationAccent.opacity(0.13)
                            : (isHovered ? RuneTheme.chromeLine.opacity(0.72) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? RuneTheme.annotationAccent.opacity(0.42) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .onHover { isHovered = $0 }
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

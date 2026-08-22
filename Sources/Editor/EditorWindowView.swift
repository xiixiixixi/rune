import SwiftUI

struct EditorWindowView: View {
    @Bindable var urlHolder: CurrentURL
    @State private var model = EditorModel()
    @State private var showsInspector = true
    @State private var confirmsMovingCaptureToTrash = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            if showsInspector {
                EditorInspectorView(model: model)
                    .frame(width: 264)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            EditorCanvasView(model: model)
                .frame(minWidth: 500, minHeight: 400)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(RuneTheme.accent)
        .overlay(alignment: .bottom) {
            if let message = model.toastMessage {
                Text(message)
                    .font(RuneFont.swiftUI(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 24)
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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        showsInspector.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
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
                .tint(RuneTheme.accent)
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

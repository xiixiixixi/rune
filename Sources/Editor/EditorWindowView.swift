import SwiftUI

struct EditorWindowView: View {
    @Bindable var urlHolder: CurrentURL
    @State private var model = EditorModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            EditorInspectorView(model: model)
                .frame(width: 280)

            EditorCanvasView(model: model)
                .frame(minWidth: 500, minHeight: 400)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .overlay(alignment: .bottom) {
            if let message = model.toastMessage {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
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

                Button("取消") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.escape, modifiers: [])

                // P1：自动 PII 打码（识别手机号/邮箱/身份证并模糊）
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
                .help("自动打码手机号/邮箱/身份证号")

                // P1：自动人脸打码（参考 macshot VNDetectFaceRectanglesRequest）
                Button {
                    Task { await model.autoRedactFaces() }
                } label: {
                    Label("人脸打码", systemImage: "face.dashed")
                }
                .help("自动打码所有人脸")

                Button {
                    deleteCapture()
                } label: {
                    Label("删除", systemImage: "trash")
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await copyToClipboard() }
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    Task { await exportImage() }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear {
            model.loadImage(from: urlHolder.url)
        }
        .onChange(of: urlHolder.url) { _, newURL in
            model.loadImage(from: newURL)
        }
    }

    private func exportImage() async {
        guard let rendered = model.renderFinal() else { return }

        let dir = AppPreferences.saveDirectory
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let ext = AppPreferences.exportFormat.fileExtension
        let path = "\(dir)/Rune_\(stamp).\(ext)"
        let url = URL(fileURLWithPath: path)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            AppPreferences.exportFormat.utType as CFString,
            1, nil
        ) else { return }

        var options: [CFString: Any] = [:]
        if AppPreferences.exportFormat == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = AppPreferences.exportQuality
        }

        CGImageDestinationAddImage(dest, rendered, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        if let sourceURL = model.sourceURL {
            let baseURL = CaptureOrchestrator.baseImageURL(for: url)
            try? FileManager.default.copyItem(at: sourceURL, to: baseURL)

            if let record = HistoryStore.shared.records.first(where: {
                HistoryStore.shared.urlForRecord($0) == sourceURL
                    || HistoryStore.shared.displayURLForRecord($0) == sourceURL
            }) {
                HistoryStore.shared.deleteRecord(record)
            }

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
        }
        try? FileManager.default.removeItem(at: url)
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

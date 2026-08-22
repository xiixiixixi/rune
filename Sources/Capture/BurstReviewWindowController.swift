import AppKit
import SwiftUI

/// 连拍结束后的整理台：选片、移到废纸篓、导出、打开文件夹。
/// 连拍是批量任务，结束后需要一个真正能整理结果的地方，不能只丢一个 Finder 文件夹给用户。
@MainActor
final class BurstReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = BurstReviewWindowController()

    private var window: NSWindow?
    private var directory: URL?

    private override init() {}

    func show(directory: URL, on screen: NSScreen? = nil, preselectedCount: Int = 0) {
        dismiss()
        self.directory = directory

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        let content = BurstReviewView(
            urls: urls,
            preselectedCount: preselectedCount,
            directory: directory,
            onExport: { [weak self] selected in self?.export(selected) },
            onOpenFolder: { NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [directory] : [urls[0]]) },
            onClose: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: content)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "连拍结果"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        window.contentView = hosting
        window.delegate = self
        if let screen = screen ?? NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
        directory = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        directory = nil
    }

    private func export(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let picker = NSOpenPanel()
        picker.title = "导出所选连拍图片"
        picker.message = "选择一个文件夹，Rune 会把所选图片复制进去"
        picker.prompt = "导出到这里"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true

        guard picker.runModal() == .OK, let destination = picker.url else { return }

        var exported = 0
        for source in urls {
            let target = uniqueURL(for: source.lastPathComponent, in: destination)
            do {
                try FileManager.default.copyItem(at: source, to: target)
                exported += 1
            } catch {
                print("Rune 连拍：导出失败 \(source.lastPathComponent)：\(error)")
            }
        }

        ToastWindow.shared.show(
            title: "导出完成",
            message: "已导出 \(exported) 张到 \(destination.lastPathComponent)",
            systemIcon: "checkmark.circle"
        )
    }

    private func uniqueURL(for filename: String, in directory: URL) -> URL {
        var target = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: target.path) else { return target }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var suffix = 2
        repeat {
            target = directory.appendingPathComponent("\(stem)_\(suffix).\(ext)")
            suffix += 1
        } while FileManager.default.fileExists(atPath: target.path)
        return target
    }
}

private struct BurstReviewView: View {
    @State private var items: [URL]
    @State private var selected: Set<URL>

    let directory: URL
    let onExport: ([URL]) -> Void
    let onOpenFolder: () -> Void
    let onClose: () -> Void

    init(
        urls: [URL],
        preselectedCount: Int = 0,
        directory: URL,
        onExport: @escaping ([URL]) -> Void,
        onOpenFolder: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _items = State(initialValue: urls)
        _selected = State(initialValue: Set(urls.prefix(max(0, preselectedCount))))
        self.directory = directory
        self.onExport = onExport
        self.onOpenFolder = onOpenFolder
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            gallery
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
        .onDeleteCommand(perform: moveSelectedToTrash)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(RuneTheme.accent)
                .frame(width: 34, height: 34)
                .background(RuneTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text("连拍结果")
                    .font(.system(size: 18, weight: .semibold))
                Text("点一下选择画面；右键可以编辑或在访达中查看")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(items.count) 张")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text("已选 \(selected.count) 张")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var gallery: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("这一组已经清空")
                    .font(.system(size: 14, weight: .medium))
                Text("移到废纸篓的图片仍可以恢复")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, url in
                        thumbnail(url: url, index: index)
                    }
                }
                .padding(18)
            }
        }
    }

    private func thumbnail(url: URL, index: Int) -> some View {
        let isSelected = selected.contains(url)
        return Button {
            if isSelected {
                selected.remove(url)
            } else {
                selected.insert(url)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 112)
                    .background(Color.black.opacity(0.035))

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? RuneTheme.accent : .white.opacity(0.92))
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? RuneTheme.accent : Color.primary.opacity(0.10), lineWidth: isSelected ? 2 : 0.5)
            )
            .overlay(alignment: .bottomLeading) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(7)
            }
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .accessibilityLabel("第 \(index + 1) 张，\(isSelected ? "已选择" : "未选择")")
        .contextMenu {
            Button("在编辑器中打开", systemImage: "pencil") {
                EditorWindowController.shared.open(url: url)
            }
            Button("在访达中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("移到废纸篓", systemImage: "trash", role: .destructive) {
                selected = [url]
                moveSelectedToTrash()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(selected.count == items.count ? "取消全选" : "全选") {
                selected = selected.count == items.count ? [] : Set(items)
            }
            .disabled(items.isEmpty)

            Button("移到废纸篓", systemImage: "trash", role: .destructive) {
                moveSelectedToTrash()
            }
            .disabled(selected.isEmpty)

            Spacer()

            Button("打开文件夹", systemImage: "folder") {
                onOpenFolder()
            }

            Button("导出所选", systemImage: "square.and.arrow.up") {
                onExport(items.filter { selected.contains($0) })
            }
            .disabled(selected.isEmpty)

            if !selected.isEmpty, selected.count < items.count {
                Button("只保留所选") {
                    keepOnlySelected()
                }
                .help("把没有选中的画面移到废纸篓")
            }

            Button {
                onClose()
            } label: {
                RuneTheme.primaryButtonLabel("完成")
            }
            .buttonStyle(RuneTheme.RunePressStyle())
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
    }

    private func moveSelectedToTrash() {
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "把选中的 \(selected.count) 张移到废纸篓？"
        alert.informativeText = "这些图片可以从废纸篓恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let targets = selected
        for url in targets {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        items.removeAll { targets.contains($0) }
        selected.removeAll()
    }

    private func keepOnlySelected() {
        guard !selected.isEmpty else { return }
        let rejected = items.filter { !selected.contains($0) }
        guard !rejected.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "只保留选中的 \(selected.count) 张？"
        alert.informativeText = "其余 \(rejected.count) 张会移到废纸篓，之后仍可恢复。"
        alert.addButton(withTitle: "只保留所选")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for url in rejected {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        items.removeAll { rejected.contains($0) }
        selected = Set(items)
    }
}

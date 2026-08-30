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
        let hosting = NSHostingView(rootView: content.runeTypography())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "连拍结果"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = RuneTheme.nsBackground
        window.appearance = NSAppearance(named: .darkAqua)
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
        VStack(spacing: 12) {
            header
            gallery
            footer
        }
        .padding(.bottom, 14)
        .background(RuneAmbientBackdrop())
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onClose)
        .onDeleteCommand(perform: moveSelectedToTrash)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "camera.fill")
                .font(RuneFont.swiftUI(size: 16, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("连拍结果")
                    .font(RuneFont.swiftUI(size: 15, weight: .medium))
                Text("点一下选择画面；右键可以编辑或在访达中查看")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(items.count) 张")
                    .font(RuneFont.swiftUI(size: 13, weight: .medium, design: .monospaced))
                Text("已选 \(selected.count) 张")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var gallery: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(RuneFont.swiftUI(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("这一组已经清空")
                    .font(RuneFont.swiftUI(size: 14, weight: .medium))
                Text("移到废纸篓的图片仍可以恢复")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
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
            .background(RuneCardBackground(cornerRadius: RuneTheme.plateCorner))
            .padding(.horizontal, 16)
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

                RuneSelectionMark(isSelected: isSelected, size: 18)
                    .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous))
            .overlay {
                if isSelected {
                    RuneSpectralBorder(cornerRadius: RuneTheme.plateCorner, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(String(format: "%02d", index + 1))
                    .font(RuneFont.swiftUI(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous)
                            .fill(.black.opacity(0.62))
                    )
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

            Button("导出所选", systemImage: "square.and.arrow.up") {
                onExport(items.filter { selected.contains($0) })
            }
            .disabled(selected.isEmpty)

            Menu {
                Button("打开文件夹", systemImage: "folder") {
                    onOpenFolder()
                }
                if !selected.isEmpty, selected.count < items.count {
                    Divider()
                    Button("只保留所选", systemImage: "checkmark.circle") {
                        keepOnlySelected()
                    }
                }
            } label: {
                RuneTheme.secondaryButtonLabel("更多", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("打开文件夹或只保留所选")

            Button {
                onClose()
            } label: {
                RuneTheme.primaryButtonLabel("完成")
            }
            .buttonStyle(RuneTheme.RunePressStyle())
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RuneGlassBackground(cornerRadius: RuneTheme.barCorner, elevation: .floating))
        .padding(.horizontal, 16)
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

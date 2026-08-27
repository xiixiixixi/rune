import AppKit
import SwiftUI

enum CaptureLibrarySection: String, CaseIterable, Identifiable {
    case all = "全部素材"
    case favorites = "收藏"
    case screenshots = "截图"
    case recordings = "录屏"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "star"
        case .screenshots: return "photo.on.rectangle.angled"
        case .recordings: return "video"
        }
    }
}

/// Rune 素材库：把截图和录屏从“设置”中移出，成为可以搜索、整理和复用的一等功能。
struct CaptureLibraryView: View {
    @State private var selectedSection: CaptureLibrarySection = .all
    @State private var searchText = ""

    init(
        initialSection: CaptureLibrarySection = .all,
        initialSearchText: String = ""
    ) {
        _selectedSection = State(initialValue: initialSection)
        _searchText = State(initialValue: initialSearchText)
    }

    private var visibleRecords: [CaptureRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return HistoryStore.shared.records.filter { record in
            let matchesSection = switch selectedSection {
            case .all: true
            case .favorites: record.isFavorite
            case .screenshots: record.kind == .screenshot
            case .recordings: record.kind == .recording
            }

            guard matchesSection else { return false }
            guard !query.isEmpty else { return true }

            return record.displayName.localizedCaseInsensitiveContains(query)
                || (record.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false)
                || (record.sourceWindowTitle?.localizedCaseInsensitiveContains(query) ?? false)
                || (record.sourceBundleID?.localizedCaseInsensitiveContains(query) ?? false)
                || (record.ocrText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)

            Divider()

            VStack(spacing: 0) {
                libraryHeader

                Divider()

                libraryContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 940, minHeight: 640)
        .onAppear {
            HistoryStore.shared.indexMissingSearchMetadata()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RuneTheme.accent)
                Text("Rune")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()

            VStack(spacing: 4) {
                ForEach(CaptureLibrarySection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .frame(width: 18)

                            Text(section.rawValue)

                            Spacer()

                            Text("\(count(for: section))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .foregroundStyle(selectedSection == section ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedSection == section ? RuneTheme.accentDim : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.rawValue)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }
            }
            .padding(10)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 6) {
                Label("所有识别和搜索都在本机完成", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !HistoryStore.shared.indexingRecordIDs.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在整理旧截图…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var libraryHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.rawValue)
                    .font(.title2.weight(.semibold))

                Text(headerDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索名称、来源应用或图片文字", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 250)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .runeGlassSurface(cornerRadius: 9, interactive: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if visibleRecords.isEmpty {
            LibraryEmptyState(
                hasSearch: !searchText.isEmpty,
                section: selectedSection,
                clearSearch: { searchText = "" },
                beginCapture: beginCapture
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 18),
                        count: 3
                    ),
                    spacing: 18
                ) {
                    ForEach(visibleRecords) { record in
                        CaptureLibraryCard(record: record)
                    }
                }
                .padding(24)
            }
        }
    }

    private var headerDescription: String {
        if !searchText.isEmpty {
            return "找到 \(visibleRecords.count) 项"
        }
        switch selectedSection {
        case .all: return "截图与录屏，随时查找和复用"
        case .favorites: return "保留最常用的内容"
        case .screenshots: return "可以搜索图片中识别到的文字"
        case .recordings: return "继续剪辑、复制或分享录屏"
        }
    }

    private func count(for section: CaptureLibrarySection) -> Int {
        switch section {
        case .all: HistoryStore.shared.records.count
        case .favorites: HistoryStore.shared.records.count(where: \.isFavorite)
        case .screenshots: HistoryStore.shared.records.count { $0.kind == .screenshot }
        case .recordings: HistoryStore.shared.records.count { $0.kind == .recording }
        }
    }

    @MainActor
    private func beginCapture() {
        let screen = NSScreen.main
        CaptureLibraryWindowController.shared.close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            await CaptureOrchestrator.shared.performCapture(.main, on: screen)
        }
    }
}

private struct LibraryEmptyState: View {
    let hasSearch: Bool
    let section: CaptureLibrarySection
    let clearSearch: () -> Void
    let beginCapture: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hasSearch ? "text.magnifyingglass" : section.icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                Text(hasSearch ? "没有找到匹配内容" : emptyTitle)
                    .font(.headline)
                Text(hasSearch ? "可以换一个关键词，或搜索截图中出现过的文字。" : emptyDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button(hasSearch ? "清除搜索" : "开始截图", action: hasSearch ? clearSearch : beginCapture)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyTitle: String {
        switch section {
        case .all: return "还没有素材"
        case .favorites: return "还没有收藏"
        case .screenshots: return "还没有截图"
        case .recordings: return "还没有录屏"
        }
    }

    private var emptyDetail: String {
        switch section {
        case .all, .screenshots: return "完成一次截图后，就能在这里搜索、复制、贴图和继续编辑。"
        case .favorites: return "点素材右上角的星标，把经常使用的内容留在这里。"
        case .recordings: return "完成一次录屏后，就能在这里继续剪辑或复制文件。"
        }
    }
}

private struct CaptureLibraryCard: View {
    let record: CaptureRecord

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @State private var isCopied = false
    @State private var confirmsMovingToTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Button(action: openRecord) {
                    ZStack {
                        Color(nsColor: .underPageBackgroundColor)

                        if let thumbnail {
                            GeometryReader { proxy in
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .clipped()
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if record.kind == .recording {
                            Circle()
                                .fill(.black.opacity(0.68))
                                .frame(width: 42, height: 42)
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .offset(x: 1)
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(record.kind == .recording ? "打开录屏 \(record.displayName)" : "预览截图 \(record.displayName)")

                Button {
                    HistoryStore.shared.setFavorite(!record.isFavorite, for: record.id)
                } label: {
                    Image(systemName: record.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(record.isFavorite ? Color(nsColor: .systemYellow) : .white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(9)
                .help(record.isFavorite ? "取消收藏" : "收藏")
                .accessibilityLabel(record.isFavorite ? "取消收藏 \(record.displayName)" : "收藏 \(record.displayName)")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text(record.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if let sourceName = record.sourceAppName {
                    if let sourceIcon {
                        Image(nsImage: sourceIcon)
                            .resizable()
                            .frame(width: 15, height: 15)
                    } else {
                        Image(systemName: "app")
                            .frame(width: 15, height: 15)
                    }
                    Text(sourceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(record.sourceWindowTitle ?? sourceName)
                }

                Label(
                    "\(record.pixelWidth) × \(record.pixelHeight)",
                    systemImage: record.kind == .recording ? "video" : "photo"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

                Spacer()

                Button(action: copyRecord) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCopied ? RuneTheme.accent : .secondary)
                .help(isCopied ? "已复制" : "复制")
                .accessibilityLabel(isCopied ? "已复制 \(record.displayName)" : "复制 \(record.displayName)")

                if record.kind == .screenshot {
                    Button(action: pinRecord) {
                        Image(systemName: "pin")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("贴到屏幕")
                    .accessibilityLabel("贴到屏幕 \(record.displayName)")
                }

                Menu {
                    Button(action: editRecord) {
                        Label(record.kind == .recording ? "继续剪辑" : "在编辑器中打开", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            HistoryStore.shared.displayURLForRecord(record),
                        ])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        confirmsMovingToTrash = true
                    } label: {
                        Label("移到废纸篓", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作 \(record.displayName)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.92 : 0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                .strokeBorder(isHovered ? RuneTheme.accent.opacity(0.45) : RuneTheme.separator.opacity(0.55), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous))
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(contentsOf: HistoryStore.shared.displayURLForRecord(record)) ?? NSItemProvider()
        }
        .task(id: record.id) {
            await loadThumbnail()
        }
        .alert("把这项素材移到废纸篓？", isPresented: $confirmsMovingToTrash) {
            Button("移到废纸篓", role: .destructive) {
                HistoryStore.shared.deleteRecord(record)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后仍可以从废纸篓恢复。")
        }
    }

    private var sourceIcon: NSImage? {
        guard let bundleID = record.sourceBundleID,
              let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID
              ) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private func loadThumbnail() async {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let kind = record.kind
        let image = await Task.detached(priority: .utility) {
            HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 600)
        }.value
        if let image {
            thumbnail = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
    }

    @MainActor
    private func copyRecord() {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if record.kind == .recording {
            pasteboard.writeObjects([url as NSURL])
        } else if let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        }
        HistoryStore.shared.markUsed(record.id)
        isCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            isCopied = false
        }
    }

    @MainActor
    private func openRecord() {
        HistoryStore.shared.markUsed(record.id)
        if record.kind == .recording {
            VideoEditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
        } else {
            PreviewOverlay.shared.show(url: HistoryStore.shared.displayURLForRecord(record))
        }
    }

    @MainActor
    private func editRecord() {
        HistoryStore.shared.markUsed(record.id)
        if record.kind == .recording {
            VideoEditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
        } else {
            EditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
        }
    }

    @MainActor
    private func pinRecord() {
        HistoryStore.shared.markUsed(record.id)
        PinnedScreenshotController.shared.pin(
            url: HistoryStore.shared.displayURLForRecord(record),
            placement: .bottomRight
        )
    }
}

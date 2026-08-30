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

/// Rune 素材库——一间安静的陈列室。
///
/// 屏幕上唯一饱和的东西是用户的截图：没有卡片套卡片，缩略图就是展品，
/// 挂在纸面上，结构只靠细线与留白。悬停时浮现裁切角线——校样即将付印。
struct CaptureLibraryView: View {
    @State private var selectedSection: CaptureLibrarySection = .all
    @State private var searchText = ""
    @State private var selectedRecordID: UUID?
    @FocusState private var searchIsFocused: Bool

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

    private var selectedRecord: CaptureRecord? {
        visibleRecords.first { $0.id == selectedRecordID } ?? visibleRecords.first
    }

    var body: some View {
        ZStack {
            RuneAmbientBackdrop()

            HStack(spacing: 0) {
                librarySidebar
                    .frame(width: 184)

                libraryStageLayout
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 680)
        .onAppear {
            HistoryStore.shared.indexMissingSearchMetadata()
            selectedRecordID = selectedRecordID ?? visibleRecords.first?.id
        }
        .onChange(of: selectedSection) { _, _ in
            selectedRecordID = visibleRecords.first?.id
        }
        .onChange(of: searchText) { _, _ in
            if let selectedRecordID,
               visibleRecords.contains(where: { $0.id == selectedRecordID }) {
                return
            }
            selectedRecordID = visibleRecords.first?.id
        }
    }

    // MARK: - Settings-aligned application shell

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RuneBrandIcon(size: 34)
                Text("Rune")
                    .font(RuneFont.swiftUI(size: 15, weight: .semibold))
                    .foregroundStyle(RuneTheme.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 52)
            .padding(.bottom, 28)

            VStack(spacing: 5) {
                ForEach(CaptureLibrarySection.allCases) { section in
                    LibrarySectionRow(
                        section: section,
                        isSelected: selectedSection == section,
                        count: count(for: section)
                    ) {
                        selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("本地优先")
                    .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textSecondary)

                if !HistoryStore.shared.indexingRecordIDs.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在整理旧截图…")
                            .font(RuneFont.swiftUI(size: 9.5))
                            .foregroundStyle(RuneTheme.textMuted)
                    }
                }

                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                    .font(RuneFont.mono(size: 9, weight: .medium))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.16))
        .overlay(alignment: .trailing) {
            RuneTheme.verticalHairline
        }
    }

    private var libraryStageLayout: some View {
        GeometryReader { proxy in
            let stageWidth = min(336, max(316, proxy.size.width * 0.34))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    libraryPageHeader
                    librarySearch
                    libraryContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                libraryDetailStage
                    .frame(width: stageWidth)
                    .padding(.trailing, 24)
                    .padding(.vertical, 20)
            }
        }
    }

    private var libraryPageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(selectedSection.rawValue)
                .font(RuneFont.swiftUI(size: 24, weight: .semibold))
                .foregroundStyle(RuneTheme.textPrimary)
                .lineLimit(1)

            Text(headerDescription)
                .font(RuneFont.swiftUI(size: 11.5))
                .foregroundStyle(RuneTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 34)
        .padding(.top, 42)
    }

    private var librarySearch: some View {
        HStack(spacing: 8) {
            RuneGlyph(
                systemImage: "magnifyingglass",
                isActive: searchIsFocused,
                size: 12
            )

            TextField(
                "搜索名称、来源应用或图片文字",
                text: $searchText,
                prompt: Text("搜索名称、来源应用或图片文字")
                    .foregroundStyle(RuneTheme.textMuted)
            )
            .textFieldStyle(.plain)
            .font(RuneFont.swiftUI(size: 12))
            .focused($searchIsFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RuneTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }

            Text("\(visibleRecords.count) 项")
                .font(RuneFont.mono(size: 9.5, weight: .medium))
                .foregroundStyle(RuneTheme.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background {
            RuneGlassBackground(
                cornerRadius: 6,
                tint: RuneTheme.glassTint,
                interactive: true,
                elevation: .embedded
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    searchIsFocused ? RuneTheme.textPrimary.opacity(0.42) : Color.clear,
                    lineWidth: 0.8
                )
        )
        .padding(.horizontal, 34)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var libraryDetailStage: some View {
        if let selectedRecord {
            LibraryDetailPanel(record: selectedRecord)
        } else {
            LibraryDetailPlaceholder()
        }
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
            ScrollView(showsIndicators: false) {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16),
                    ],
                    spacing: 20
                ) {
                    ForEach(visibleRecords) { record in
                        CaptureLibraryCard(
                            record: record,
                            isSelected: selectedRecord?.id == record.id,
                            onSelect: { selectedRecordID = record.id }
                        )
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 与设置页相同的导航语言：暗面选中态 + 左侧光谱细线。
private struct LibrarySectionRow: View {
    let section: CaptureLibrarySection
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RuneGlyph(systemImage: section.icon, isActive: isSelected, size: 14)
                    .frame(width: 20)

                Text(section.rawValue)
                    .font(RuneFont.swiftUI(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? RuneTheme.textPrimary : RuneTheme.textSecondary)

                Spacer(minLength: 0)

                Text("\(count)")
                    .font(RuneFont.mono(size: 9, weight: .medium))
                    .foregroundStyle(RuneTheme.textMuted)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.052)
                            : (isHovered ? Color.white.opacity(0.035) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.13) : Color.clear, lineWidth: 0.7)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(RuneTheme.spectralGradient)
                        .frame(width: 1.5, height: 22)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 空态：一枚空的玻璃取景框，等第一张截图落进来；只有一个明确动作。
private struct LibraryEmptyState: View {
    let hasSearch: Bool
    let section: CaptureLibrarySection
    let clearSearch: () -> Void
    let beginCapture: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if hasSearch {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, height: 82)
                    .background(RuneCardBackground(cornerRadius: RuneTheme.plateCorner + 4))
                    .padding(.bottom, 26)
            }

            Text(hasSearch ? "没有找到匹配内容" : emptyTitle)
                .font(RuneFont.swiftUI(size: 15, weight: .medium))

            Text(hasSearch ? "可以换一个关键词，或搜索截图中出现过的文字。" : emptyDetail)
                .font(RuneFont.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 7)

            if hasSearch {
                Button("清除搜索", action: clearSearch)
                    .buttonStyle(RuneTheme.RunePressStyle())
                    .font(RuneFont.swiftUI(size: 13))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                            .fill(RuneTheme.graphiteRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                            .strokeBorder(RuneTheme.separator, lineWidth: 1)
                    )
                    .padding(.top, 22)
            } else {
                Button(action: beginCapture) {
                    RuneTheme.primaryButtonLabel("按下快门", systemImage: "camera.viewfinder")
                }
                .buttonStyle(RuneTheme.RunePressStyle())
                .padding(.top, 22)
            }
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

/// 展签（gallery plate）：缩略图平挂在纸上，悬停时四角浮现裁切角线；
/// 说明文字用两行小字，像美术馆墙上的展签。不再有卡片盒子。
private struct CaptureLibraryCard: View {
    let record: CaptureRecord
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @State private var isCopied = false
    @State private var confirmsMovingToTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            plate

            HStack(spacing: 0) {
                Text(record.displayName)
                    .font(RuneFont.swiftUI(size: 12, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.bottom, 5)
                    .overlay(alignment: .bottomLeading) {
                        if isSelected {
                            RuneSelectionUnderline(width: 38)
                        }
                    }

                Spacer(minLength: 8)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let sourceName = record.sourceAppName {
                    Text(sourceName)
                        .font(RuneFont.mono(size: 10))
                        .foregroundStyle(RuneTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(record.sourceWindowTitle ?? sourceName)
                }

                Spacer(minLength: 8)

                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(RuneFont.mono(size: 10))
                    .foregroundStyle(RuneTheme.textMuted)

                Text(record.createdAt.formatted(.relative(presentation: .named)))
                    .font(RuneFont.mono(size: 10))
                    .foregroundStyle(RuneTheme.textMuted.opacity(0.8))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.050)
                        : (isHovered ? Color.white.opacity(0.022) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.white.opacity(0.18) : Color.clear,
                    lineWidth: 0.8
                )
        )
        .overlay(
            RuneSpectralBorder(cornerRadius: RuneTheme.cardCorner, lineWidth: 0.65)
                .opacity(isSelected ? 0.52 : 0)
        )
        .contentShape(Rectangle())
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

    // MARK: 图版：截图本身就是唯一饱和的东西。

    private var plate: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RuneTheme.graphiteRaised

                        if let thumbnail {
                            GeometryReader { proxy in
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .clipped()
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if record.kind == .recording {
                            Circle()
                                .fill(.black.opacity(0.6))
                                .frame(width: 38, height: 38)
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .offset(x: 1)
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                            .strokeBorder(
                                isHovered ? Color.white.opacity(0.48) : Color.white.opacity(0.18),
                                lineWidth: 0.8
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous))

                    // 悬停操作：贴在图上的小圆钮，平时完全退场。
                    if isHovered {
                        HStack(spacing: 6) {
                            plateButton(
                                isCopied ? "checkmark" : "doc.on.doc",
                                help: isCopied ? "已复制" : "复制"
                            ) {
                                copyRecord()
                            }

                            if record.kind == .screenshot {
                                plateButton("pin", help: "贴到屏幕") {
                                    pinRecord()
                                }
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
                        .padding(8)
                    }

                    if isCopied {
                        Text("已复制")
                            .font(RuneFont.swiftUI(size: 10, weight: .medium))
                            .foregroundStyle(RuneTheme.primaryOnFill)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                                    .fill(RuneTheme.primaryFill)
                            )
                            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .allowsHitTesting(false)
                    }
                }

                // 星标：收藏过的常驻，其余悬停才出现。
                Button {
                    HistoryStore.shared.setFavorite(!record.isFavorite, for: record.id)
                } label: {
                    Image(systemName: record.isFavorite || isHovered ? "star.fill" : "star")
                        .font(RuneFont.swiftUI(size: 11, weight: .medium))
                        .foregroundStyle(record.isFavorite ? Color(nsColor: .systemYellow) : .white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.55), in: Circle())
                        .opacity(record.isFavorite || isHovered ? 1 : 0)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(record.isFavorite ? "取消收藏" : "收藏")
                .accessibilityLabel(record.isFavorite ? "取消收藏 \(record.displayName)" : "收藏 \(record.displayName)")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(record.kind == .recording ? "打开录屏 \(record.displayName)" : "预览截图 \(record.displayName)")
    }

    private func plateButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(RuneFont.swiftUI(size: 10, weight: .medium))
                .foregroundStyle(RuneTheme.textPrimary.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(RuneTheme.separator.opacity(0.6), lineWidth: 0.5))
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .help(help)
        .accessibilityLabel("\(help) \(record.displayName)")
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

// MARK: - Selection inspector

private struct LibraryDetailPlaceholder: View {
    var body: some View {
        RuneGlassStage(
            title: "素材详情",
            subtitle: "选择一项素材后在这里查看和操作"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有可查看的素材")
                    .font(RuneFont.swiftUI(size: 12.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                Text("完成截图或录屏后，尺寸、来源和后续操作会出现在这里。")
                    .font(RuneFont.swiftUI(size: 10.5))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
        }
    }
}

private struct LibraryDetailPanel: View {
    let record: CaptureRecord

    @State private var thumbnail: NSImage?
    @State private var isCopied = false
    @State private var confirmsMovingToTrash = false

    var body: some View {
        RuneGlassStage(
            title: "素材详情",
            subtitle: record.kind == .recording ? "当前选中的录屏" : "当前选中的截图"
        ) {
            preview
                .padding(.top, 22)

            Text(record.displayName)
                .font(RuneFont.swiftUI(size: 14, weight: .semibold))
                .foregroundStyle(RuneTheme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 14)

            VStack(spacing: 0) {
                detailRow("类型", record.kind == .recording ? "录屏" : "截图")
                detailRow("尺寸", "\(record.pixelWidth) × \(record.pixelHeight)")
                detailRow("创建", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let source = record.sourceAppName {
                    detailRow("来源", source)
                }
            }
            .padding(.top, 12)

            HStack(spacing: 8) {
                Button(action: openRecord) {
                    RuneTheme.primaryButtonLabel(
                        record.kind == .recording ? "打开剪辑" : "打开预览",
                        systemImage: record.kind == .recording ? "play" : "arrow.up.right.square"
                    )
                }
                .buttonStyle(RuneTheme.RunePressStyle())

                Button(action: copyRecord) {
                    RuneTheme.secondaryButtonLabel(
                        isCopied ? "已复制" : "复制",
                        systemImage: isCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(RuneTheme.RunePressStyle())
            }
            .padding(.top, 16)

            VStack(spacing: 0) {
                detailAction("编辑", systemImage: "slider.horizontal.3", action: editRecord)

                if record.kind == .screenshot {
                    detailAction("贴到屏幕", systemImage: "pin", action: pinRecord)
                }

                detailAction(
                    record.isFavorite ? "取消收藏" : "收藏",
                    systemImage: record.isFavorite ? "star.fill" : "star",
                    action: toggleFavorite
                )

                detailAction("在访达中显示", systemImage: "folder", action: revealRecord)

                Button(role: .destructive) {
                    confirmsMovingToTrash = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "trash")
                            .frame(width: 16)
                        Text("移到废纸篓")
                        Spacer()
                    }
                    .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                    .foregroundStyle(RuneTheme.signal)
                    .frame(height: 34)
                    .overlay(alignment: .top) { RuneTheme.hairline }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)

            Spacer(minLength: 0)
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

    private var preview: some View {
        ZStack {
            RuneTheme.graphite

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }

            if record.kind == .recording {
                Image(systemName: "play.fill")
                    .font(RuneFont.swiftUI(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.62), in: Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(RuneTheme.separator, lineWidth: 1)
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(RuneTheme.textMuted)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .foregroundStyle(RuneTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(RuneFont.mono(size: 9.5, weight: .regular))
        .frame(height: 26)
        .overlay(alignment: .bottom) { RuneTheme.hairline }
    }

    private func detailAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RuneGlyph(systemImage: systemImage, size: 12)
                    .frame(width: 16)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
            .foregroundStyle(RuneTheme.textSecondary)
            .frame(height: 34)
            .overlay(alignment: .top) { RuneTheme.hairline }
        }
        .buttonStyle(.plain)
    }

    private func loadThumbnail() async {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let kind = record.kind
        let image = await Task.detached(priority: .utility) {
            HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 720)
        }.value
        if let image {
            thumbnail = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
    }

    private func openRecord() {
        HistoryStore.shared.markUsed(record.id)
        let url = HistoryStore.shared.displayURLForRecord(record)
        if record.kind == .recording {
            VideoEditorWindowController.shared.open(url: url)
        } else {
            PreviewOverlay.shared.show(url: url)
        }
    }

    private func editRecord() {
        HistoryStore.shared.markUsed(record.id)
        let url = HistoryStore.shared.displayURLForRecord(record)
        if record.kind == .recording {
            VideoEditorWindowController.shared.open(url: url)
        } else {
            EditorWindowController.shared.open(url: url)
        }
    }

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

    private func pinRecord() {
        HistoryStore.shared.markUsed(record.id)
        PinnedScreenshotController.shared.pin(
            url: HistoryStore.shared.displayURLForRecord(record),
            placement: .bottomRight
        )
    }

    private func toggleFavorite() {
        HistoryStore.shared.setFavorite(!record.isFavorite, for: record.id)
    }

    private func revealRecord() {
        NSWorkspace.shared.activateFileViewerSelecting([
            HistoryStore.shared.displayURLForRecord(record),
        ])
    }
}

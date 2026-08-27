import Foundation

/// 截图发生时的来源上下文。窗口截图记录精确窗口；区域截图记录选区中心
/// 最上层窗口；全屏截图回退到触发快捷键时的前台应用。
struct CaptureSource: Equatable, Sendable {
    let bundleIdentifier: String?
    let applicationName: String
    let windowTitle: String?
    /// 仅用于本次框选期间查询界面元素边界，不写入历史记录。
    let processID: pid_t?
}

/// Represents a captured screenshot or recording in the history.
struct CaptureRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var filename: String
    var pixelWidth: Int
    var pixelHeight: Int
    var kind: CaptureKind
    var hasAnnotations: Bool
    var beautifiedPath: String?
    /// 用户在素材库中看到的自定义名称；为空时继续显示文件名。
    var title: String?
    /// 截图中的本地 OCR 文字，用于素材库搜索。不会上传。
    var ocrText: String?
    /// 截图来自哪个应用/窗口。旧记录没有这些字段时保持为空。
    var sourceBundleID: String?
    var sourceAppName: String?
    var sourceWindowTitle: String?
    /// 收藏是最轻量的整理方式，也会作为未来同步的默认边界。
    var isFavorite: Bool
    /// 最近一次从素材库复制、打开或贴图的时间。
    var lastUsedAt: Date?
    var useCount: Int

    init(
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: CaptureKind = .screenshot,
        hasAnnotations: Bool = false,
        beautifiedPath: String? = nil,
        title: String? = nil,
        ocrText: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        isFavorite: Bool = false,
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.hasAnnotations = hasAnnotations
        self.beautifiedPath = beautifiedPath
        self.title = title
        self.ocrText = ocrText
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.isFavorite = isFavorite
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    var displayName: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? filename : trimmedTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, filename, pixelWidth, pixelHeight, kind
        case hasAnnotations, beautifiedPath, title, ocrText, isFavorite
        case sourceBundleID, sourceAppName, sourceWindowTitle
        case lastUsedAt, useCount
    }

    /// 兼容 0.7.3 及更早版本的 history.json；新字段缺失时使用安全默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        filename = try container.decode(String.self, forKey: .filename)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        kind = try container.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .screenshot
        hasAnnotations = try container.decodeIfPresent(Bool.self, forKey: .hasAnnotations) ?? false
        beautifiedPath = try container.decodeIfPresent(String.self, forKey: .beautifiedPath)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceWindowTitle = try container.decodeIfPresent(String.self, forKey: .sourceWindowTitle)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }
}

enum CaptureKind: String, Codable, Sendable {
    case screenshot
    case recording
}

/// Background configuration for the beautifier.
struct BeautifierConfig: Codable, Equatable {
    var style: BackgroundStyle = .none
    var padding: CGFloat = 0.08
    var cornerRadius: CGFloat = 0.018
    var shadowStrength: CGFloat = 0.36
    var alignment: ImageAlignment = .center
    var aspectRatio: CanvasAspectRatio = .auto

    static let `default` = BeautifierConfig()
}

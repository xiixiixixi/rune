import CoreGraphics

/// 显示器描述（自建轻量结构，不直接依赖 SCShareableContent 类型，
/// 使坐标换算等纯逻辑可在无屏幕权限环境下测试）。
public struct DisplayDescriptor: Equatable, Sendable {
    /// 显示器 ID（与 CGDirectDisplayID / SCDisplay 对应）
    public let id: CGDirectDisplayID
    /// 全局点坐标 frame（AppKit 约定：原点在左下角），单位：点
    public let frame: CGRect
    /// 背光缩放倍率（Retina = 2.0，普通屏 = 1.0）
    public let backingScaleFactor: CGFloat

    public init(id: CGDirectDisplayID, frame: CGRect, backingScaleFactor: CGFloat) {
        self.id = id
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
    }
}

/// 选区比例模式（Tab 轮换）
public enum AspectRatioMode: CaseIterable, Equatable, Sendable {
    case free
    case ratio1_1
    case ratio3_4
    case ratio16_9

    /// 轮换到下一个模式（自由 → 1:1 → 3:4 → 16:9 → 自由）
    public var next: AspectRatioMode {
        switch self {
        case .free: .ratio1_1
        case .ratio1_1: .ratio3_4
        case .ratio3_4: .ratio16_9
        case .ratio16_9: .free
        }
    }

    /// 3:4 / 16:9 模式下的宽高比（自由模式下为 nil）
    public var ratio: (width: CGFloat, height: CGFloat)? {
        switch self {
        case .free: nil
        case .ratio1_1: (1, 1)
        case .ratio3_4: (3, 4)
        case .ratio16_9: (16, 9)
        }
    }
}

/// 截图流程错误（失败后状态机复位到 idle）
public enum CaptureError: Error, Equatable, Sendable {
    /// 用户取消（Esc 等）
    case canceled
    /// 选区/预热超时
    case timeout
    /// 屏幕录制权限被拒绝
    case permissionDenied
    /// 底层截图失败（SCK 返回错误等）
    case captureFailed
}

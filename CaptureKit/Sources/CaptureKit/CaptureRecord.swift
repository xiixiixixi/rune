import CoreGraphics
import Foundation

/// 一次截图的完整结果（在内存中传递，文件地址只是导出后的产物）。
///
/// 命名说明：本类型是"内存中的单帧图像产物"。主应用里另有一个同名同职责不同的
/// `CaptureRecord`（历史记录的文件元数据，被几十处引用）。为避免主应用接入本包时
/// 发生顶层命名冲突，本包改用 `CapturedFrame` 这个名字。
///
/// 设计依据：M1 设计文档 §3.2 —— 截图完成后在内存中传递像素，
/// 避免"先写临时文件、再读回内存、再处理"的重复工作；
/// Retina 像素倍率在此有明确归属，保存 PNG 时默认保留原始物理像素。
public struct CapturedFrame: Sendable {
    /// 物理像素图像（Retina 屏上为 2x 像素，非点尺寸）
    public let image: CGImage
    /// 来源屏幕的背光缩放倍率（backingScaleFactor），导出时决定输出分辨率
    public let scaleFactor: CGFloat
    /// 来源显示器 ID（多屏工作流用；非屏幕截图时为 nil）
    public let displayID: CGDirectDisplayID?
    /// 截图时刻
    public let capturedAt: Date

    public init(image: CGImage, scaleFactor: CGFloat, displayID: CGDirectDisplayID?, capturedAt: Date = Date()) {
        self.image = image
        self.scaleFactor = scaleFactor
        self.displayID = displayID
        self.capturedAt = capturedAt
    }
}

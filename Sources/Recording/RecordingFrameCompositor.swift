@preconcurrency import CoreImage
import CoreMedia
import Foundation

/// 把叠加层画到屏幕帧上（画中画 + 鼠标点击高亮）。
///
/// 用 Core Image 一次完成「拷贝 + 叠加」：既不用手写逐行 memcpy，
/// 也不用在位图上下文里纠结坐标系上下翻转（位图上下文和 Core Image 的原点方向
/// 相反，是这类合成最容易出错的地方）。
/// CIImage 从像素缓冲读进来时方向已经是对的，直接 `composited(over:)` 即可。
///
/// **没有任何叠加内容时原样返回屏幕帧**：不开摄像头、不点鼠标的录制完全不产生额外开销。
final class RecordingFrameCompositor: @unchecked Sendable {

    /// 画中画小窗在画面里的位置与大小。
    struct Layout {
        /// 距离边缘的内缩（像素）
        var inset: CGFloat = 56
        /// 小窗宽度占画面宽度的比例
        var widthRatio: CGFloat = 0.22
        /// 小窗高度占画面宽度的比例（按宽度算，保证 4:3 左右的比例）
        var heightRatio: CGFloat = 0.165
        /// 圆角
        var cornerRadius: CGFloat = 18
    }

    /// 一个点击高亮圈。
    struct ClickMark {
        /// 画面像素坐标（左上原点）
        let point: CGPoint
        /// 点击后已经过去多久（秒）
        let age: TimeInterval
    }

    private let layout: Layout
    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()

    init(layout: Layout = Layout()) {
        self.layout = layout
        // workingColorSpace / outputColorSpace 传 NSNull = 不做色彩空间转换，
        // 屏幕原本是什么颜色就录成什么颜色。
        self.ciContext = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull()
        ])
    }

    /// 准备一块与画面同尺寸的像素缓冲池（开机时调用一次）。
    func prepare(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil,
            nil,
            attributes as CFDictionary,
            &newPool
        )
        pool = newPool
    }

    /// 合成一帧。
    /// - Parameters:
    ///   - screen: 屏幕帧
    ///   - camera: 摄像头帧；nil 表示这一帧没有摄像头画面
    ///   - clicks: 点击高亮圈；空数组表示没有
    ///   - cameraRotation: 摄像头画面需要旋转的角度（度）
    /// - Returns: 合成后的帧；失败时退回原屏幕帧，绝不因为叠加层把录屏搞挂。
    func render(
        screen: CVPixelBuffer,
        camera: CVPixelBuffer?,
        clicks: [ClickMark] = [],
        cameraRotation: CGFloat = 0
    ) -> CVPixelBuffer {
        guard camera != nil || !clicks.isEmpty else { return screen }

        lock.lock()
        let currentPool = pool
        lock.unlock()
        guard let currentPool else { return screen }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, currentPool, &output) == kCVReturnSuccess,
              let output else { return screen }

        let screenImage = CIImage(cvPixelBuffer: screen)
        let bounds = screenImage.extent
        guard bounds.width > 1, bounds.height > 1 else { return screen }

        var composite = screenImage
        if let camera {
            var cameraImage = CIImage(cvPixelBuffer: camera)

            // 旋转（绕中心）。摄像头传感器多半竖着装，不转会躺倒。
            if abs(cameraRotation) > 0.01 {
                let center = CGPoint(x: cameraImage.extent.midX, y: cameraImage.extent.midY)
                let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
                let back = CGAffineTransform(translationX: center.x, y: center.y)
                cameraImage = cameraImage
                    .transformed(by: toOrigin)
                    .transformed(by: CGAffineTransform(rotationAngle: cameraRotation))
                    .transformed(by: back)
            }

            let target = targetRect(in: bounds.size)
            composite = aspectFit(cameraImage, into: target).composited(over: composite)
        }

        ciContext.render(
            composite,
            to: output,
            bounds: CGRect(origin: .zero, size: bounds.size),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        if !clicks.isEmpty {
            drawClickMarks(clicks, in: output, width: Int(bounds.width), height: Int(bounds.height))
        }
        return output
    }

    /// 画中画小窗的矩形（Core Image 坐标系：原点在左下）。
    private func targetRect(in size: CGSize) -> CGRect {
        let width = size.width * layout.widthRatio
        let height = size.width * layout.heightRatio
        let inset = min(layout.inset, size.width * 0.06)
        return CGRect(
            x: size.width - width - inset,
            y: inset,
            width: width,
            height: height
        )
    }

    /// 等比缩放并居中到目标矩形。
    private func aspectFit(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let dx = rect.minX - scaledExtent.minX + (rect.width - scaledExtent.width) / 2
        let dy = rect.minY - scaledExtent.minY + (rect.height - scaledExtent.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    /// 画点击高亮圈：越点越淡、圈越滚越大，像系统自己的点击提示。
    private func drawClickMarks(_ marks: [ClickMark], in buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        for mark in marks {
            let age = max(0, mark.age)
            let alpha = max(0, 1 - age / 0.45) * 0.8
            guard alpha > 0.01 else { continue }
            let radius = 14 + age * 90
            // 位图原点在左上，位图上下文的原点在左下，这里翻一下。
            let centerX = CGFloat(mark.point.x)
            let centerY = CGFloat(height) - CGFloat(mark.point.y)
            let rect = CGRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha * 0.22))
            context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            context.setLineWidth(max(2, radius * 0.14))
            context.strokeEllipse(in: rect)
        }
    }
}

import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 录屏导出格式。飞书的录屏面板同样提供 MP4 / GIF 两种，GIF 直接进聊天。
enum VideoExportFormat: String, CaseIterable, Identifiable, Sendable {
    case mp4
    case gif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: "MP4"
        case .gif: "GIF"
        }
    }

    var fileExtension: String { rawValue }
}

/// 视频 → GIF 编码器（不引第三方库：ImageIO 自带 GIF 写出）。
///
/// 录屏 GIF 要的是"轻"：帧率压到 15fps、最长边 800px。更高会得到一个
/// 几十兆的文件，发到聊天里基本发不动。
enum GIFExporter {

    /// GIF 编码的默认参数
    enum Defaults {
        static let maxDimension: Int = 800
        static let frameRate: Int = 15
    }

    /// 把视频区间编码成 GIF。
    ///
    /// - Parameters:
    ///   - asset: 源视频
    ///   - outputURL: 目标 .gif 路径
    ///   - startTime: 起点（秒）
    ///   - endTime: 终点（秒）；nil = 到片尾
    ///   - maxDimension: 最长边像素上限
    ///   - frameRate: 抽帧帧率
    static func export(
        asset: AVAsset,
        to outputURL: URL,
        startTime: Double = 0,
        endTime: Double? = nil,
        maxDimension: Int = Defaults.maxDimension,
        frameRate: Int = Defaults.frameRate
    ) -> URL? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let assetDuration = CMTimeGetSeconds(asset.duration)
        guard assetDuration.isFinite, assetDuration > 0 else { return nil }
        let begin = max(0, min(startTime, assetDuration - 0.05))
        let finish = max(begin + 0.05, min(endTime ?? assetDuration, assetDuration))
        let span = finish - begin

        let firstTime = CMTime(seconds: begin, preferredTimescale: 600)
        guard let firstFrame = try? generator.copyCGImage(at: firstTime, actualTime: nil),
              firstFrame.width > 0, firstFrame.height > 0 else { return nil }

        // 等比缩到最长边上限
        let longest = max(firstFrame.width, firstFrame.height)
        let scale = min(1.0, Double(maxDimension) / Double(longest))
        let targetWidth = max(1, Int((Double(firstFrame.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(firstFrame.height) * scale).rounded()))

        let frameCount = max(1, Int((span * Double(frameRate)).rounded()))
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { return nil }

        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )

        let delay = 1.0 / Double(max(1, frameRate))
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]

        for index in 0..<frameCount {
            let seconds = begin + Double(index) / Double(max(1, frameRate))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil),
                  let scaled = resize(frame, width: targetWidth, height: targetHeight) else {
                continue
            }
            CGImageDestinationAddImage(destination, scaled, frameProperties as CFDictionary)
        }

        return CGImageDestinationFinalize(destination) ? outputURL : nil
    }

    /// 等比缩放单帧。
    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()
    }
}

/// AVAsset 不是 Sendable，但 GIF 编码过程只读它。包一层明确告知编译器。
final class GIFExportBox: @unchecked Sendable {
    let asset: AVAsset
    init(asset: AVAsset) { self.asset = asset }
}

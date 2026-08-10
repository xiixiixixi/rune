import AppKit
import Vision

/// OCR 识别结果（M3：文字与条码结构化分开）。
struct OCRResult {
    /// 识别到的文字（多行用 \n 连接）；无文字时为 nil。
    let text: String?
    /// 识别到的条码内容（QR/条码的 payload）；无条码时为空数组。
    let barcodes: [String]

    /// 合并为单个字符串（条码在前，文字在后，保持历史行为）。
    var combinedText: String {
        var parts: [String] = []
        parts.append(contentsOf: barcodes.filter { !$0.isEmpty })
        if let text, !text.isEmpty { parts.append(text) }
        return parts.joined(separator: "\n")
    }

    var isEmpty: Bool { combinedText.isEmpty }
}

/// 单条文字识别结果（含位置，供 PII 打码用）。boundingBox 是 Vision 归一化坐标（原点左下，0-1）。
struct OCRTextObservation {
    let text: String
    let boundingBox: CGRect
}

/// M3 离线 OCR 服务（基于 Apple Vision，纯本地，无网络）。
///
/// 设计依据：总纲 M3 —— `VNRecognizeTextRequest`（macOS 13+ 全语言），
/// 显式设中英文识别语言，解决旧代码靠系统默认可能漏中文的问题。
/// 隐私：完全本地执行，不上传任何内容（总纲红线：OCR 本地、默认零网络）。
@MainActor
final class OCRService {
    static let shared = OCRService()
    private init() {}

    /// 识别一张图片中的文字和条码。
    /// - Parameter image: 要识别的 CGImage（由调用方截图后提供，本服务不关心截图方式）
    /// - Returns: OCRResult（文字 + 条码）
    func recognize(in image: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            // 文字识别：显式设中英文（zh-Hans 简体中文 + en-US 英文）
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            // 先中文后英文：符合主要用户群（中文界面），中文优先匹配
            // 注意：需确认系统支持这些语言，否则 Vision 会抛错。用 try? 安全降级。
            let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: VNRecognizeTextRequestRevision3)) ?? []
            let desired = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            if !desired.isEmpty {
                textRequest.recognitionLanguages = desired
            }

            // 条码识别：QR + 各类条码
            let barcodeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([textRequest, barcodeRequest])

                // 条码结果
                var barcodes: [String] = []
                if let barcodeResults = barcodeRequest.results {
                    for barcode in barcodeResults {
                        if let payload = barcode.payloadStringValue, !payload.isEmpty {
                            barcodes.append(payload)
                        }
                    }
                }

                // 文字结果
                var text: String? = nil
                if let textResults = textRequest.results {
                    let joined = textResults
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    if !joined.isEmpty { text = joined }
                }

                continuation.resume(returning: OCRResult(text: text, barcodes: barcodes))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 识别文字并返回每条文字的内容+位置（供 PII 打码定位用）。
    /// 不含条码（PII 打码只关心文字）。
    func recognizeWithPositions(in image: CGImage) async throws -> [OCRTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: VNRecognizeTextRequestRevision3)) ?? []
            let desired = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            if !desired.isEmpty { textRequest.recognitionLanguages = desired }

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([textRequest])
                let observations = (textRequest.results ?? []).compactMap { obs -> OCRTextObservation? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return OCRTextObservation(text: candidate.string, boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: observations)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

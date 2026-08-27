import AppKit
@preconcurrency import Vision

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

/// 一次截图里可以继续使用的内容。图片仍然保留，但它不再是唯一结果。
struct CaptureContentAnalysis {
    let observations: [OCRTextObservation]
    let barcodes: [String]
    let sensitiveMatches: [PIIRedactor.PIIMatch]
    let links: [URL]

    init(observations: [OCRTextObservation], barcodes: [String]) {
        self.observations = observations
        self.barcodes = Self.unique(barcodes.filter { !$0.isEmpty })
        self.sensitiveMatches = PIIRedactor.detect(in: observations)
        self.links = Self.detectLinks(
            in: observations.map(\.text).joined(separator: "\n"),
            barcodes: self.barcodes
        )
    }

    var text: String? {
        let value = observations.map(\.text).joined(separator: "\n")
        return value.isEmpty ? nil : value
    }

    var textBlockCount: Int { observations.count }

    var nonLinkBarcodes: [String] {
        barcodes.filter { barcode in
            !links.contains { $0.absoluteString == barcode }
        }
    }

    var isEmpty: Bool {
        observations.isEmpty && barcodes.isEmpty
    }

    private static func detectLinks(in text: String, barcodes: [String]) -> [URL] {
        var values: [URL] = barcodes.compactMap(httpURL(from:))

        if !text.isEmpty,
           let detector = try? NSDataDetector(
               types: NSTextCheckingResult.CheckingType.link.rawValue
           ) {
            let range = NSRange(text.startIndex..., in: text)
            detector.enumerateMatches(in: text, range: range) { result, _, _ in
                guard let url = result?.url,
                      let safeURL = httpURL(from: url.absoluteString) else { return }
                values.append(safeURL)
            }
        }

        var seen = Set<String>()
        return values.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func httpURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum CaptureContentAnalysisState {
    case analyzing
    case ready(CaptureContentAnalysis)
    case empty
    case failed
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
        let analysis = try await analyzeCapture(in: image)
        return OCRResult(text: analysis.text, barcodes: analysis.barcodes)
    }

    /// 截图确认台的统一内容分析：一次 Vision 请求同时拿到文字位置与二维码。
    /// 这样“复制全部文字、选取局部文字、打开链接、一键打码”可以共用同一份本地结果。
    func analyzeCapture(in image: CGImage) async throws -> CaptureContentAnalysis {
        try await withCheckedThrowingContinuation { continuation in
            // Vision 是同步重活；放到后台，确认台仍可立即保存、复制或取消。
            DispatchQueue.global(qos: .userInitiated).async {
                // 文字识别：显式设中英文（zh-Hans 简体中文 + en-US 英文）
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                textRequest.usesLanguageCorrection = true
                // 先中文后英文：符合主要用户群（中文界面），中文优先匹配
                // 注意：需确认系统支持这些语言，否则 Vision 会抛错。用 try? 安全降级。
                let supported = (try? textRequest.supportedRecognitionLanguages()) ?? []
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

                    // 文字与位置一起保留。确认台后面的取字、链接和隐私动作都复用它。
                    let observations = (textRequest.results ?? []).compactMap { result -> OCRTextObservation? in
                        guard let candidate = result.topCandidates(1).first else { return nil }
                        return OCRTextObservation(
                            text: candidate.string,
                            boundingBox: result.boundingBox
                        )
                    }

                    continuation.resume(
                        returning: CaptureContentAnalysis(
                            observations: observations,
                            barcodes: barcodes
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 识别文字并返回每条文字的内容+位置（供 PII 打码定位用）。
    /// 与确认台共用统一分析管线，调用方只取其中的文字位置。
    func recognizeWithPositions(in image: CGImage) async throws -> [OCRTextObservation] {
        try await analyzeCapture(in: image).observations
    }

    /// 使用 Apple Vision 在本机检测人脸，返回归一化位置供隐私打码。
    func detectFaces(in image: CGImage) async throws -> [CGRect] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                do {
                    try handler.perform([request])
                    continuation.resume(
                        returning: (request.results ?? []).map(\.boundingBox)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

import Foundation
import CoreGraphics

/// PII（个人身份信息）自动打码服务（P1）。
///
/// 用途：截图后自动识别手机号/邮箱/身份证号，返回这些敏感信息的位置（归一化坐标），
/// 调用方（EditorModel）在这些位置加 blur 标注，实现"一键脱敏"。
///
/// 工作流：OCR 识别文字+位置 → 正则匹配 PII → 返回匹配项的 boundingBox。
/// 隐私：完全本地处理（OCR 本地 + 正则本地），不上传任何内容。
enum PIIRedactor {
    /// 中国手机号：1 开头 11 位
    static let phonePattern = #"(?<!\d)1[3-9]\d{9}(?!\d)"#
    /// 邮箱
    static let emailPattern = #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
    /// 中国身份证号（18 位，末位可能是 X）
    static let idCardPattern = #"(?<!\d)\d{17}[\dXx](?!\d)"#

    /// PII 匹配类型
    enum PIIType: String {
        case phone = "手机号"
        case email = "邮箱"
        case idCard = "身份证号"
    }

    /// 一处 PII 匹配结果（含类型和位置）。
    struct PIIMatch {
        let type: PIIType
        /// 在图中的归一化位置（Vision 坐标，原点左下，0-1），调用方需按需转换。
        let boundingBox: CGRect
    }

    /// 在 OCR 观察结果里找 PII，返回匹配项。
    /// - Parameter observations: OCR 识别的文字+位置（来自 OCRService.recognizeWithPositions）
    /// - Returns: 找到的 PII 匹配（手机号/邮箱/身份证号及其位置）
    static func detect(in observations: [OCRTextObservation]) -> [PIIMatch] {
        let patterns: [(PIIType, String)] = [
            (.phone, phonePattern),
            (.email, emailPattern),
            (.idCard, idCardPattern),
        ]

        var matches: [PIIMatch] = []
        for obs in observations {
            for (type, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(obs.text.startIndex..., in: obs.text)
                regex.enumerateMatches(in: obs.text, range: range) { result, _, _ in
                    guard result != nil else { return }
                    // 用匹配子串在行内的相对位置，结合该行的 boundingBox，估算 PII 的位置。
                    // 简化处理：PII 在行内，用行的 boundingBox 作为打码区域（保守覆盖整行）。
                    // 更精确的定位需要字符级 boundingBox（VNRecognizedText 的 boundingBox 行级已够用）。
                    matches.append(PIIMatch(type: type, boundingBox: obs.boundingBox))
                }
            }
        }
        return matches
    }
}

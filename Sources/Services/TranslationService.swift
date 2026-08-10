import Foundation

/// OCR 翻译服务（参考 macshot TranslationService 的 Google 路径算法，独立精简实现）。
///
/// 用谷歌翻译免费端点（translate.googleapis.com/translate_a/single），不需要 API key。
/// 隐私说明：翻译时会把识别到的文字发到谷歌服务器——这是翻译的本质需求，
/// 但只发 OCR 识别出的文字（不发原图），且用户主动触发（默认不联网）。
enum TranslationService {

    /// 常用目标语言（和 macshot 一致，覆盖主要语种）
    static let availableLanguages: [(code: String, name: String)] = [
        ("zh-CN", "中文(简体)"), ("zh-TW", "中文(繁体)"), ("en", "英文"),
        ("ja", "日文"), ("ko", "韩文"), ("fr", "法文"), ("de", "德文"),
        ("es", "西班牙文"), ("ru", "俄文"), ("ar", "阿拉伯文"),
        ("it", "意大利文"), ("pt", "葡萄牙文"), ("th", "泰文"), ("vi", "越南文"),
    ]

    /// 默认目标语言（中文简体——符合主要用户群）
    static var targetLanguage: String {
        get { UserDefaults.standard.string(forKey: "bs_translateTargetLang") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "bs_translateTargetLang") }
    }

    /// 翻译一段文字（自动检测源语言）。
    /// - Parameters:
    ///   - text: 要翻译的文字
    ///   - targetLang: 目标语言代码（如 "zh-CN"、"en"）
    /// - Returns: 翻译结果
    static func translate(_ text: String, to targetLang: String? = nil) async throws -> String {
        let lang = targetLang ?? targetLanguage
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // 参考 macshot translateOneGoogle：构造谷歌免费翻译端点 URL
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),      // 自动检测源语言
            URLQueryItem(name: "tl", value: lang),         // 目标语言
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: trimmed),       // 要翻译的文字
        ]
        guard let url = components.url else { throw TranslationError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranslationError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // 谷歌返回的 JSON 结构：[[["译文","原文",...],...], ...]
        // macshot 的解析：json.first as? [[Any]]，取每段 .first as? String 拼接
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = json.first as? [[Any]] else {
            throw TranslationError.parseError
        }
        let translated = segments.compactMap { $0.first as? String }.joined()
        guard !translated.isEmpty else { throw TranslationError.emptyResult }
        return translated
    }
}

enum TranslationError: LocalizedError {
    case badURL, httpError(Int), parseError, emptyResult
    var errorDescription: String? {
        switch self {
        case .badURL: return "翻译 URL 无效"
        case .httpError(let code): return "翻译服务返回错误 \(code)"
        case .parseError: return "无法解析翻译结果"
        case .emptyResult: return "翻译结果为空"
        }
    }
}

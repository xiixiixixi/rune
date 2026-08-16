import AppKit
import CryptoKit

/// 图片上传服务（参考 macshot 的 ImgbbUploader + S3Uploader 算法，独立精简实现）。
///
/// 两种后端：
/// - imgbb：免费图床，base64 上传，拿链接分享（默认）
/// - S3：S3/R2/MinIO 兼容，手写 AWS Sig V4（无 AWS SDK），需自配云存储
///
/// 隐私：上传是用户主动触发，默认不联网。上传会把图片发到云端——这是上传的本质。
enum ImageUploader {
    struct UploadResult {
        let link: String
        let deleteURL: String?
    }

    enum UploadProvider: String {
        case imgbb = "imgbb"
        case s3 = "s3"
        static var current: UploadProvider {
            UploadProvider(rawValue: UserDefaults.standard.string(forKey: "bs_uploadProvider") ?? "") ?? .imgbb
        }
    }

    // MARK: - 入口

    /// 上传图片，自动按用户选的 provider 分派。
    static func upload(_ image: NSImage) async throws -> UploadResult {
        switch UploadProvider.current {
        case .imgbb: return try await uploadToImgbb(image)
        case .s3:    return try await uploadToS3(image)
        }
    }

    // MARK: - imgbb（参考 macshot ImgbbUploader：base64 + multipart）

    /// imgbb 免费 API key（参考 macshot 的默认 key）；用户可在设置里换自己的。
    private static var imgbbAPIKey: String {
        let custom = UserDefaults.standard.string(forKey: "bs_imgbbAPIKey") ?? ""
        return custom.isEmpty ? "c2c63d156c6baa11136a464dcd22a404" : custom
    }

    private static func uploadToImgbb(_ image: NSImage) async throws -> UploadResult {
        guard let pngData = image.pngData() else { throw UploadError.encodingFailed }
        let base64 = pngData.base64EncodedString()

        var request = URLRequest(url: URL(string: "https://api.imgbb.com/1/upload?key=\(imgbbAPIKey)")!)
        request.httpMethod = "POST"
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"\r\n\r\n".data(using: .utf8)!)
        body.append(base64.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UploadError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // 解析 imgbb 返回（参考 macshot：json.data.url + delete_url）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let url = dataDict["url"] as? String else {
            throw UploadError.parseError
        }
        return UploadResult(link: url, deleteURL: dataDict["delete_url"] as? String)
    }

    // MARK: - S3（参考 macshot S3Uploader：手写 AWS Signature V4，无 SDK）

    /// S3 配置（用户在设置里配自己的云存储）
    struct S3Config {
        let endpoint: String; let region: String; let bucket: String
        let accessKeyID: String; let secretAccessKey: String
        let publicURLBase: String; let pathPrefix: String
        var isValid: Bool { !endpoint.isEmpty && !bucket.isEmpty && !accessKeyID.isEmpty && !secretAccessKey.isEmpty }
        static var current: S3Config {
            let ud = UserDefaults.standard
            return S3Config(
                endpoint: ud.string(forKey: "bs_s3Endpoint") ?? "",
                region: ud.string(forKey: "bs_s3Region") ?? "auto",
                bucket: ud.string(forKey: "bs_s3Bucket") ?? "",
                accessKeyID: ud.string(forKey: "bs_s3AccessKeyID") ?? "",
                secretAccessKey: ud.string(forKey: "bs_s3SecretAccessKey") ?? "",
                publicURLBase: ud.string(forKey: "bs_s3PublicURLBase") ?? "",
                pathPrefix: ud.string(forKey: "bs_s3PathPrefix") ?? ""
            )
        }
    }

    private static func uploadToS3(_ image: NSImage) async throws -> UploadResult {
        let cfg = S3Config.current
        guard cfg.isValid else { throw UploadError.s3NotConfigured }
        guard let pngData = image.pngData() else { throw UploadError.encodingFailed }

        let endpointURL = URL(string: cfg.endpoint)
        guard let host = endpointURL?.host else { throw UploadError.invalidEndpoint }
        var prefix = cfg.pathPrefix
        if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
        let filename = "\(AppPreferences.generateFileName(ext: "png"))"
        let objectKey = "\(prefix)\(filename.replacingOccurrences(of: " ", with: "_"))"
        let encodedKey = objectKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectKey
        let scheme = endpointURL?.scheme ?? "https"
        let urlString = "\(scheme)://\(host)/\(cfg.bucket)/\(encodedKey)"
        guard let url = URL(string: urlString) else { throw UploadError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        signS3Request(&request, data: pngData, cfg: cfg)   // AWS Sig V4 签名

        let (_, response) = try await URLSession.shared.upload(for: request, from: pngData)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UploadError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let link = cfg.publicURLBase.isEmpty ? urlString : "\(cfg.publicURLBase)/\(encodedKey)"
        return UploadResult(link: link, deleteURL: nil)
    }

    /// AWS Signature V4 签名（参考 macshot S3Uploader.signRequest 算法）。
    private static func signS3Request(_ request: inout URLRequest, data: Data, cfg: S3Config) {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: Date())
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: Date())

        let payloadHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        let method = request.httpMethod ?? "PUT"
        let path = request.url?.path.isEmpty == false ? request.url!.path : "/"
        let signedHeaderNames = ["content-type", "host", "x-amz-content-sha256", "x-amz-date"]
        let canonicalHeaders = signedHeaderNames.map { "\($0):\(request.value(forHTTPHeaderField: $0) ?? "")" }.joined(separator: "\n") + "\n"
        let canonicalRequest = [method, path, "", canonicalHeaders, signedHeaderNames.joined(separator: ";"), payloadHash].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(cfg.region)/s3/aws4_request"
        let canonicalHash = SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined()
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(canonicalHash)"

        func hmac(_ key: Data, _ data: Data) -> Data {
            let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
            return Data(mac)
        }
        let kDate = hmac(Data("AWS4\(cfg.secretAccessKey)".utf8), Data(dateStamp.utf8))
        let kRegion = hmac(kDate, Data(cfg.region.utf8))
        let kService = hmac(kRegion, Data("s3".utf8))
        let kSigning = hmac(kService, Data("aws4_request".utf8))
        let signature = hmac(kSigning, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        request.setValue("AWS4-HMAC-SHA256 Credential=\(cfg.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaderNames.joined(separator: ";")), Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }
}

enum UploadError: LocalizedError {
    case encodingFailed, httpError(Int), parseError, s3NotConfigured, invalidEndpoint
    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "图片编码失败"
        case .httpError(let c): return "上传失败（HTTP \(c)）"
        case .parseError: return "无法解析上传响应"
        case .s3NotConfigured: return "S3 未配置——请在设置里填写云存储信息"
        case .invalidEndpoint: return "S3 端点地址无效"
        }
    }
}

// MARK: - NSImage pngData 便捷扩展

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

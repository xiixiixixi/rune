import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 把成品图打包成拖拽数据，供"从 Rune 直接拖到别的应用"。
///
/// 同时提供三种表示，因为接收方口味不同，少一种就会在某类目标里变成拖不进去：
/// - `public.png` / `public.tiff` 图像数据：聊天窗口、浏览器、邮件直接当图片收下
/// - `public.file-url` 文件：访达落盘、Markdown 编辑器插图、IDE 引用路径
///
/// 只给文件 URL 的话，拖进微信得到的是"文件"而不是内联图片（这正是此前
/// 预览卡的行为）；只给图像数据的话，拖进访达和 Typora 这类地方又没反应。
///
/// 两条出口共用同一份编码结果：AppKit 拖拽会话要 `NSPasteboardItem`
/// （`NSItemProvider` 并不 conform `NSPasteboardWriting`），
/// SwiftUI `.onDrag` 要 `NSItemProvider`。
enum ImageDragSource {
    /// 拖出用的临时文件暂存目录。
    /// 不能拖完就删——接收方可能异步读取文件，删早了会拿到空文件。
    private static var stagingDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RuneDragOut", isDirectory: true)
    }

    // MARK: - 出口

    /// AppKit 拖拽会话（确认台上 ⌥ 拖动）。
    static func pasteboardItem(for image: CGImage, suggestedName: String) -> NSPasteboardItem {
        makePasteboardItem(payload(for: image, suggestedName: suggestedName))
    }

    /// SwiftUI `.onDrag`（工具栏「复制」按钮）。图还没落过盘，顺带存一份供 file-url 用。
    static func itemProvider(for image: CGImage, suggestedName: String) -> NSItemProvider {
        makeItemProvider(payload(for: image, suggestedName: suggestedName))
    }

    /// SwiftUI `.onDrag`（结果预览卡）。图已经在磁盘上，直接复用那份文件，不再多落一次盘。
    static func itemProvider(for image: NSImage?, fileURL: URL?) -> NSItemProvider {
        let payload = Payload(
            png: image.flatMap(pngData(from:)),
            tiff: image?.tiffRepresentation,
            fileURL: fileURL,
            suggestedName: fileURL?.deletingPathExtension().lastPathComponent ?? "Rune"
        )
        return makeItemProvider(payload)
    }

    // MARK: - 数据准备

    private struct Payload {
        var png: Data?
        var tiff: Data?
        var fileURL: URL?
        var suggestedName: String
    }

    private static func payload(for image: CGImage, suggestedName: String) -> Payload {
        // 先把编码做完再注册：加载回调只捕获 Data/URL（Sendable），
        // 不把 CGImage 带进 @Sendable 闭包里。
        let png = pngData(from: image)
        return Payload(
            png: png,
            tiff: tiffData(from: image),
            fileURL: stageFile(pngData: png, name: suggestedName),
            suggestedName: suggestedName
        )
    }

    // MARK: - 组装

    private static func makePasteboardItem(_ payload: Payload) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let png = payload.png {
            item.setData(png, forType: .png)
        }
        if let tiff = payload.tiff {
            item.setData(tiff, forType: .tiff)
        }
        if let url = payload.fileURL {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        return item
    }

    private static func makeItemProvider(_ payload: Payload) -> NSItemProvider {
        let provider = NSItemProvider()

        if let png = payload.png {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(png, nil)
                return nil
            }
        }

        if let tiff = payload.tiff {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.tiff.identifier,
                visibility: .all
            ) { completion in
                completion(tiff, nil)
                return nil
            }
        }

        // 放在图像之后：让偏好图像的目标优先拿到图片数据，
        // 只有真正需要文件的（访达、Markdown 编辑器）才走这一路。
        if let url = payload.fileURL {
            provider.registerObject(url as NSURL, visibility: .all)
        }

        provider.suggestedName = payload.suggestedName
        return provider
    }

    // MARK: - 编码与暂存

    private static func pngData(from image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    private static func pngData(from image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return pngData(from: cgImage)
        }
        return image.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
    }

    private static func tiffData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:])
    }

    /// 落一份 PNG 供 file-url 表示用，并顺手清理一天前的旧文件。
    private static func stageFile(pngData: Data?, name: String) -> URL? {
        guard let pngData else { return nil }
        let directory = stagingDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneStaging(in: directory)

        let stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeStem = stem.isEmpty ? "Rune-\(Int(Date().timeIntervalSince1970 * 1000))" : stem
        let url = directory.appendingPathComponent("\(safeStem).png")
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func pruneStaging(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in urls {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

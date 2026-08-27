import Foundation
import AppKit
@preconcurrency import AVFoundation

/// Persists capture history as a JSON file in Application Support.
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var records: [CaptureRecord] = []
    private(set) var indexingRecordIDs: Set<UUID> = []
    private let storageDir: URL
    private let manifestURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newStorageDir = appSupport.appendingPathComponent("Rune", isDirectory: true)
        let oldStorageDir = appSupport.appendingPathComponent("BetterShot", isDirectory: true)
        // 首次使用“Rune”时复制旧版本历史，旧资料保留不删，避免改名后看不到以前的截图。
        if !FileManager.default.fileExists(atPath: newStorageDir.path),
           FileManager.default.fileExists(atPath: oldStorageDir.path) {
            try? FileManager.default.copyItem(at: oldStorageDir, to: newStorageDir)
        }
        storageDir = newStorageDir
        manifestURL = storageDir.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        migrateLegacyBaseFiles()
        loadRecords()
    }

    // MARK: - Import

    func importCapture(
        from tempURL: URL,
        deleteSource: Bool = true,
        kind: CaptureKind = .screenshot,
        source: CaptureSource? = nil
    ) async -> CaptureRecord? {
        let ext = tempURL.pathExtension.isEmpty ? "png" : tempURL.pathExtension
        // M2 自动命名保存：用 AppPreferences 生成器，冲突时加 _2/_3 后缀（比 UUID 更友好）。
        let baseName = AppPreferences.generateFileName(ext: ext)
        let (filename, destURL) = uniqueFilename(baseName: baseName, in: storageDir)

        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        } catch {
            print("导入截图失败：\(error)")
            return nil
        }

        var width = 0, height = 0
        if kind == .recording {
            let asset = AVURLAsset(url: destURL)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let naturalSize = try? await track.load(.naturalSize),
               let preferredTransform = try? await track.load(.preferredTransform) {
                let size = naturalSize.applying(preferredTransform)
                width = Int(abs(size.width))
                height = Int(abs(size.height))
            }
        } else if let source = CGImageSourceCreateWithURL(destURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }

        let record = CaptureRecord(
            filename: filename,
            pixelWidth: width,
            pixelHeight: height,
            kind: kind,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.applicationName,
            sourceWindowTitle: source?.windowTitle
        )
        records.insert(record, at: 0)
        saveRecords()

        if kind == .screenshot {
            Task { await indexSearchMetadata(for: record.id) }
        }

        if deleteSource {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return record
    }

    /// 生成不冲突的文件名：若 `baseName` 已存在，加 `_2`/`_3`... 后缀直到不冲突。
    /// 符合 Finder 复制习惯，比 UUID 更友好。
    private func uniqueFilename(baseName: String, in dir: URL) -> (String, URL) {
        let initialURL = dir.appendingPathComponent(baseName)
        if !FileManager.default.fileExists(atPath: initialURL.path) {
            return (baseName, initialURL)
        }
        let nsName = (baseName as NSString)
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension.isEmpty ? "" : "." + nsName.pathExtension
        for i in 2...1000 {
            let candidate = "\(stem)_\(i)\(ext)"
            let candidateURL = dir.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return (candidate, candidateURL)
            }
        }
        // 兜底（理论不会到这）：加 UUID
        let fallback = "\(stem)_\(UUID().uuidString.prefix(6))\(ext)"
        return (fallback, dir.appendingPathComponent(fallback))
    }

    // MARK: - Update

    func setBeautifiedPath(_ path: String, for recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].beautifiedPath = path
        saveRecords()
    }

    func setFavorite(_ isFavorite: Bool, for recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].isFavorite = isFavorite
        saveRecords()
    }

    func markUsed(_ recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].lastUsedAt = Date()
        records[index].useCount += 1
        saveRecords()
    }

    func rename(_ title: String?, recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index].title = trimmed?.isEmpty == false ? trimmed : nil
        saveRecords()
    }

    /// 把旧截图补齐为可搜索素材。重复调用是安全的：已有文字或正在识别的记录会跳过。
    func indexMissingSearchMetadata() {
        let ids = records
            .filter { $0.kind == .screenshot && $0.ocrText == nil }
            .map(\.id)

        Task {
            for id in ids {
                await indexSearchMetadata(for: id)
                await Task.yield()
            }
        }
    }

    func indexSearchMetadata(for recordID: UUID) async {
        guard !indexingRecordIDs.contains(recordID),
              let record = records.first(where: { $0.id == recordID }),
              record.kind == .screenshot,
              record.ocrText == nil else { return }

        indexingRecordIDs.insert(recordID)
        defer { indexingRecordIDs.remove(recordID) }

        let url = displayURLForRecord(record)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

        do {
            let result = try await OCRService.shared.recognize(in: image)
            guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
            // 空字符串表示已识别但没有文字，避免每次打开素材库都重复扫描。
            records[index].ocrText = result.combinedText
            saveRecords()
        } catch {
            print("素材库文字索引失败：\(record.filename)：\(error)")
        }
    }

    // MARK: - Access

    func urlForRecord(_ record: CaptureRecord) -> URL {
        storageDir.appendingPathComponent(record.filename)
    }

    func displayURLForRecord(_ record: CaptureRecord) -> URL {
        if let path = record.beautifiedPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return urlForRecord(record)
    }

    func thumbnail(for record: CaptureRecord, maxSize: CGFloat = 120) -> NSImage? {
        Self.renderThumbnail(
            at: displayURLForRecord(record),
            kind: record.kind,
            maxSize: maxSize
        )
    }

    /// 缩略图解码可以在后台完成，避免打开菜单或记录页时卡住界面。
    nonisolated static func renderThumbnail(
        at url: URL,
        kind: CaptureKind,
        maxSize: CGFloat = 120
    ) -> NSImage? {
        guard let image = renderThumbnailCGImage(at: url, kind: kind, maxSize: maxSize) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    /// 后台任务只传递不可变的 CGImage；到主线程后再包装成 NSImage。
    nonisolated static func renderThumbnailCGImage(
        at url: URL,
        kind: CaptureKind,
        maxSize: CGFloat = 120
    ) -> CGImage? {
        if kind == .recording {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Delete

    func deleteRecord(_ record: CaptureRecord) {
        let url = urlForRecord(record)
        guard moveToTrashIfPresent(url) else { return }
        if let beautifiedPath = record.beautifiedPath {
            let beautifiedURL = URL(fileURLWithPath: beautifiedPath)
            _ = moveToTrashIfPresent(beautifiedURL)
            let baseURL = CaptureOrchestrator.baseImageURL(for: beautifiedURL)
            _ = moveToTrashIfPresent(baseURL)
        }
        records.removeAll { $0.id == record.id }
        saveRecords()
    }

    func deleteAllRecords() {
        let snapshot = records
        for record in snapshot {
            deleteRecord(record)
        }
    }

    /// 删除历史记录时统一进入废纸篓，避免一次误点永久丢失截图或录屏。
    @discardableResult
    private func moveToTrashIfPresent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            print("移到废纸篓失败：\(url.lastPathComponent)：\(error)")
            return false
        }
    }

    // MARK: - Persistence

    private func migrateLegacyBaseFiles() {
        let baseDirectory = storageDir.appendingPathComponent("bases", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for oldURL in urls {
            let name = oldURL.lastPathComponent
            let lowercased = name.lowercased()
            guard lowercased.hasPrefix("bettershot_") || lowercased.hasPrefix("better-shot_") else {
                continue
            }

            let separatorIndex = name.firstIndex(of: "_")
            let suffix = separatorIndex.map { String(name[$0...]) }
                ?? "_\(UUID().uuidString).\((name as NSString).pathExtension)"
            let (_, newURL) = uniqueFilename(baseName: "rune\(suffix)", in: baseDirectory)
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                print("Rune 原图文件改名失败：\(name)：\(error)")
            }
        }
    }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        var decoded = (try? JSONDecoder().decode([CaptureRecord].self, from: data)) ?? []
        var didMigrateLegacyRecords = false

        for index in decoded.indices {
            let oldFilename = decoded[index].filename
            let lowercased = oldFilename.lowercased()
            if lowercased.hasPrefix("bettershot_") || lowercased.hasPrefix("better-shot_") {
                let separatorIndex = oldFilename.firstIndex(of: "_")
                let suffix = separatorIndex.map { String(oldFilename[$0...]) }
                    ?? "_\(decoded[index].id.uuidString).\((oldFilename as NSString).pathExtension)"
                let desiredFilename = "rune\(suffix)"
                let oldURL = storageDir.appendingPathComponent(oldFilename)
                let (newFilename, newURL) = uniqueFilename(baseName: desiredFilename, in: storageDir)

                do {
                    if FileManager.default.fileExists(atPath: oldURL.path) {
                        try FileManager.default.moveItem(at: oldURL, to: newURL)
                    }
                    decoded[index].filename = newFilename
                    didMigrateLegacyRecords = true
                } catch {
                    print("Rune 历史文件改名失败：\(oldFilename)：\(error)")
                }
            }

            guard let beautifiedPath = decoded[index].beautifiedPath else { continue }
            let oldBeautifiedURL = URL(fileURLWithPath: beautifiedPath)
            guard FileManager.default.fileExists(atPath: oldBeautifiedURL.path) else {
                decoded[index].beautifiedPath = nil
                didMigrateLegacyRecords = true
                continue
            }

            let beautifiedName = oldBeautifiedURL.lastPathComponent
            let beautifiedLowercased = beautifiedName.lowercased()
            guard beautifiedLowercased.hasPrefix("bettershot_")
                    || beautifiedLowercased.hasPrefix("better-shot_") else { continue }

            let separatorIndex = beautifiedName.firstIndex(of: "_")
            let suffix = separatorIndex.map { String(beautifiedName[$0...]) }
                ?? "_\(decoded[index].id.uuidString).\((beautifiedName as NSString).pathExtension)"
            let (_, newBeautifiedURL) = uniqueFilename(
                baseName: "rune\(suffix)",
                in: oldBeautifiedURL.deletingLastPathComponent()
            )

            do {
                let oldBaseURL = CaptureOrchestrator.baseImageURL(for: oldBeautifiedURL)
                try FileManager.default.moveItem(at: oldBeautifiedURL, to: newBeautifiedURL)
                if FileManager.default.fileExists(atPath: oldBaseURL.path) {
                    let newBaseURL = CaptureOrchestrator.baseImageURL(for: newBeautifiedURL)
                    try? FileManager.default.moveItem(at: oldBaseURL, to: newBaseURL)
                }
                decoded[index].beautifiedPath = newBeautifiedURL.path
                didMigrateLegacyRecords = true
            } catch {
                print("Rune 成品文件改名失败：\(beautifiedName)：\(error)")
            }
        }

        // Filter out records whose files no longer exist
        records = decoded.filter { FileManager.default.fileExists(atPath: urlForRecord($0).path) }
        if didMigrateLegacyRecords {
            saveRecords()
        }
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

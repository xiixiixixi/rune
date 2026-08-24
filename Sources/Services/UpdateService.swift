import AppKit
import Foundation

struct RuneUpdate: Equatable, Sendable {
    let version: String
    let notes: String
    let releasePageURL: URL
    let downloadURL: URL?

    var preferredURL: URL {
        downloadURL ?? releasePageURL
    }
}

enum RuneUpdateCheckResult: Equatable, Sendable {
    case upToDate(latestVersion: String)
    case updateAvailable(RuneUpdate)
}

enum RuneUpdateError: LocalizedError {
    case invalidResponse
    case unavailable
    case missingPackage
    case extractionFailed
    case packageRejected
    case devBuildNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无法识别的版本信息。"
        case .unavailable:
            return "暂时无法连接 Rune 的 GitHub Release。"
        case .missingPackage:
            return "这个版本没有自动更新包，请手动下载安装。"
        case .extractionFailed:
            return "更新包解压失败，请稍后再试。"
        case .packageRejected:
            return "更新包校验未通过，已中止安装。"
        case .devBuildNotSupported:
            return "当前运行的是开发版，请从应用程序文件夹启动 Rune 后再更新。"
        }
    }
}

enum UpdateService {
    /// 版本探测与更新包都走"不计 API 限额"的通道：
    /// - 版本：仓库 main 分支的 version.json（raw 直链，几 KB）
    /// - 更新包：latest release 的固定名资产 Rune-latest.zip（下载走 CDN）
    /// GitHub 匿名 API 每小时只有 60 次/共享 IP，实测常被挤占，不可用。
    private static let remoteVersionURL = URL(
        string: "https://raw.githubusercontent.com/xiixiixixi/rune/main/version.json"
    )!
    private static let latestDownloadURL = URL(
        string: "https://github.com/xiixiixixi/rune/releases/latest/download/Rune-latest.zip"
    )!
    private static let releasesPageURL = URL(
        string: "https://github.com/xiixiixixi/rune/releases/latest"
    )!

    static func check(currentVersion: String) async throws -> RuneUpdateCheckResult {
        var request = URLRequest(url: remoteVersionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("Rune/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw RuneUpdateError.unavailable
        }

        let remote = try JSONDecoder().decode(RemoteVersion.self, from: data)
        let latestVersion = normalizedVersion(remote.version)
        guard !latestVersion.isEmpty else {
            throw RuneUpdateError.invalidResponse
        }

        guard compareVersions(latestVersion, currentVersion) == .orderedDescending else {
            return .upToDate(latestVersion: latestVersion)
        }

        return .updateAvailable(
            RuneUpdate(
                version: latestVersion,
                notes: remote.notes ?? "",
                releasePageURL: releasesPageURL,
                downloadURL: latestDownloadURL
            )
        )
    }

    static func scheduleAutomaticCheckIfNeeded() {
        guard AppPreferences.automaticallyChecksForUpdates else { return }

        let now = Date()
        guard now.timeIntervalSince(AppPreferences.lastAutomaticUpdateCheck) >= 24 * 60 * 60 else {
            return
        }
        AppPreferences.lastAutomaticUpdateCheck = now

        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"

        Task {
            guard case let .updateAvailable(update) = try? await check(
                currentVersion: currentVersion
            ) else { return }
            await UpdateWindowController.shared.present(update, currentVersion: currentVersion)
        }
    }

    // MARK: - 下载

    /// 下载更新包到临时目录，返回 zip 文件 URL。progress 主线程回调 0…1。
    static func download(
        _ update: RuneUpdate,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard let url = update.downloadURL else {
            throw RuneUpdateError.missingPackage
        }
        let delegate = DownloadProgressDelegate(onProgress: progress)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: OperationQueue.main
        )
        defer { session.finishTasksAndInvalidate() }
        let (tmpURL, response) = try await session.download(from: url, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw RuneUpdateError.unavailable
        }
        return tmpURL
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: @MainActor (Double) -> Void

        init(onProgress: @escaping @MainActor (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            Task { @MainActor in
                self.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }

    // MARK: - 安装并重启

    /// 解压并校验更新包：必须确实是 Rune、版本比当前新。返回新版 app 的 URL。
    /// 体检（--audit-update-flow）也走这里，但不会执行后续的替换重启。
    static func extractAndValidate(zipURL: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", zipURL.path, staging.path]
        try extract.run()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw RuneUpdateError.extractionFailed
        }

        let newApp = staging.appendingPathComponent("Rune.app")
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        guard let plist = NSDictionary(
            contentsOf: newApp.appendingPathComponent("Contents/Info.plist")
        ), let bundleID = plist["CFBundleIdentifier"] as? String,
            bundleID == Bundle.main.bundleIdentifier,
            let newVersion = plist["CFBundleShortVersionString"] as? String,
            compareVersions(newVersion, currentVersion) == .orderedDescending else {
            try? FileManager.default.removeItem(at: staging)
            throw RuneUpdateError.packageRejected
        }
        return newApp
    }

    /// 解压校验后替换当前 app 并重启。必须从 /Applications（或用户安装位置）运行；
    /// .build 调试版拒绝自动安装。
    ///
    /// 替换由独立 shell 进程完成：等待本进程退出 → 挪走旧版 → 放入新版 →
    /// 重新启动 → 清理，全程无需用户操作。
    static func installAndRelaunch(zipURL: URL) throws {
        let appURL = Bundle.main.bundleURL
        guard !appURL.path.contains("/.build/") else {
            throw RuneUpdateError.devBuildNotSupported
        }

        let newApp = try extractAndValidate(zipURL: zipURL)
        let staging = newApp.deletingLastPathComponent()

        // 独立 shell 在本进程退出后完成替换与重启
        let backupURL = appURL.deletingLastPathComponent()
            .appendingPathComponent("Rune.app.old")
        let script = """
        sleep 1
        rm -rf "\(backupURL.path)"
        mv "\(appURL.path)" "\(backupURL.path)"
        mv "\(newApp.path)" "\(appURL.path)"
        open "\(appURL.path)"
        sleep 3
        rm -rf "\(backupURL.path)" "\(staging.path)" "\(zipURL.path)"
        """
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/sh")
        installer.arguments = ["-c", script]
        try installer.run()

        NSApp.terminate(nil)
    }

    #if DEBUG
    /// 无人值守体检（--audit-update-flow）：真实调用 GitHub API 检查更新、
    /// 真实下载 zip、真实解压校验；不执行替换重启。结果写
    /// /tmp/rune-update-flow-result.txt。
    static func runUpdateFlowSelfTest() {
        Task { @MainActor in
            func report(_ text: String) {
                try? text.write(toFile: "/tmp/rune-update-flow-result.txt", atomically: true, encoding: .utf8)
                print("[更新自测]\n" + text)
            }

            // 1. 检查更新（把当前版本说成 0.0.1，保证能发现"新版"）
            guard case let .updateAvailable(update) = try? await check(currentVersion: "0.0.1"),
                  let zipURL = update.downloadURL else {
                report("检查更新: FAIL ❌（latest 无 zip 更新包或接口异常）")
                return
            }

            // 2. 下载（强制版本 99.0 绕过比较，全速走下载管道）
            let forced = RuneUpdate(
                version: "99.0",
                notes: "",
                releasePageURL: update.releasePageURL,
                downloadURL: zipURL
            )
            do {
                let localZip = try await download(forced) { _ in }
                // 3. 解压 + 校验（dry-run，不替换）
                let newApp = try extractAndValidate(zipURL: localZip)
                let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
                let newVersion = plist?["CFBundleShortVersionString"] as? String ?? "?"
                try? FileManager.default.removeItem(at: localZip)
                try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent())
                report("""
                检查更新: PASS ✅ 发现 \(update.version)
                下载: PASS ✅
                解压校验: PASS ✅ 包内版本 \(newVersion)
                """)
            } catch {
                report("下载/解压: FAIL ❌ \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
    #endif

    // MARK: - 版本工具

    private static func normalizedVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalizedVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let right = normalizedVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// 远端 version.json 的结构（发版时随仓库提交，含更新说明）。
private struct RemoteVersion: Decodable, Sendable {
    let version: String
    let build: Int?
    let notes: String?
}

import AppKit
import Foundation

struct RuneUpdate: Equatable, Sendable {
    let version: String
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无法识别的版本信息。"
        case .unavailable:
            return "暂时无法连接 Rune 的 GitHub Release。"
        }
    }
}

enum UpdateService {
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/xiixiixixi/rune/releases/latest"
    )!

    static func check(currentVersion: String) async throws -> RuneUpdateCheckResult {
        var request = URLRequest(url: latestReleaseAPI)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Rune/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuneUpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RuneUpdateError.unavailable
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latestVersion = normalizedVersion(release.tagName)
        guard !latestVersion.isEmpty,
              let releasePageURL = URL(string: release.htmlURL) else {
            throw RuneUpdateError.invalidResponse
        }

        let comparison = compareVersions(latestVersion, currentVersion)
        guard comparison == .orderedDescending else {
            let displayedVersion = comparison == .orderedAscending
                ? normalizedVersion(currentVersion)
                : latestVersion
            return .upToDate(latestVersion: displayedVersion)
        }

        let downloadURL = release.assets
            .first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadURL) }
        return .updateAvailable(
            RuneUpdate(
                version: latestVersion,
                releasePageURL: releasePageURL,
                downloadURL: downloadURL
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
            await presentUpdateAlert(update, currentVersion: currentVersion)
        }
    }

    @MainActor
    private static func presentUpdateAlert(_ update: RuneUpdate, currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Rune \(update.version) 可以更新"
        alert.informativeText = "你正在使用 \(currentVersion)。下载后打开安装包，把新版 Rune 拖进 Applications 即可覆盖旧版。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "以后再说")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.preferredURL)
        }
    }

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

private struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

import AppKit
import CoreGraphics

@MainActor
@Observable
final class ScreenCapture {
    static let shared = ScreenCapture()

    private(set) var isCapturing = false

    private init() {}

    // MARK: - Fullscreen 

    func captureFullscreen() async throws -> URL? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        try? await Task.sleep(for: .milliseconds(200))

        let tempPath = makeTempPath()
        let success = await runScreencapture(["-x", "-t", "png", tempPath])
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Region

    func captureRegion() async throws -> URL? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let tempPath = makeTempPath()
        let success = await runScreencapture(["-s", "-x", "-t", "png", tempPath])
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Window (CLI screencapture -w)

    func captureWindow(includeShadow: Bool = false) async throws -> URL? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let tempPath = makeTempPath()
        var args = ["-w"]
        if !includeShadow { args.append("-o") }
        args.append(contentsOf: ["-x", "-t", "png", tempPath])

        let success = await runScreencapture(args)
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Sound

    func playShutterSound() {
        guard AppPreferences.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        let url = URL(fileURLWithPath: path)
        if let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Helpers

    private func makeTempPath() -> String {
        let dir = NSTemporaryDirectory()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return "\(dir)bettershot_\(stamp).png"
    }

    private func runScreencapture(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

/// 单帧截图的稳定门面。
///
/// M1 的 ScreenCaptureKit 实现将作为 `StillCaptureBackend` 注入：优先走
/// SCScreenshotManager，必要时在 backend 内部选择瞬态 UI 的兜底路径。
/// 这层不引用 ScreenCaptureKit，因而可由纯 Swift 测试替身覆盖。
public protocol StillCaptureBackend: CaptureEngine {}

public struct StillCapture<Backend: StillCaptureBackend>: CaptureEngine {
    private let backend: Backend

    public init(backend: Backend) {
        self.backend = backend
    }

    public func prewarm() async throws {
        try await backend.prewarm()
    }

    public func capture(_ target: CaptureTarget) async throws -> CapturedFrame {
        try await backend.capture(target)
    }
}

import CoreGraphics

/// 截图目标。区域使用全局 AppKit 点坐标；具体引擎负责将其换算到各显示器的物理像素。
public enum CaptureTarget: Equatable, Sendable {
    case fullscreen
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(CGRect)
}

/// 对截图引擎的最小门面协议。
///
/// CaptureKit 的 UI、状态机和调用方只依赖此协议；ScreenCaptureKit 的
/// `SCShareableContent`、`SCContentFilter` 等实现细节留在实际引擎中，避免泄漏到 Editor。
public protocol CaptureEngine: Sendable {
    /// 预取可共享内容与截图所需缓存。热键触发后应尽早调用以缩短冻结画面的延迟。
    func prewarm() async throws

    /// 捕获一个目标并返回内存中的原始物理像素。
    func capture(_ target: CaptureTarget) async throws -> CapturedFrame
}

public extension CaptureEngine {
    /// 不需要预热的实现可采用默认空操作。
    func prewarm() async throws {}
}

/// 将 UI 事件与采集引擎串接的轻量协调器。
///
/// 选区的拖拽和绘制仍属于 AppKit overlay；本类型只拥有流程状态和实际采集调用，
/// 从而让 Esc、权限分支与成功/失败收口到同一个状态机。
public actor CaptureFlow<Engine: CaptureEngine> {
    private let engine: Engine
    private var machine = CaptureStateMachine()

    public init(engine: Engine) {
        self.engine = engine
    }

    public var state: CaptureState { machine.state }
    public var aspectRatioMode: AspectRatioMode { machine.aspectRatioMode }

    /// 从热键入口启动流程；无权限时只进入引导态，不访问采集 API。
    public func begin(hasPermission: Bool) {
        machine.reduce(.hotkeyTriggered(hasPermission: hasPermission))
    }

    /// 在权限已授予后预热引擎。调用方随后可显示选区 overlay。
    public func prewarm() async {
        guard machine.state == .prewarming else { return }
        do {
            try await engine.prewarm()
            machine.reduce(.selectionBegan)
        } catch {
            machine.reduce(.captureFailure)
        }
    }

    /// 在用户确认目标后进行采集；无论成功或失败，状态都可由调用方读取后 reset。
    public func capture(_ target: CaptureTarget) async -> CapturedFrame? {
        guard machine.state == .selecting || machine.state == .adjusting else { return nil }
        machine.reduce(.confirm)
        do {
            let frame = try await engine.capture(target)
            machine.reduce(.captureSuccess)
            return frame
        } catch {
            machine.reduce(.captureFailure)
            return nil
        }
    }

    public func handle(_ event: CaptureEvent) {
        machine.reduce(event)
    }

    public func reset() {
        machine.reset()
    }
}

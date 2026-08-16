import Foundation

/// 截图流程状态（单向流转，纯数据、无 UI 依赖，可独立测试）。
///
/// 设计依据：M1 设计文档 §3.4 ——
/// `空闲 → 预热 → 选择区域 → 调整区域 → 确认 → 截图中 → 完成或失败`
/// 扩展：`空闲` 触发热键时若未获得屏幕录制权限，先进入 `permissionRequired` 引导，
/// 授权后才预热；每个状态都能响应取消；失败后复位回 `idle`。
public enum CaptureState: Equatable, Sendable {
    case idle
    /// 首次触发但未获得屏幕录制权限（显示引导，不假装成功）
    case permissionRequired
    /// SCK 缓存预取 + 瞬态 UI（菜单栏等）兜底捕获
    case prewarming
    /// 拖拽选择区域（含比例模式轮换）
    case selecting
    /// 方向键微调 / 吸附调整
    case adjusting
    /// 执行截图
    case capturing
    /// 完成（调用方接管 CapturedFrame）
    case finished
    /// 失败（携带原因，随后复位回 idle）
    case failed(CaptureError)
}

/// 状态机输入事件
public enum CaptureEvent: Equatable, Sendable {
    /// 全局快捷键触发；携带是否已授权（未授权 → 引导态）
    case hotkeyTriggered(hasPermission: Bool)
    /// 用户在系统设置中授予屏幕录制权限后返回
    case permissionGranted
    /// 用户拒绝权限
    case permissionDenied
    /// 开始拖拽选区
    case selectionBegan
    /// 拖拽过程中选区变化
    case selectionChanged
    /// Tab：轮换选区比例模式
    case modeCycle
    /// 进入方向键微调
    case adjustBegan
    /// 确认选区（Enter / 点击）
    case confirm
    /// 取消（Esc，任何状态可用）
    case cancel
    /// 选区/预热超时
    case timeout
    /// 底层截图成功
    case captureSuccess
    /// 底层截图失败
    case captureFailure
}

/// 截图流程状态机（值类型 + 集中 reduce，纯函数可测）。
public struct CaptureStateMachine: Equatable, Sendable {
    public private(set) var state: CaptureState
    public private(set) var aspectRatioMode: AspectRatioMode

    public init() {
        self.state = .idle
        self.aspectRatioMode = .free
    }

    /// 处理事件；不匹配当前状态的事件被忽略（保持原状态）。
    public mutating func reduce(_ event: CaptureEvent) {
        switch (state, event) {

        // 空闲：热键触发，按权限分派
        case (.idle, .hotkeyTriggered(hasPermission: true)):
            state = .prewarming
        case (.idle, .hotkeyTriggered(hasPermission: false)):
            state = .permissionRequired

        // 权限引导
        case (.permissionRequired, .permissionGranted):
            state = .prewarming
        case (.permissionRequired, .permissionDenied):
            state = .idle
        case (.permissionRequired, .cancel):
            state = .idle

        // 预热完成 → 开始选择
        case (.prewarming, .selectionBegan):
            state = .selecting
        case (.prewarming, .captureFailure):
            state = .failed(.captureFailed)
        case (.prewarming, .cancel):
            state = .idle

        // 选择区域
        case (.selecting, .selectionChanged):
            break  // 选区数据由视图层持有，状态机只关心流程
        case (.selecting, .modeCycle):
            aspectRatioMode = aspectRatioMode.next
        case (.selecting, .adjustBegan):
            state = .adjusting
        case (.selecting, .confirm):
            state = .capturing
        case (.selecting, .cancel):
            state = .idle

        // 调整区域
        case (.adjusting, .modeCycle):
            aspectRatioMode = aspectRatioMode.next
        case (.adjusting, .selectionBegan):
            state = .selecting  // 重新拖选
        case (.adjusting, .confirm):
            state = .capturing
        case (.adjusting, .cancel):
            state = .idle

        // 截图中
        case (.capturing, .captureSuccess):
            state = .finished
        case (.capturing, .captureFailure):
            state = .failed(.captureFailed)
        case (.capturing, .cancel):
            state = .idle

        // 超时：选择/调整/预热/截图中都可能超时
        case (.prewarming, .timeout), (.selecting, .timeout), (.adjusting, .timeout), (.capturing, .timeout):
            state = .failed(.timeout)

        // 重复触发 / 无效事件：忽略
        default:
            break
        }
    }

    /// 显式复位（失败或完成后回到空闲；finished/failed 是终态，须由调用方复位）
    public mutating func reset() {
        state = .idle
        aspectRatioMode = .free
    }
}

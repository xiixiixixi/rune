import Testing
@testable import CaptureKit

/// 状态机测试：正常流程、权限分支、取消、超时、失败复位、重复触发、比例轮换、无效事件。
/// 依据 M1 设计文档 §3.4 与 §6 测试清单。
@Suite struct CaptureStateMachineTests {

    @Test func normalFlowReachesFinished() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        #expect(sm.state == .prewarming)
        sm.reduce(.selectionBegan)
        #expect(sm.state == .selecting)
        sm.reduce(.confirm)
        #expect(sm.state == .capturing)
        sm.reduce(.captureSuccess)
        #expect(sm.state == .finished)
    }

    @Test func permissionRequiredThenGranted() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: false))
        #expect(sm.state == .permissionRequired)
        sm.reduce(.permissionGranted)
        #expect(sm.state == .prewarming)
    }

    @Test func permissionDeniedReturnsToIdle() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: false))
        sm.reduce(.permissionDenied)
        #expect(sm.state == .idle)
    }

    @Test func cancelFromEveryStateReturnsToIdle() {
        // 每个可取消状态的完整前置路径（idle 只接受热键事件离开）
        let paths: [(name: String, events: [CaptureEvent])] = [
            ("permissionRequired", [.hotkeyTriggered(hasPermission: false)]),
            ("prewarming", [.hotkeyTriggered(hasPermission: true)]),
            ("selecting", [.hotkeyTriggered(hasPermission: true), .selectionBegan]),
            ("adjusting", [.hotkeyTriggered(hasPermission: true), .selectionBegan, .adjustBegan]),
            ("capturing", [.hotkeyTriggered(hasPermission: true), .selectionBegan, .confirm]),
        ]
        for path in paths {
            var sm = CaptureStateMachine()
            for event in path.events {
                sm.reduce(event)
            }
            #expect(sm.state != .idle, "前置路径应离开 idle: \(path.name)")
            sm.reduce(.cancel)
            #expect(sm.state == .idle, "\(path.name) 应可通过取消回到 idle")
        }
    }

    @Test func timeoutFailsAndResetReturnsToIdle() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        sm.reduce(.selectionBegan)
        sm.reduce(.timeout)
        #expect(sm.state == .failed(.timeout))
        // 失败是终态：事件被忽略
        sm.reduce(.cancel)
        #expect(sm.state == .failed(.timeout))
        sm.reset()
        #expect(sm.state == .idle)
        #expect(sm.aspectRatioMode == .free)
    }

    @Test func captureFailureAndReset() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        sm.reduce(.selectionBegan)
        sm.reduce(.confirm)
        sm.reduce(.captureFailure)
        #expect(sm.state == .failed(.captureFailed))
        sm.reset()
        #expect(sm.state == .idle)
    }

    @Test func repeatedHotkeyIsIgnoredWhileActive() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        sm.reduce(.selectionBegan)
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        #expect(sm.state == .selecting, "非 idle 时重复触发热键应被忽略")
    }

    @Test func aspectRatioModeCyclesOnTab() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        sm.reduce(.selectionBegan)
        #expect(sm.aspectRatioMode == .free)
        sm.reduce(.modeCycle)
        #expect(sm.aspectRatioMode == .ratio1_1)
        sm.reduce(.modeCycle)
        #expect(sm.aspectRatioMode == .ratio3_4)
        sm.reduce(.modeCycle)
        #expect(sm.aspectRatioMode == .ratio16_9)
        sm.reduce(.modeCycle)
        #expect(sm.aspectRatioMode == .free, "16:9 轮换后应回到自由模式")
    }

    @Test func adjustingFlow() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        sm.reduce(.selectionBegan)
        sm.reduce(.adjustBegan)
        #expect(sm.state == .adjusting)
        sm.reduce(.confirm)
        #expect(sm.state == .capturing)

        // 调整中重新拖选回到 selecting
        var sm2 = CaptureStateMachine()
        sm2.reduce(.hotkeyTriggered(hasPermission: true))
        sm2.reduce(.selectionBegan)
        sm2.reduce(.adjustBegan)
        sm2.reduce(.selectionBegan)
        #expect(sm2.state == .selecting)
    }

    @Test func invalidEventsAreIgnored() {
        var sm = CaptureStateMachine()
        sm.reduce(.confirm)           // idle 时确认无效
        #expect(sm.state == .idle)
        sm.reduce(.captureSuccess)    // idle 时截图成功无效
        #expect(sm.state == .idle)
        sm.reduce(.timeout)           // idle 时超时无效
        #expect(sm.state == .idle)
    }

    @Test func selectionChangedKeepsStateAndMode() {
        var sm = CaptureStateMachine()
        sm.reduce(.hotkeyTriggered(hasPermission: true))
        sm.reduce(.selectionBegan)
        sm.reduce(.modeCycle)
        sm.reduce(.selectionChanged)
        #expect(sm.state == .selecting)
        #expect(sm.aspectRatioMode == .ratio1_1, "选区变化不应重置比例模式")
    }
}

private actor TestCaptureBackend: StillCaptureBackend {
    private(set) var didPrewarm = false

    func prewarm() async throws {
        didPrewarm = true
    }

    func capture(_ target: CaptureTarget) async throws -> CapturedFrame {
        throw CaptureError.captureFailed
    }
}

@Suite struct CaptureFlowTests {
    @Test func permissionGatePreventsPrewarmUntilAuthorized() async {
        let backend = TestCaptureBackend()
        let flow = CaptureFlow(engine: StillCapture(backend: backend))

        await flow.begin(hasPermission: false)
        var state = await flow.state
        #expect(state == .permissionRequired)
        await flow.prewarm()
        var didPrewarm = await backend.didPrewarm
        #expect(didPrewarm == false)

        await flow.handle(.permissionGranted)
        await flow.prewarm()
        didPrewarm = await backend.didPrewarm
        state = await flow.state
        #expect(didPrewarm)
        #expect(state == .selecting)
    }

    @Test func backendFailureTransitionsToFailed() async {
        let flow = CaptureFlow(engine: StillCapture(backend: TestCaptureBackend()))
        await flow.begin(hasPermission: true)
        await flow.prewarm()

        let record = await flow.capture(.fullscreen)
        let state = await flow.state
        #expect(record == nil)
        #expect(state == .failed(.captureFailed))
    }
}

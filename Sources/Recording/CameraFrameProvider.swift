@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// 摄像头取帧（录屏画中画用）。
///
/// 飞书录屏面板有「摄像头」开关，开了之后录屏画面角落会出现一个摄像头小窗。
/// 系统自带的两条路都走不通：
/// - ScreenCaptureKit 的摄像头接口（`SCVideoEffectOutput` / `cameraEnabled`）只对
///   iOS 的应用内捕获开放，macOS 上不可用；
/// - 所以这里自己开一路 AVFoundation 摄像头会话，取最新帧交给合成器叠进画面。
///
/// 取不到设备（台式机 / Mac mini 没有内置摄像头）或用户没授权时，
/// `availability()` 会给出明确原因，界面据此把开关置灰——而不是让人点了才发现没反应。
final class CameraFrameProvider: NSObject, @unchecked Sendable {

    struct Availability {
        let hasDevice: Bool
        let isAuthorized: Bool
        let deviceName: String?
        /// 给界面看的说明：不可用时直接展示这句话。
        var reason: String? {
            if !hasDevice { return "此设备没有摄像头" }
            if !isAuthorized { return "尚未授权摄像头访问" }
            return nil
        }
        var isUsable: Bool { hasDevice && isAuthorized }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var latestRotation: CGFloat = 0
    private var isRunning = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// 已经取到的帧数（验收用：证明帧真的在流动）。
    private(set) var frameCount: Int = 0

    static func availability() -> Availability {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return Availability(
            hasDevice: !devices.isEmpty,
            isAuthorized: status == .authorized,
            deviceName: devices.first?.localizedName
        )
    }

    /// 请求摄像头权限。返回 false 表示没拿到权限。
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    var latestFrame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    var rotationAngle: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return latestRotation
    }

    /// 启动摄像头采集。失败会抛错，调用方负责降级（不录摄像头，但录屏继续）。
    func start() throws {
        lock.lock()
        let alreadyRunning = isRunning
        lock.unlock()
        guard !alreadyRunning else { return }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        guard let device = devices.first else {
            throw CameraFrameError.noDevice
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraFrameError.cannotAddInput
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.tc.rune.recording.camera"))
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraFrameError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        // 摄像头传感器多半是竖着装的，旋转协调器给出「水平拍摄」该用的角度。
        // 协调器本身会持续更新，不需要 start/stop。
        if #available(macOS 14.0, *) {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }

        session.startRunning()

        lock.lock()
        isRunning = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let running = isRunning
        isRunning = false
        latestBuffer = nil
        lock.unlock()
        guard running else { return }

        if #available(macOS 14.0, *) {
            rotationCoordinator = nil
        }
        if session.isRunning {
            session.stopRunning()
        }
    }

    enum CameraFrameError: LocalizedError {
        case noDevice
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noDevice: return "此设备没有摄像头"
            case .cannotAddInput: return "无法打开摄像头输入"
            case .cannotAddOutput: return "无法创建摄像头输出"
            }
        }
    }
}

// MARK: - 取帧

extension CameraFrameProvider: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 角度交给合成器去转（这里不去动 connection.videoRotationAngle）：
        // 画面旋转在合成阶段做，行为固定、可单独验证。
        var angle: CGFloat = 0
        if #available(macOS 14.0, *) {
            angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
        }

        lock.lock()
        latestBuffer = pixelBuffer
        latestRotation = angle
        frameCount += 1
        lock.unlock()
    }
}

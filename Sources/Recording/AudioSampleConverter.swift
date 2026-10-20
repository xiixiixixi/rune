@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// 把任意来源的 PCM 采样规范化成统一格式（48kHz / 双声道 / 交织 Float32）。
///
/// 为什么必须有这一步：
/// - 系统音频走 ScreenCaptureKit，格式由我们配置决定（固定 48kHz 双声道）；
/// - 麦克风走 ScreenCaptureKit 的麦克风通道，格式是**设备原生格式**——采样率、位深、
///   交织方式都不确定（文档原文：「based on the selected microphone capture device's
///   native format」）。
/// 同一个文件里两条音轨必须落到同一种格式，播放器混音与导出才成立。
///
/// 这里刻意「先量后转」：先读真实的 ASBD，再决定要不要转码，而不是假设某个格式。
/// 滚动截图那边的教训就是量纲不一致（拿 24 采样行向量去比 192 像素宽的行），
/// 那样写的代码单测能过、生产路径永远不触发。
enum AudioSampleConverter {

    /// 统一目标格式：48kHz / 双声道 / 交织 Float32。
    static let canonicalFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            preconditionFailure("无法创建 48kHz 双声道 Float32 格式")
        }
        return format
    }()

    /// AudioBufferList 在 Swift 里只暴露了第一个 AudioBuffer 成员，
    /// 多声道（尤其非交织）要按连续内存自己算出第 N 个缓冲在哪。
    @inline(__always)
    static func buffers(in listPointer: UnsafePointer<AudioBufferList>) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? MemoryLayout<UInt32>.size
        return UnsafeRawPointer(listPointer)
            .advanced(by: offset)
            .assumingMemoryBound(to: AudioBuffer.self)
    }

    /// 读取采样缓冲里真实的音频格式描述。
    static func sourceFormat(of sampleBuffer: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        return AVAudioFormat(streamDescription: pointer)
    }

    /// 把采样缓冲里的 PCM 数据拷进一个独立的 AVAudioPCMBuffer。
    ///
    /// ScreenCaptureKit 的采样缓冲底层是 IOSurface，内存由系统持有；
    /// 我们在转换期间需要把它拷进自己管理的缓冲，免得指针悬空。
    static func copyPCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return nil }
        let bufferCount = format.isInterleaved ? 1 : channelCount

        // AudioBufferList 只保证带 1 个 AudioBuffer 成员；多缓冲要自己按连续内存算。
        let listSize = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size * (bufferCount - 1)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)

        var needed = 0
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        guard Int(list.pointee.mNumberBuffers) >= bufferCount else { return nil }

        let sourceBuffers = buffers(in: UnsafePointer(list))
        let destinationBuffers = buffers(in: pcm.audioBufferList)
        let count = format.isInterleaved ? 1 : channelCount
        for index in 0..<count {
            let from = sourceBuffers[index]
            let to = destinationBuffers[index]
            guard let fromPointer = from.mData, let toPointer = to.mData else { return nil }
            let byteCount = min(Int(from.mDataByteSize), Int(to.mDataByteSize))
            guard byteCount > 0 else { return nil }
            memcpy(toPointer, fromPointer, byteCount)
        }
        return pcm
    }

    /// 把交织 Float32 的 PCM 数据打包成一个可直接喂给 AVAssetWriter 的采样缓冲。
    ///
    /// 数据会**复制**进 block buffer：AVAudioPCMBuffer 的内存归它自己，
    /// 采样缓冲必须能独立存活（写入器会晚于这一帧才真正编码）。
    static func makeSampleBuffer(
        from pcm: AVAudioPCMBuffer,
        format: AVAudioFormat,
        timestamp: CMTime
    ) -> CMSampleBuffer? {
        guard pcm.frameLength > 0,
              let channelData = pcm.floatChannelData?[0] else { return nil }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(pcm.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = CMBlockBufferReplaceDataBytes(
            with: channelData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard status == kCMBlockBufferNoErr else { return nil }

        var formatDescription: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: Int(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

/// 单路音频的规范化器。**每路音频各持有一个实例**：
/// AVAudioConverter 绑定了输入输出格式，且不是线程安全的；
/// 系统音频与麦克风分别跑在两条不同的回调队列上，不能共用一个。
final class AudioSampleNormalizer: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat = AudioSampleConverter.canonicalFormat) {
        self.targetFormat = targetFormat
    }

    /// 规范化一路音频。返回 nil 表示这帧无法处理（调用方记日志跳过，不中断录制）。
    func canonicalize(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = AudioSampleConverter.sourceFormat(of: sampleBuffer) else { return nil }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 已经是目标格式：原样透传，不做无谓的拷贝。
        if source.sampleRate == targetFormat.sampleRate,
           source.channelCount == targetFormat.channelCount,
           source.isInterleaved == targetFormat.isInterleaved,
           source.commonFormat == targetFormat.commonFormat {
            return sampleBuffer
        }

        lock.lock()
        if sourceFormat != source {
            sourceFormat = source
            converter = AVAudioConverter(from: source, to: targetFormat)
        }
        let activeConverter = converter
        lock.unlock()

        guard let activeConverter else { return nil }
        guard let inputPCM = AudioSampleConverter.copyPCMBuffer(from: sampleBuffer, format: source) else { return nil }

        let ratio = targetFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputPCM.frameLength) * ratio) + 64)
        guard let outputPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = activeConverter.convert(to: outputPCM, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputPCM
        }
        guard status != .error, conversionError == nil, outputPCM.frameLength > 0 else { return nil }

        return AudioSampleConverter.makeSampleBuffer(
            from: outputPCM,
            format: targetFormat,
            timestamp: timestamp
        )
    }
}

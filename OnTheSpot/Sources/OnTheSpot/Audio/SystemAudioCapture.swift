@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os

/// Captures system audio (other participants) via ScreenCaptureKit.
final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    private let _stream = OSAllocatedUnfairLock<SCStream?>(uncheckedState: nil)
    private let _continuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)

    func bufferStream() async throws -> AsyncStream<AVAudioPCMBuffer> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 16000

        // Minimal video — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        let audioStream = AsyncStream<AVAudioPCMBuffer> { cont in
            self._continuation.withLock { $0 = cont }

            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                Task {
                    try? await self._stream.withLock { $0 }?.stopCapture()
                    self._stream.withLock { $0 = nil }
                }
            }
        }

        _stream.withLock { $0 = scStream }
        try await scStream.startCapture()

        return audioStream
    }

    func stop() async {
        try? await _stream.withLock { $0 }?.stopCapture()
        _stream.withLock { $0 = nil }
        _continuation.withLock { $0?.finish(); $0 = nil }
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame
        ) else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = blockBuffer.dataLength
        let frameCount = AVAudioFrameCount(length) / AVAudioFrameCount(asbd.mBytesPerFrame)

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        try? blockBuffer.withUnsafeMutableBytes { rawPtr in
            guard let srcPtr = rawPtr.baseAddress else { return }
            memcpy(pcmBuffer.floatChannelData![0], srcPtr, length)
        }

        _ = _continuation.withLock { $0?.yield(pcmBuffer) }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("SystemAudioCapture: stream stopped with error: \(error)")
        _continuation.withLock { $0?.finish(); $0 = nil }
    }

    enum CaptureError: Error {
        case noDisplay
    }
}

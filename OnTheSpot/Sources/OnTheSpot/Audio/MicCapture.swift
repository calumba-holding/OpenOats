@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio via AVAudioEngine and streams PCM buffers.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    /// Set a specific input device by its AudioDeviceID. Pass nil to use system default.
    func setInputDevice(_ deviceID: AudioDeviceID?) {
        guard let id = deviceID else { return }
        let audioUnit = engine.inputNode.audioUnit!
        var deviceID = id
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    func bufferStream(deviceID: AudioDeviceID? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        let level = _audioLevel
        let errorHolder = _error

        return AsyncStream { continuation in
            // Set input device before accessing inputNode format
            if let id = deviceID {
                do {
                    let inputNode = self.engine.inputNode
                    let audioUnit = inputNode.audioUnit!
                    var devID = id
                    let status = AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &devID,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    if status != noErr {
                        print("MicCapture: failed to set input device (\(status))")
                    }
                }
            }

            let inputNode = self.engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            print("MicCapture: input format = \(format)")
            print("MicCapture: sample rate = \(format.sampleRate), channels = \(format.channelCount)")

            guard format.sampleRate > 0 && format.channelCount > 0 else {
                let msg = "Invalid audio format: sr=\(format.sampleRate) ch=\(format.channelCount)"
                print("MicCapture: \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                // Calculate RMS audio level
                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += channelData[i] * channelData[i]
                    }
                    let rms = sqrt(sum / Float(max(frameLength, 1)))
                    level.value = min(rms * 4, 1.0)
                }

                continuation.yield(buffer)
            }

            continuation.onTermination = { [engine] _ in
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }

            do {
                self.engine.prepare()
                try self.engine.start()
                print("MicCapture: engine started successfully")
            } catch {
                let msg = "Mic failed: \(error.localizedDescription)"
                print("MicCapture: \(msg)")
                errorHolder.value = msg
                continuation.finish()
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _audioLevel.value = 0
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            guard status == noErr else { continue }

            result.append((id: deviceID, name: name as String))
        }

        return result
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}

/// Simple thread-safe float holder for audio level.
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional string holder.
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

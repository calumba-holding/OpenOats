# FluidAudio Transcription Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace SFSpeechRecognizer with FluidAudio (Parakeet-TDT + Silero VAD) for fast, accurate, on-device transcription without Apple Intelligence dependency.

**Architecture:** Keep existing MicCapture/SystemAudioCapture audio pipeline. Add a new `StreamingTranscriber` class that resamples audio to 16kHz, runs Silero VAD for speech boundary detection, and batch-transcribes speech segments via Parakeet-TDT. TranscriptionEngine orchestrates two StreamingTranscriber instances (mic + system).

**Tech Stack:** FluidAudio 0.7.9+ (SPM), Parakeet-TDT v2 CoreML (~600MB), Silero VAD v6 CoreML (~900KB)

---

### Task 1: Add FluidAudio SPM Dependency

**Files:**
- Modify: `OnTheSpot/Package.swift`

**Step 1: Add FluidAudio package dependency**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OnTheSpot",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        .executableTarget(
            name: "OnTheSpot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/OnTheSpot",
            exclude: ["Info.plist", "OnTheSpot.entitlements", "Assets"]
        ),
    ]
)
```

**Step 2: Resolve packages and verify build**

Run: `cd /Users/rock/ai/projects/on-the-spot/OnTheSpot && swift package resolve`
Expected: FluidAudio and its dependencies download successfully.

Run: `cd /Users/rock/ai/projects/on-the-spot/OnTheSpot && swift build 2>&1 | tail -5`
Expected: Build succeeds (existing code unchanged).

**Step 3: Commit**

```bash
git add OnTheSpot/Package.swift OnTheSpot/Package.resolved
git commit -m "Add FluidAudio SPM dependency for on-device transcription"
```

---

### Task 2: Create StreamingTranscriber

New class that consumes an `AsyncStream<AVAudioPCMBuffer>`, runs VAD, and transcribes speech segments.

**Files:**
- Create: `OnTheSpot/Sources/OnTheSpot/Transcription/StreamingTranscriber.swift`

**Step 1: Create the StreamingTranscriber class**

```swift
import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via Parakeet-TDT.
final class StreamingTranscriber: @unchecked Sendable {
    private let asrManager: AsrManager
    private let vadManager: VadManager
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.onthespot", category: "StreamingTranscriber")

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(
        asrManager: AsrManager,
        vadManager: VadManager,
        speaker: Speaker,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.asrManager = asrManager
        self.vadManager = vadManager
        self.speaker = speaker
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var isSpeaking = false

        for await buffer in stream {
            // Resample to 16kHz mono
            guard let samples = resample(buffer) else { continue }

            // Run VAD on this chunk
            let vadConfig = VadSegmentationConfig.default
            do {
                let result = try await vadManager.processStreamingChunk(
                    samples,
                    state: vadState,
                    config: vadConfig,
                    returnSeconds: true,
                    timeResolution: 2
                )
                vadState = result.state

                if let event = result.event {
                    switch event.kind {
                    case .speechStart:
                        isSpeaking = true
                        speechSamples.removeAll(keepingCapacity: true)
                        log.debug("[\(self.speaker.rawValue)] speech start")

                    case .speechEnd:
                        isSpeaking = false
                        log.debug("[\(self.speaker.rawValue)] speech end, samples=\(speechSamples.count)")

                        // Transcribe the accumulated segment
                        if speechSamples.count > 8000 { // >0.5s at 16kHz
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                    }
                }

                // Accumulate samples during speech
                if isSpeaking {
                    speechSamples.append(contentsOf: samples)

                    // Force-flush if segment gets too long (30s = 480,000 samples)
                    if speechSamples.count > 480_000 {
                        let segment = speechSamples
                        speechSamples.removeAll(keepingCapacity: true)
                        await transcribeSegment(segment)
                    }
                }
            } catch {
                log.error("VAD error: \(error.localizedDescription)")
            }
        }

        // Flush any remaining speech on stream end
        if speechSamples.count > 8000 {
            await transcribeSegment(speechSamples)
        }
    }

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let result = try await asrManager.transcribe(samples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            log.info("[\(self.speaker.rawValue)] transcribed: \(text.prefix(80))")
            onFinal(text)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
        }
    }

    /// Resample AVAudioPCMBuffer to 16kHz mono [Float].
    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format

        // Set up converter on first buffer (or if format changes)
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/rock/ai/projects/on-the-spot/OnTheSpot && swift build 2>&1 | tail -10`
Expected: Build succeeds. StreamingTranscriber isn't used yet but should compile.

**Step 3: Commit**

```bash
git add OnTheSpot/Sources/OnTheSpot/Transcription/StreamingTranscriber.swift
git commit -m "Add StreamingTranscriber with VAD-gated FluidAudio transcription"
```

---

### Task 3: Rewrite TranscriptionEngine to Use FluidAudio

Replace `SFSpeechRecognizer` / `BufferRelay` with FluidAudio's `AsrManager` + `VadManager` + `StreamingTranscriber`.

**Files:**
- Modify: `OnTheSpot/Sources/OnTheSpot/Transcription/TranscriptionEngine.swift`

**Step 1: Rewrite TranscriptionEngine**

The full replacement file:

```swift
import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

/// Simple file logger for diagnostics — writes to /tmp/onthespot.log
func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/onthespot.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var assetStatus: String = "Ready"
    private(set) var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore

    /// Audio level from mic for the UI meter.
    var audioLevel: Float { micCapture.audioLevel }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Shared FluidAudio instances
    private var asrManager: AsrManager?
    private var vadManager: VadManager?

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func start(locale: Locale, inputDeviceID: AudioDeviceID = 0) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
        lastError = nil

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        // 1. Load FluidAudio models
        assetStatus = "Downloading models..."
        diagLog("[ENGINE-1] loading FluidAudio models...")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let asr = AsrManager(config: .default)
            try await asr.initialize(models: models)
            self.asrManager = asr

            let vad = try await VadManager()
            self.vadManager = vad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] FluidAudio models loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        guard let asrManager, let vadManager else { return }

        // 2. Start mic capture
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
        diagLog("[ENGINE-3] starting mic capture, targetMicID=\(String(describing: targetMicID))")
        let micStream = micCapture.bufferStream(deviceID: targetMicID)

        // 3. Start system audio capture
        diagLog("[ENGINE-4] starting system audio capture...")
        let sysStreams: SystemAudioCapture.CaptureStreams?
        do {
            sysStreams = try await systemCapture.bufferStream()
            diagLog("[ENGINE-5] system audio capture started OK")
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            diagLog("[ENGINE-5-FAIL] \(msg)")
            lastError = msg
            sysStreams = nil
        }

        // 4. Start mic transcription
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        // 5. Start system audio transcription
        if let sysStream = sysStreams?.systemAudio {
            let sysTranscriber = StreamingTranscriber(
                asrManager: asrManager,
                vadManager: vadManager,
                speaker: .them,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: text, speaker: .them))
                    }
                }
            )
            sysTask = Task.detached {
                await sysTranscriber.run(stream: sysStream)
            }
        }

        assetStatus = "Transcribing (Parakeet-TDT v2)"
        diagLog("[ENGINE-6] all transcription tasks started")
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    func stop() {
        micTask?.cancel()
        sysTask?.cancel()
        micKeepAliveTask?.cancel()
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        Task { await systemCapture.stop() }
        micCapture.stop()
        isRunning = false
        assetStatus = "Ready"
    }
}
```

Key changes:
- Removed: `import Speech`, `SFSpeechRecognizer`, `BufferRelay` actor, all SF* recognition code
- Added: `import FluidAudio`, `AsrManager`/`VadManager` initialization, `StreamingTranscriber` per source
- `locale` parameter is kept in the signature for API compatibility but Parakeet-TDT v2 is English-only
- Model download happens at start, with `assetStatus` reflecting progress

**Step 2: Verify it compiles**

Run: `cd /Users/rock/ai/projects/on-the-spot/OnTheSpot && swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors.

**Step 3: Commit**

```bash
git add OnTheSpot/Sources/OnTheSpot/Transcription/TranscriptionEngine.swift
git commit -m "Replace SFSpeechRecognizer with FluidAudio Parakeet-TDT + Silero VAD"
```

---

### Task 4: Build and Smoke Test

**Step 1: Full release build**

Run: `cd /Users/rock/ai/projects/on-the-spot && ./scripts/build_swift_app.sh`
Expected: Build succeeds, app installs to `/Applications/On The Spot.app`.

**Step 2: Launch and verify model download**

Run: `open "/Applications/On The Spot.app"`

Verify:
- App launches without crash
- Status shows "Downloading models..." then "Models ready"
- Models cached in `~/Library/Application Support/FluidAudio/Models/`

**Step 3: Test transcription**

- Click start, speak into mic
- Verify "You:" utterances appear in transcript
- Check `/tmp/onthespot.log` for `[ENGINE-*]` and `[you] transcribed:` log lines

**Step 4: Commit if any fixes needed**

```bash
git add -p  # only changed files
git commit -m "Fix issues found during smoke test"
```

---

### Task 5: Remove Speech Framework Dependency (cleanup)

**Files:**
- Modify: `OnTheSpot/Sources/OnTheSpot/Info.plist` (if Speech-related keys exist)

**Step 1: Check for Speech framework references**

Search for any remaining `import Speech` or `SFSpeech` references:

Run: `grep -r "Speech" OnTheSpot/Sources/ --include="*.swift" -l`
Expected: No files reference Speech framework.

Run: `grep -r "NSSpeechRecognitionUsageDescription" OnTheSpot/Sources/ -l`
Check if Info.plist has the speech recognition usage description. If so, it can be removed (FluidAudio doesn't need it — it runs entirely on-device without system speech APIs).

**Step 2: Clean up if needed and commit**

```bash
git add <changed-files>
git commit -m "Remove Speech framework dependency"
```

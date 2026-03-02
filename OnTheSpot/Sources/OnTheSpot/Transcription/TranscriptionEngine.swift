@preconcurrency import Speech
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Observation

/// Orchestrates dual SpeechAnalyzer instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var assetStatus: String = "Ready"
    private(set) var lastError: String?

    let micCapture = MicCapture()
    private let systemCapture = SystemAudioCapture()
    private let transcriptStore: TranscriptStore

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func start(locale: Locale, inputDeviceID: AudioDeviceID = 0) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        assetStatus = "Preparing..."

        let micTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        let sysTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        // Check and install assets if needed
        let status = await AssetInventory.status(forModules: [micTranscriber])
        switch status {
        case .installed:
            assetStatus = "Models ready"
        case .downloading, .supported:
            assetStatus = "Installing speech models..."
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [micTranscriber]) {
                    // Observe progress via KVO
                    let progress = request.progress
                    while !progress.isFinished && !progress.isCancelled {
                        assetStatus = "Installing: \(Int(progress.fractionCompleted * 100))%"
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                assetStatus = "Models ready"
            } catch {
                assetStatus = "Model install failed: \(error.localizedDescription)"
                isRunning = false
                return
            }
        case .unsupported:
            assetStatus = "Speech recognition not supported for this locale"
            isRunning = false
            return
        @unknown default:
            break
        }

        // Start mic transcription
        let deviceID: AudioDeviceID? = inputDeviceID > 0 ? inputDeviceID : nil
        micTask = Task.detached { [micCapture, transcriptStore] in
            do {
                let micStream = micCapture.bufferStream(deviceID: deviceID)
                let inputSequence = micStream.map { buffer -> AnalyzerInput in
                    nonisolated(unsafe) let b = buffer
                    return AnalyzerInput(buffer: b)
                }

                let analyzer = SpeechAnalyzer(
                    inputSequence: inputSequence,
                    modules: [micTranscriber]
                )

                for try await result in micTranscriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }

                    let isFinal = result.range.duration != .zero

                    await MainActor.run {
                        if isFinal {
                            transcriptStore.volatileYouText = ""
                            transcriptStore.append(Utterance(text: text, speaker: .you))
                        } else {
                            transcriptStore.volatileYouText = text
                        }
                    }
                }

                _ = analyzer
            } catch {
                if !Task.isCancelled {
                    let msg = "Mic error: \(error.localizedDescription)"
                    print(msg)
                    await MainActor.run { [weak self] in
                        self?.lastError = msg
                    }
                }
            }
        }

        // Start system audio transcription
        sysTask = Task.detached { [systemCapture, transcriptStore] in
            do {
                let sysStream = try await systemCapture.bufferStream()
                let inputSequence = sysStream.map { buffer -> AnalyzerInput in
                    nonisolated(unsafe) let b = buffer
                    return AnalyzerInput(buffer: b)
                }

                let analyzer = SpeechAnalyzer(
                    inputSequence: inputSequence,
                    modules: [sysTranscriber]
                )

                for try await result in sysTranscriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }

                    let isFinal = result.range.duration != .zero

                    await MainActor.run {
                        if isFinal {
                            transcriptStore.volatileThemText = ""
                            transcriptStore.append(Utterance(text: text, speaker: .them))
                        } else {
                            transcriptStore.volatileThemText = text
                        }
                    }
                }

                _ = analyzer
            } catch {
                if !Task.isCancelled {
                    let msg = "System audio error: \(error.localizedDescription)"
                    print(msg)
                    await MainActor.run { [weak self] in
                        self?.lastError = msg
                    }
                }
            }
        }
    }

    func stop() {
        micTask?.cancel()
        sysTask?.cancel()
        micTask = nil
        sysTask = nil
        micCapture.stop()
        Task { await systemCapture.stop() }
        isRunning = false
        assetStatus = "Ready"
    }
}

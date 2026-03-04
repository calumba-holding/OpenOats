# FluidAudio Transcription Engine

Replace `SFSpeechRecognizer` with FluidAudio (Parakeet-TDT + Silero VAD) for fast, accurate on-device transcription that works without Apple Intelligence.

## Problem

Apple's SpeechAnalyzer crashes on external boot drives. The fallback `SFSpeechRecognizer` works but has limited quality and usage caps.

## Solution

Use FluidAudio SDK with Parakeet-TDT v2 (English-only, 600M params, 2.1% WER) and Silero VAD CoreML for speech boundary detection. Keep existing audio capture pipeline unchanged.

## Architecture

```
MicCapture ──AsyncStream<AVAudioPCMBuffer>──┐
                                             ├──▶ Resample 16kHz ──▶ Silero VAD ──▶ AsrManager.transcribe()
SystemAudioCapture ──AsyncStream<AVAudioPCMBuffer>──┘                                       │
                                                                                            ▼
                                                                                     TranscriptStore
```

## Components

### StreamingTranscriber (new)

Per-source transcription pipeline:

1. Consumes `AsyncStream<AVAudioPCMBuffer>` from mic or system audio
2. Resamples to 16kHz mono via `AudioConverter` (FluidAudio utility)
3. Runs Silero VAD streaming — detects `speechStart` / `speechEnd` events
4. Accumulates `[Float]` samples during speech
5. On `speechEnd`, calls `AsrManager.transcribe(samples)` (110-190x RTFx)
6. Feeds result to TranscriptStore

### TranscriptionEngine (modified)

- Drop: `SFSpeechRecognizer`, `BufferRelay` actor, `Speech` framework import
- Add: FluidAudio `AsrManager` + `VadManager` init
- Models auto-download from HuggingFace on first run (~600MB + ~900KB)
- `assetStatus` reflects model download/ready state
- Two concurrent tasks: mic → transcribe(speaker: .you), sys → transcribe(speaker: .them)

### Unchanged

- `MicCapture` — AVAudioEngine mic capture with device selection
- `SystemAudioCapture` — ScreenCaptureKit system audio
- `TranscriptStore` — receives Utterance objects as before
- `ContentView` — reads same observable properties
- Audio level metering — still from mic tap

## Dependencies

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
```

## Models

- Parakeet-TDT v2 (~600MB CoreML, English-only, 2.1% WER, 110-190x RTFx)
- Silero VAD v6 (~900KB CoreML, 1220x RTFx)
- Auto-downloaded on first launch, cached in ~/Library/Application Support/FluidAudio/Models/

## Performance

| Component | Speed | Accuracy |
|-----------|-------|----------|
| Silero VAD | 1220x real-time | 96% accuracy, 97.9% F1 |
| Parakeet-TDT v2 | 110-190x real-time | 2.1% WER |
| Total pipeline latency | ~0.5s after speech ends | — |

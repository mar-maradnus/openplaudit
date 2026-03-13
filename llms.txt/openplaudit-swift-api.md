# OpenPlaudit — Swift API Reference

Native macOS menubar app for PLAUD Note. BLE sync, Opus decode, whisper.cpp transcription. Shares config/state with the Python CLI (`plaude`).

## Package: `OpenPlaudit` (v0.4.0)

Build: `swift build`. Run: `scripts/run-app.sh`. Release: `scripts/build-release.sh` (produces `.app.zip`). Requires macOS 14+, `brew install opus`.

SPM targets: `BLEKit`, `AudioKit`, `TranscriptionKit`, `SyncEngine`, `MeetingKit`, `COpus` (system library), `OpenPlaudit` (app).

Tests: 118 (BLE protocol + error classification, Opus decoder, session state + recovery, config, meeting detection, audio conversion, meeting config, meeting state persistence).

---

## `BLEKit` — BLE Protocol & Client

### Protocol.swift — Pure functions, no I/O

```swift
import BLEKit

let pkt = buildCmd(cmdHandshake, payload: tokenData)  // -> Data: [0x01][cmd_id:2LE][payload]
let crc = crc16CCITT(data)                             // CRC-16/CCITT-FALSE, init=0xFFFF, poly=0x1021
let sessions = parseSessions(payload)                  // -> [RecordingSession]
```

Constants: `serviceUUID`, `txUUID`, `rxUUID`, `protoCommand` (0x01), `protoVoice` (0x02).

Command IDs: `cmdHandshake` (1), `cmdTimeSync` (4), `cmdGetRecSessions` (26), `cmdSyncFileStart` (28), `cmdSyncFileTail` (29), `cmdFileChecksum` (116), `cmdFileChecksumRsp` (117).

`RecordingSession`: `sessionID: UInt32` (Unix timestamp), `fileSize: UInt32`, `scene: UInt16`.

### PlaudClient.swift — Actor-based BLE client

```swift
let client = PlaudClient(address: "UUID-STRING", token: "hex_token")

try await client.connect()                  // CoreBluetooth scan + connect + service discovery (15s timeout, Nordic fallback)
let ok = try await client.handshake()       // Authenticate with binding token -> Bool
try await client.timeSync()                 // Sync Unix time to device
let sessions = try await client.getSessions() // -> [RecordingSession]
await client.disconnect()
```

Voice data buffer: `client.voiceData` (Data), `client.voicePacketCount` (Int). Controlled by `client.setReceiving(true/false)` and `client.resetVoiceBuffer()`.

### BLEError — Classified error types

```swift
public enum BLEError: Error {
    // Connection phase
    case bluetoothOff              // BT powered off
    case bluetoothUnauthorized     // Missing privacy permission
    case deviceNotFound            // Scan found nothing
    case connectionFailed(Error?)  // CB connection failed
    case disconnected              // Lost connection

    // Service discovery
    case serviceNotFound           // PLAUD service UUID not present
    case characteristicsNotFound   // TX/RX characteristics missing

    // Protocol
    case notConnected              // No active connection
    case handshakeFailed           // Token rejected
    case timeout(String)           // Operation timed out
    case transferRejected(UInt8)   // Device rejected transfer
    case noResponse(String)        // No response to command
}
```

### Transfer.swift — File download

```swift
let rawData = try await downloadFile(
    client: client,
    sessionID: sid,
    fileSize: session.fileSize,
    progress: { current, expected, pct in ... }
)
// Returns Data (raw Opus with 9-byte per-frame headers)
// Throws DownloadError on stall, CRC mismatch, alignment error
```

### Scanner.swift — Device discovery

```swift
let scanner = BLEScanner()
let devices = await scanner.scan(timeout: 15.0) // -> [DiscoveredDevice]
// Each: name, identifier (UUID), rssi
// Scans for PLAUD service UUID first, falls back to Nordic manufacturer ID (0x0059)
```

---

## `AudioKit` — Opus Decode + WAV

### OpusDecoder.swift

```swift
import AudioKit

let frames = extractOpusFrames(rawData)    // -> [Data], each up to 80 bytes
let pcm = try decodeOpusFrames(frames)     // -> Data, 16-bit LE PCM at 16kHz mono
let pcm = try decodeOpusRaw(rawData)       // Shorthand: extract + decode
```

Audio parameters: 16000 Hz, 1 channel, 20ms frames, 320 samples/frame. BLE packets: 89 bytes = 9-byte header + up to 80-byte Opus frame.

### WAVWriter.swift

```swift
try saveWAV(pcmData, to: url)                    // Write WAV file (atomic)
let wavBytes = buildWAV(pcmData, sampleRate: 16000) // In-memory RIFF WAV
```

---

## `TranscriptionKit` — Whisper

```swift
import TranscriptionKit

let transcriber = Transcriber(model: "medium")
try await transcriber.loadModel()              // Downloads on first use to ~/.local/share/openplaudit/models/
let result = try await transcriber.transcribe(wavPath: url, language: "en")
// result: TranscriptionResult { file, durationSeconds, model, language, segments, text }
// segments: [Segment { start, end, text }]
```

Models: tiny, tiny.en, base, base.en, small, small.en, medium, medium.en, large. Downloaded from HuggingFace.

---

## `SyncEngine` — Orchestrator

### SyncEngine.swift — @MainActor ObservableObject

```swift
import SyncEngine

let engine = SyncEngine(config: loadConfigWithKeychain())

// Sync control
engine.startSync()           // Launch background sync task
engine.cancelSync()          // Cancel in-progress sync
engine.startAutoSync(intervalMinutes: 30)
engine.stopAutoSync()

// Observable state
engine.status                // .idle | .connecting | .syncing(current, total) | .error(String)
engine.isConnected           // Bool
engine.progress              // SyncProgress? { bytesReceived, bytesExpected, percentage }
engine.recentRecordings      // [RecentRecording] (up to 10, sorted newest first, with transcript preview)

// Config
engine.config                // AppConfig (read/write)
engine.persistConfig()       // Save to TOML + Keychain
```

Pipeline: download → decode → transcribe per session. State tracked in `SessionState`. Heavy work runs off-main via `Task.detached`. Cooperative cancellation via `Task.checkCancellation()`.

BLE errors caught during connection are mapped to user-facing remediation messages (e.g. "Bluetooth is off — turn it on in System Settings") via an internal `remediation(for:)` method. Batch notifications: one summary per sync cycle rather than per-session.

WAV duration is always sourced from `AVAudioFile` (authoritative) rather than byte arithmetic.

### Config.swift

```swift
let cfg = loadConfig()                    // From ~/.config/openplaudit/config.toml
let cfg = loadConfigWithKeychain()        // TOML + Keychain token overlay
try saveConfig(cfg)                       // Write TOML
try saveConfigWithKeychain(cfg)           // TOML (no token) + Keychain (token)
let dirs = getOutputDirs(cfg)             // OutputDirs { base, audio, transcripts, raw }
try setNested(&cfg, key: "device.address", value: "...")
```

### SessionState.swift — @MainActor

```swift
let state = SessionState()               // Default: ~/.local/share/openplaudit/state.json

state.markDownloaded(sessionID)          // Sets downloaded_at, clears failure
state.markDecoded(sessionID)
state.markTranscribed(sessionID)
state.markFailed(sessionID, reason: "...")

state.needsDownload(sessionID)           // -> Bool
state.needsDecode(sessionID)
state.needsTranscription(sessionID)
state.isComplete(sessionID)              // All three phases done

try state.saveAtomically()               // Atomic write + rolling backup
state.reload()

// Recovery
state.hasBackup                          // Bool
try state.restoreFromBackup()            // Restore from rolling backup
// Throws StateError.backupNotFound if no backup exists
```

Corrupt state files are quarantined with timestamps (`state.corrupt.YYYYMMDDTHHMMSS.json`, keeps 3). A rolling backup (`state.backup.json`) is created before every atomic write.

### Keychain.swift

```swift
try KeychainHelper.save(key: "device.token", value: token)
let token = KeychainHelper.load(key: "device.token")  // -> String?
KeychainHelper.delete(key: "device.token")
```

Service: `com.openplaudit.app`, class: `kSecClassGenericPassword`.

### Notifications.swift

```swift
sendNotification(title: "OpenPlaudit", body: "2 recordings synced", subtitle: "")
```

---

## CLI Compatibility

Both tools share:
- Config: `~/.config/openplaudit/config.toml`
- State: `~/.local/share/openplaudit/state.json`
- Output: `~/Documents/OpenPlaudit/{audio,transcripts,raw}`
- Transcript JSON format: identical structure

The Swift app stores the token in Keychain and writes an empty token to TOML. The CLI reads the token from TOML. Users must set the token in both places, or use the app exclusively.

---

## `MeetingKit` — Meeting Recording

### MeetingDetector.swift — Process-based app detection

```swift
import MeetingKit

let detector = MeetingDetector()
let apps = detector.detect(
    monitoredApps: ["us.zoom.xos", "com.apple.FaceTime"],
    includeBrowsers: false
)
// apps: [MeetingApp] — enum with .zoom, .facetime, .teamsNew, etc.

// Polling mode (fires onChange when apps change):
detector.onChange = { apps, newApps in ... }  // newApps: Set<String> of newly appeared bundle IDs
detector.startMonitoring(monitoredApps: [...], includeBrowsers: false, interval: 5.0)
detector.stopMonitoring()
```

`MeetingApp` enum: `.teamsNew`, `.teamsClassic`, `.zoom`, `.webex`, `.slack`, `.facetime`, `.chrome`, `.safari`, `.firefox`. Properties: `displayName`, `isBrowser`, `rawValue` (bundle ID).

For tests: inject `runningAppProvider` closure to avoid NSWorkspace dependency.

### AudioCaptureSession.swift — ScreenCaptureKit wrapper

```swift
let session = AudioCaptureSession(outputDir: tempDir)
try await session.start(appBundleID: "us.zoom.xos")
// ... captures audio ...
let wavPath = try await session.stop()   // Returns URL to 16kHz mono 16-bit WAV
```

- Uses `SCStream` with `capturesAudio = true`, `sampleRate = 16000`, `channelCount = 1`
- Video frames are discarded (minimum 2x2 @ 1fps to satisfy API)
- Float32 PCM from ScreenCaptureKit converted to Int16 in the audio callback
- Periodic flush to disk (60s chunks) to limit RAM usage during long meetings
- Chunks reassembled into final WAV on stop

Pure conversion function: `float32ToInt16(_ sample: Float) -> Int16`

### MeetingRecorder.swift — Single recording coordinator

```swift
let recorder = MeetingRecorder(outputBaseDir: dirs.meetingAudio)
try await recorder.start(appBundleID: "us.zoom.xos", appDisplayName: "Zoom")
// ... recording ...
let recording = try await recorder.stop()
// recording: MeetingRecording { wavPath, appName, startedAt, durationSeconds }
```

### MeetingEngine.swift — @MainActor ObservableObject orchestrator

```swift
let meetingEngine = MeetingEngine(config: appConfig, transcriber: sharedTranscriber)
meetingEngine.startMonitoring()    // Start polling for meeting apps
meetingEngine.stopMonitoring()

// Manual control
await meetingEngine.startManualRecording(app: .zoom)
await meetingEngine.stopManualRecording()

// Observable state
meetingEngine.recordingState       // .idle | .monitoring | .recording(app) | .transcribing | .error(String)
meetingEngine.detectedApps         // [MeetingApp]
meetingEngine.recentMeetings       // [RecentMeeting]
meetingEngine.recordingDurationString // "2:34"
```

Auto-record: when `autoRecord` is true, starts recording 10s after a meeting app appears, stops 10s after it disappears. Apps already running when monitoring starts are not treated as new appearances (previouslyDetected is seeded on start).

Shares `Transcriber` instance with `SyncEngine` (model loaded once). After recording, transcribes to the same JSON format as PLAUD recordings.

State persisted in `~/.local/share/openplaudit/meeting-state.json` via `MeetingState`. On launch, `rebuildRecentMeetings()` restores the list from disk.

### MeetingState.swift — Persistent meeting state

```swift
let state = MeetingState()  // Default: ~/.local/share/openplaudit/meeting-state.json
state.markRecorded(id: uuid, appName: "Zoom", duration: 120.5, filename: "20260313_UTC.wav")
state.markTranscribed(id: uuid)
state.markFailed(id: uuid, reason: "capture error")
state.needsTranscription(id)  // -> Bool
state.isComplete(id)           // -> Bool
try state.saveAtomically()     // Atomic write + rolling backup
```

Corrupt files quarantined with timestamps, same pattern as `SessionState`.

### Config additions

```swift
// In AppConfig:
cfg.meeting.enabled               // Bool, default false
cfg.meeting.autoRecord            // Bool, default false
cfg.meeting.monitoredApps         // [String], bundle IDs
cfg.meeting.includeBrowsers       // Bool, default false
cfg.meeting.micDeviceID           // String, empty = system default
cfg.meeting.consentAcknowledged   // Bool, default false
```

TOML section: `[meeting]` with fields `enabled`, `auto_record`, `monitored_apps`, `include_browsers`, `mic_device_id`, `consent_acknowledged`.

### Output directories

```
~/Documents/OpenPlaudit/
    meetings/
        audio/          ← Meeting WAV files (yyyyMMdd_HHmmss_UTC.wav)
        transcripts/    ← Meeting transcript JSON
```

Available via `getOutputDirs(cfg).meetingAudio` and `getOutputDirs(cfg).meetingTranscripts`.

### Permissions

- **Screen recording**: macOS prompts at runtime when `SCStream` starts (no entitlement needed)
- **Microphone**: `NSMicrophoneUsageDescription` in Info.plist + `com.apple.security.device.audio-input` entitlement

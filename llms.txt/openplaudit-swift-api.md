# OpenPlaudit — Swift API Reference

Native macOS menubar app for PLAUD Note. BLE sync, Opus decode, whisper.cpp transcription. Shares config/state with the Python CLI (`plaude`).

## Package: `OpenPlaudit` (v0.2.0)

Build: `swift build`. Run: `scripts/run-app.sh`. Requires macOS 14+, `brew install opus`.

SPM targets: `BLEKit`, `AudioKit`, `TranscriptionKit`, `SyncEngine`, `COpus` (system library), `OpenPlaudit` (app).

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

try await client.connect()                  // CoreBluetooth scan + connect + service discovery
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
engine.recentRecordings      // [RecentRecording] (up to 10, sorted newest first)

// Config
engine.config                // AppConfig (read/write)
engine.persistConfig()       // Save to TOML + Keychain
```

Pipeline: download → decode → transcribe per session. State tracked in `SessionState`. Heavy work runs off-main via `Task.detached`. Cooperative cancellation via `Task.checkCancellation()`.

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
```

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

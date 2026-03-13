# OpenPlaudit

Local-first tools for the PLAUD Note AI voice recorder. Sync recordings over BLE, decode Opus audio, and transcribe with Whisper — entirely offline, no cloud required.

OpenPlaudit includes a **Python CLI** (`plaude`) and a **native macOS menubar app**, both sharing the same configuration, state, and output files.

## Important

**This project exists for one reason: privacy.** The official PLAUD app uploads recordings to cloud servers for processing. If that is acceptable to you, use the official app — it is better supported and will not break.

OpenPlaudit operates entirely on your local machine. Recordings never leave your device. Transcription runs locally via whisper.cpp (macOS app) or OpenAI Whisper (CLI).

**This tool is built on a reverse-engineered BLE protocol. Any firmware update to the PLAUD Note can break compatibility without warning.** There is no affiliation with PLAUD Inc., and no guarantee of continued operation.

## macOS Menubar App

A native Swift menubar app that syncs PLAUD recordings and records meetings, all locally.

### Install

1. Download `OpenPlaudit.app.zip` from the [latest release](https://github.com/mar-maradnus/openplaudit/releases)
2. Unzip and move `OpenPlaudit.app` to `/Applications`
3. Right-click the app, then click Open (required once for unsigned apps)
4. Configure your device address and token in Settings

Or build from source:

```bash
brew install opus
git clone https://github.com/mar-maradnus/openplaudit.git
cd openplaudit
swift build
scripts/run-app.sh
```

**Note:** For development, create a self-signed certificate named "OpenPlaudit Dev" (Keychain Access → Certificate Assistant → Create a Certificate → Code Signing). This provides a stable identity for macOS TCC permissions across rebuilds.

### Configuration

After launch, a waveform icon appears in the menubar. Click it and choose **Settings**.

1. **Device tab** — enter your BLE device address (UUID) and binding token. The token is stored in the macOS Keychain, not in the config file.
2. **Output tab** — change the output directory if desired (default: `~/Documents/OpenPlaudit`).
3. **Transcription tab** — select the Whisper model (tiny → large, default: medium) and language. Models are downloaded on first use (~1.5 GB for medium).
4. **Sync tab** — toggle auto-sync and set the interval (1–120 minutes). Toggle raw file retention, auto-delete after transcription, and notifications.
5. **Meetings tab** — acknowledge consent, enable meeting recording, configure monitored apps, toggle auto-record, and select microphone.

Click **Save** in each tab to apply. To find your device UUID, use `plaude scan` from the CLI, or check Console.app for BLE discovery logs.

### PLAUD Sync

- **Sync Now** — click in the menubar to start a manual sync. The icon changes during sync and the menu shows progress (e.g. "Syncing 2/5...").
- **Cancel Sync** — appears during sync. Cooperative cancellation; partial downloads are resumed on next sync.
- **Auto-sync** — when enabled, syncs on the configured interval. Runs silently in the background.
- **Recent recordings** — the last 5 recordings with date, duration, and transcript preview. Click to open the transcript or audio file.
- **Notifications** — a summary notification is sent after each sync cycle.
- **State recovery** — if `state.json` becomes corrupted, go to Settings → Sync → "Restore State from Backup".

### Meeting Recording

OpenPlaudit detects running meeting applications (Teams, Zoom, Webex, FaceTime, Slack, and optionally browsers) and records system audio plus microphone locally using ScreenCaptureKit. Recordings are transcribed with the same whisper.cpp pipeline as PLAUD recordings.

- **Manual recording** — click "Record Meeting" in the menubar. The icon changes to a red recording indicator and the menu shows elapsed time. Click "Stop Recording" to finish.
- **Auto-record** — when enabled, recording starts automatically 10 seconds after a meeting app launches and stops 10 seconds after it quits.
- **Consent** — meeting recording must be explicitly enabled in Settings after acknowledging a consent notice. You are responsible for complying with local recording consent laws.
- **Output** — meeting recordings are saved to `~/Documents/OpenPlaudit/meetings/audio/` and transcripts to `~/Documents/OpenPlaudit/meetings/transcripts/`.

### Troubleshooting

Error messages in the menubar include actionable guidance:

| Error | What to do |
|-------|------------|
| Bluetooth is off | Turn on Bluetooth in System Settings |
| Bluetooth permission denied | System Settings → Privacy → Bluetooth → grant OpenPlaudit access |
| Device not found | Ensure PLAUD Note is nearby, powered on, and not connected to another app |
| Connection/handshake failed | Move closer to device; ensure it is not recording; check your token |
| Transfer rejected | Ensure device is not recording |
| Timeout / No response | Move closer or restart the device |
| BLE service not found | Device may need a firmware update (note: updates may break OpenPlaudit) |
| Screen Recording permission | macOS prompts on first meeting recording; grant access in System Settings |

### Features

- Background PLAUD sync on a configurable interval (1–120 minutes)
- Meeting recording with auto-detect for Teams, Zoom, Webex, FaceTime, Slack
- Local transcription via whisper.cpp with Metal acceleration on Apple Silicon
- Secure token storage in macOS Keychain
- Transcript preview in recent recordings menu
- Cancel in-progress syncs with cooperative cancellation
- macOS notifications with optional transcript preview
- Structured logging visible in Console.app
- State recovery from corruption with rolling backups
- Classified BLE error messages with actionable troubleshooting guidance

### Permissions

- **Bluetooth** — required for PLAUD sync
- **Screen Recording** — required for meeting audio capture (macOS prompts at runtime)
- **Microphone** — required for meeting mic capture

### Requirements

- macOS 14+ (Sonoma)
- Homebrew: `brew install opus`
- A PLAUD Note device with known BLE address and binding token (for PLAUD sync)
- Screen Recording and Microphone permissions (for meeting recording)

## Python CLI

A command-line tool for the same workflow, useful for scripting and automation.

### Install

```bash
cd openplaudit
python -m venv venv && source venv/bin/activate
pip install -e ".[dev]"
```

Requires Python 3.11+, macOS, `brew install opus`.

### Quick Start

```bash
plaude config init
plaude config set device.address "YOUR-DEVICE-UUID"
plaude config set device.token "your_token_here"
plaude scan       # Find your device address
plaude list       # List recordings on device
plaude sync       # Download, decode, transcribe
```

### Commands

| Command | Description |
|---------|-------------|
| `plaude sync` | Connect, download new recordings, decode, transcribe, notify |
| `plaude list` | List recordings on device (no download) |
| `plaude scan` | Scan for PLAUD BLE devices |
| `plaude transcribe <file>` | Transcribe a local audio file with Whisper |
| `plaude config show` | Print current configuration |
| `plaude config init` | Create default config file |
| `plaude config set <key> <value>` | Set a config value (e.g. `device.address`) |

Use `-v` for verbose BLE output, `-q` for minimal output.

## Shared Configuration

Both tools read the same config and state files. Run either tool; neither will re-download what the other already processed.

**Config**: `~/.config/openplaudit/config.toml`

```toml
[device]
address = ""       # BLE UUID from `plaude scan`
token = ""         # 32-char hex binding token (app stores in Keychain instead)

[output]
base_dir = "~/Documents/OpenPlaudit"

[transcription]
model = "medium"   # Whisper model: tiny, base, small, medium, large
language = "en"

[sync]
auto_delete_local_audio = false
keep_raw = false
auto_sync_enabled = false
auto_sync_interval_minutes = 30

[notifications]
enabled = true
show_preview = true

[meeting]
enabled = false
auto_record = false
monitored_apps = ["com.microsoft.teams2", "us.zoom.xos", "com.cisco.webexmeetings", "com.apple.FaceTime"]
include_browsers = false
mic_device_id = ""
consent_acknowledged = false
```

**State**: `~/.local/share/openplaudit/state.json`

**Output**:
```
~/Documents/OpenPlaudit/
  audio/              — decoded PLAUD WAV files (16kHz mono)
  transcripts/        — PLAUD transcript JSON with timestamped segments
  raw/                — raw Opus downloads (if keep_raw = true)
  meetings/audio/     — meeting recording WAV files
  meetings/transcripts/ — meeting transcript JSON
```

## Sync Workflow

Each recording progresses through three phases:

1. **Download** — BLE transfer of raw Opus packets from device
2. **Decode** — Extract Opus frames, decode to 16kHz mono WAV
3. **Transcribe** — Run Whisper locally, save JSON with timestamped segments

State is tracked per session. If sync is interrupted, the next run resumes from the last successful phase. Failed sessions are retried automatically.

## Transcript Format

```json
{
  "file": "20260312_094358_UTC",
  "duration_seconds": 24.2,
  "model": "medium",
  "language": "en",
  "segments": [
    {"start": 0.0, "end": 3.5, "text": "..."}
  ],
  "text": "full transcript..."
}
```

## Obtaining the Binding Token

The PLAUD Note requires a 32-character hex binding token for BLE authentication. This token is issued by PLAUD's cloud service during initial pairing with the official app. See [docs/token-extraction.md](docs/token-extraction.md) for extraction methods.

## Tests

```bash
# Python CLI tests (118 tests)
pytest

# Swift app tests (118 tests)
swift test
```

Tests cover protocol serialisation, CRC, BLE error classification, config loading, state tracking with backup/recovery, Opus frame extraction, BLE transfer validation, CLI commands, sync orchestration, retry/resume, meeting detection, audio conversion, and meeting state persistence. BLE and meeting recording integration are tested manually.

## Project Structure

```
openplaudit/
  # Python CLI
  src/plaude/
    cli.py              — Click CLI entry point
    config.py           — TOML config with defaults and deep merge
    state.py            — Phase-aware session state tracker
    sync.py             — Orchestrator: download -> decode -> transcribe
    notify.py           — macOS notifications via osascript
    ble/
      protocol.py       — Packet building, CRC-16, command constants
      client.py         — BleakClient wrapper, handshake, session listing
      transfer.py       — File download via voice packet capture
    audio/
      decoder.py        — Opus frame extraction and PCM decoding
    transcription/
      whisper.py        — Whisper model loading and transcription

  # macOS Menubar App
  Sources/
    BLEKit/             — CoreBluetooth client, BLE protocol, file transfer
    AudioKit/           — Opus decode via libopus, WAV writing
    TranscriptionKit/   — whisper.cpp via SwiftWhisper
    SyncEngine/         — Orchestrator, config, state, Keychain, notifications
    MeetingKit/         — Meeting detection, ScreenCaptureKit recording, transcription
    OpenPlaudit/        — AppKit menubar app, SwiftUI settings and about views
    COpus/              — C system library bridge for libopus

  # Shared
  docs/                 — Protocol notes, token extraction guide
  llms.txt/             — LLM-friendly API references
  scripts/              — Build and run helpers
  Tests/                — Python (118) and Swift (68) test suites
```

## Disclaimer

This is an independent project built on a reverse-engineered BLE protocol. **It can break with any PLAUD Note firmware update.** There is no affiliation with or endorsement by PLAUD Inc.

If you do not have specific privacy or security concerns about cloud-based recording storage, the official PLAUD app provides a better and more reliable experience.

## Author

Ram Sundaram

## License

MIT

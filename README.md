# OpenPlaudit

Local-first CLI for PLAUD Note AI voice recorder. Syncs recordings over BLE, decodes Opus audio, and transcribes with OpenAI Whisper — entirely offline, no cloud required.

## Requirements

- Python 3.11+
- macOS (CoreBluetooth via Bleak)
- Opus codec library (`brew install opus`)
- A paired PLAUD Note device (binding token extracted from mobile app backup)

## Install

```bash
cd openplaudit
python -m venv venv && source venv/bin/activate
pip install -e ".[dev]"
```

## Quick Start

```bash
# Create config with defaults
plaude config init

# Set your device address and token
plaude config set device.address "YOUR-DEVICE-UUID"
plaude config set device.token "your_token_here"

# Scan for PLAUD devices (to find address)
plaude scan

# List recordings on device
plaude list

# Sync everything: download, decode, transcribe
plaude sync
```

## Commands

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

## Configuration

Config file: `~/.config/openplaudit/config.toml`

```toml
[device]
address = ""       # BLE UUID from `plaude scan`
token = ""         # 32-char hex binding token

[output]
base_dir = "~/Documents/OpenPlaudit"

[transcription]
model = "medium"   # Whisper model: tiny, base, small, medium, large
language = "en"

[sync]
auto_delete_local_audio = false
keep_raw = false   # Keep raw .opus files from BLE transfer

[notifications]
enabled = true
show_preview = true
```

Output structure:
```
~/Documents/OpenPlaudit/
  audio/        — decoded WAV files
  transcripts/  — JSON transcripts (timestamped segments)
  raw/          — raw Opus downloads (if keep_raw = true)
```

## Sync Workflow

Each recording progresses through three phases:

1. **Download** — BLE transfer of raw Opus packets from device
2. **Decode** — Extract Opus frames from BLE packets, decode to WAV
3. **Transcribe** — Run Whisper, save JSON with timestamped segments

State is tracked in `~/.local/share/openplaudit/state.json`. If sync is interrupted, the next run resumes from the last successful phase per recording. Failed sessions are retried automatically.

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

## Tests

```bash
pytest
```

118 tests covering protocol serialisation, CRC, config load/save, state tracking, Opus frame extraction, BLE transfer validation, CLI commands, sync orchestration, and retry/resume semantics. BLE integration is tested manually against the real device.

## Project Structure

```
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
```

## Disclaimer

This tool is a personal utility built on a reverse-engineered BLE protocol. Firmware updates may break compatibility. There is no affiliation with PLAUD Inc.

## License

MIT

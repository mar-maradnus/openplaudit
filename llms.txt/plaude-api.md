# OpenPlaudit — Python API Reference

Local-first CLI and library for PLAUD Note AI recorder. BLE sync, Opus decode, Whisper transcription.

## Package: `plaude` (v0.1.0)

Install: `pip install -e .` from repo root. Requires Python >= 3.11, macOS, `brew install opus`.

Entry point: `plaude = plaude.cli:main` (Click CLI).

---

## `plaude.config`

TOML configuration at `~/.config/openplaudit/config.toml`. State at `~/.local/share/openplaudit/state.json`.

```python
from plaude.config import load_config, save_config, init_config, config_path, set_nested, get_output_dirs

cfg = load_config()                          # Load config merged with defaults
cfg = load_config(Path("/custom/path.toml")) # Load from specific path
init_config()                                # Create default config if missing
save_config(cfg)                             # Save to default path
set_nested(cfg, "device.address", "AA:BB")   # Set dotted key (auto-coerces bool/int)
dirs = get_output_dirs(cfg)                  # Returns dict: base, audio, transcripts, raw (Path objects)
```

### Default Config Structure

```toml
[device]
address = ""           # macOS CoreBluetooth UUID
token = ""             # 32-char hex BLE binding token

[output]
base_dir = "~/Documents/OpenPlaudit"  # audio/, transcripts/, raw/ created under this

[transcription]
model = "medium"       # tiny|base|small|medium|large
language = "en"        # "" for auto-detect

[sync]
auto_delete_local_audio = false
keep_raw = false       # retain raw BLE download in raw/

[notifications]
enabled = true
show_preview = true    # first 100 chars of transcript in notification
```

---

## `plaude.ble.protocol`

BLE protocol primitives. No I/O — pure functions for packet building and parsing.

```python
from plaude.ble.protocol import build_cmd, crc16_ccitt, parse_sessions

pkt = build_cmd(cmd_id=1, payload=b"\x02\x00\x00...")  # -> bytes: [0x01][cmd_id:2LE][payload]
crc = crc16_ccitt(data)                                  # CRC-16/CCITT-FALSE, init=0xFFFF, poly=0x1021
sessions = parse_sessions(payload)                       # -> list[dict] with session_id, file_size, scene
```

### Constants

```python
SERVICE_UUID = "00001910-0000-1000-8000-00805f9b34fb"
TX_UUID = "00002bb0-0000-1000-8000-00805f9b34fb"  # device -> host (notify)
RX_UUID = "00002bb1-0000-1000-8000-00805f9b34fb"  # host -> device (write)
PROTO_COMMAND = 0x01
PROTO_VOICE = 0x02

# Key command IDs
CMD_HANDSHAKE = 1
CMD_TIME_SYNC = 4
CMD_GET_REC_SESSIONS = 26
CMD_SYNC_FILE_START = 28
CMD_SYNC_FILE_TAIL = 29
CMD_FILE_CHECKSUM = 116
CMD_FILE_CHECKSUM_RSP = 117
```

### Session Payload Format

`GET_REC_SESSIONS` response: `[4B unused][count:4LE]` then `count` x `[session_id:4LE][file_size:4LE][scene:2LE]`.

`session_id` is a Unix timestamp. `file_size` is raw Opus frames only (BLE transfer is ~11% larger due to 9B/frame headers).

---

## `plaude.ble.client`

High-level async BLE client wrapping `bleak.BleakClient`.

```python
from plaude.ble.client import PlaudClient

client = PlaudClient(address="YOUR-UUID", token="your_token", verbose=False)

await client.connect()                    # Connect + subscribe to TX notifications
ok = await client.handshake()             # Authenticate with binding token -> bool
await client.time_sync()                  # Sync Unix time to device
sessions = await client.get_sessions()    # -> list[dict] with session_id, file_size, scene
await client.disconnect()

# Scanning (static method)
devices = await PlaudClient.scan(timeout=15.0)  # -> list[dict] with name, address, rssi
```

### Voice Packet Capture

During file transfer, the client captures `proto_type=0x02` BLE notifications into `client.voice_data` (bytearray). The `transfer` module controls this via `client.receiving` flag.

---

## `plaude.ble.transfer`

Async file download using voice packet capture.

```python
from plaude.ble.transfer import download_file

raw_data = await download_file(client, session_id=1773294238, file_size=96640, verbose=True)
# Returns bytes (raw Opus with 9B/frame headers) or raises DownloadError
```

Protocol: sends `SYNC_FILE_START`, collects voice packets until `SYNC_FILE_TAIL`, verifies CRC (skips if device sends `0xFFFF`). Stall detection after 10s of no data.

---

## `plaude.audio.decoder`

Opus frame extraction and decoding. No async — pure CPU work.

```python
from plaude.audio.decoder import extract_opus_frames, decode_opus_frames, decode_opus_raw, save_wav, pcm_to_wav_bytes

# From raw BLE data (89-byte packets with 9-byte headers)
frames = extract_opus_frames(raw_data)      # -> list[bytes], each frame up to 80 bytes
pcm = decode_opus_frames(frames)            # -> bytes, 16-bit LE PCM at 16kHz mono
pcm = decode_opus_raw(raw_data)             # Shorthand: extract + decode

save_wav(pcm, "/path/to/output.wav")        # Write WAV file
wav_bytes = pcm_to_wav_bytes(pcm)           # In-memory WAV
```

### Audio Parameters

```python
SAMPLE_RATE = 16000      # Hz
CHANNELS = 1             # Mono
FRAME_DURATION_MS = 20   # Each Opus frame = 20ms
SAMPLES_PER_FRAME = 320  # 16000 * 20 / 1000
PACKET_SIZE = 89         # BLE packet: 9B header + 80B max frame
HEADER_SIZE = 9          # session_id(4) + offset(4) + frame_size(1)
```

### BLE Packet Structure

Each 89-byte packet: `[session_id:4LE][offset:4LE][frame_size:1][opus_frame:80]`. The `frame_size` byte gives actual frame length (often 80, but can be smaller). Frames with `frame_size=0` or `>80` are skipped. Corrupted frames produce silence (320 zero samples).

---

## `plaude.transcription.whisper`

Whisper transcription wrapper.

```python
from plaude.transcription.whisper import load_model, transcribe_with_model

model = load_model("medium")
result = transcribe_with_model(model, "/path/to/audio.wav", model_name="medium", language="en")
# Returns dict:
# {
#   "duration_seconds": 23.0,
#   "model": "medium",
#   "language": "en",
#   "segments": [{"start": 0.0, "end": 12.0, "text": "..."}],
#   "text": "full transcript..."
# }
```

Models are downloaded on first use. `medium` requires ~5GB RAM. Supports any audio format Whisper accepts (WAV, MP3, FLAC, etc.).

---

## `plaude.state`

JSON-based session tracking. Keys are stringified session IDs. Phase-aware with failure recovery.

```python
from plaude.state import (
    load_state, save_state,
    mark_downloaded, mark_decoded, mark_transcribed, mark_failed,
    needs_download, needs_decode, needs_transcription, is_complete,
)

state = load_state()                           # Default: ~/.local/share/openplaudit/state.json
state = load_state(Path("/custom/state.json"))
mark_downloaded(state, session_id=1773294238)  # Sets downloaded_at, clears failure
mark_decoded(state, session_id)                # Sets decoded_at, clears failure
mark_transcribed(state, session_id)            # Sets transcribed_at, clears failure
mark_failed(state, session_id, "reason")       # Sets failed_at + failure_reason
save_state(state)

needs_download(state, session_id)              # -> bool
needs_decode(state, session_id)                # -> bool
needs_transcription(state, session_id)         # -> bool
is_complete(state, session_id)                 # -> bool (all three phases done)
```

---

## `plaude.sync`

Orchestrator combining all modules.

```python
from plaude.sync import run_sync, transcribe_local

# Full BLE sync pipeline (async)
count = await run_sync(cfg, verbose=False, quiet=False)  # Returns count of newly synced recordings

# Local file transcription (sync)
result = transcribe_local("/path/to/file.wav", cfg, output_dir=None, quiet=False)
```

---

## `plaude.notify`

macOS notifications via osascript. Fails silently on non-macOS.

```python
from plaude.notify import notify

notify(title="OpenPlaudit", message="Recording transcribed", subtitle="2026-03-12 09:43")
```

---

## CLI Commands

```
plaude sync                    # Full pipeline: BLE download + decode + transcribe + notify
plaude list                    # List recordings on device (no download)
plaude scan [--timeout N]      # Scan for PLAUD BLE devices
plaude transcribe <file> [-o]  # Transcribe local audio file
plaude config init             # Create default config
plaude config show             # Print effective config
plaude config set <key> <val>  # Set config value (e.g. device.address)
```

Global flags: `-v`/`--verbose` (BLE debug), `-q`/`--quiet` (errors only).

# PLAUD Note BLE Protocol Reference

Reverse-engineered from Android SDK decompilation and validated against PLAUD Note hardware.

## GATT Service

Service UUID `0x1910`. Two characteristics:

| Char | UUID | Direction | Properties |
|------|------|-----------|------------|
| TX | `0x2BB0` | Device -> Host | Notify |
| RX | `0x2BB1` | Host -> Device | Write |

## Packet Format

```
[proto_type: uint8] [cmd_id: uint16 LE] [payload...]
```

proto_type: `0x01` = command, `0x02` = voice data, `0x03` = OTA.

## Command IDs

| ID | Name | Direction |
|----|------|-----------|
| 1 | HANDSHAKE | Both |
| 2 | GET_SSN | -> Device |
| 3 | GET_STATE | Both |
| 4 | TIME_SYNC | -> Device |
| 5 | DEPAIR | -> Device |
| 6 | GET_STORAGE | -> Device |
| 8 | COMMON_SETTINGS | Both |
| 9 | BATT_STATUS | <- Device |
| 10 | WIFI_OPEN | -> Device |
| 13 | WIFI_CLOSE | -> Device |
| 20 | RECORD_START | -> Device |
| 23 | RECORD_STOP | -> Device |
| 26 | GET_REC_SESSIONS | Both |
| 28 | SYNC_FILE_START | Both |
| 29 | SYNC_FILE_TAIL | <- Device |
| 112 | FILE_INFO_SYNC | Both |
| 113 | FILE_INFO_SYNC_RSP | <- Device |
| 114 | FILE_SYNC_DATA | Both |
| 116 | FILE_CHECKSUM | -> Device |
| 117 | FILE_CHECKSUM_RSP | <- Device |

Commands 1, 3, 9 work without authentication. All others require successful handshake.

## Handshake

**Request** (cmd 1):

```
[0x02]            handshake type
[0x00]            config value
[0x00]            extra byte (portVersion >= 3)
[token: 32 bytes] UTF-8 encoded hex string, zero-padded to 32 bytes
```

Token is the BLE binding token from the PLAUD cloud API, NOT the device serial number.

**Response:**

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | status: 0=OK, 1=TOKEN_NOT_MATCH, 2=RECORDING_NOW, 255=MODE_NOT_MATCH |
| 1 | 2 | portVersion (uint16 LE) |
| 3 | 1 | timezone |
| 4 | 1 | timezoneMin |
| 5 | 1 | audioChannel |
| 6 | 1 | supportWifi |

## Time Sync

**Request** (cmd 4): `[unix_timestamp: uint32 LE]`

## Session Listing

**Request** (cmd 26): empty payload.

**Response:**

```
[4 bytes unused]
[count: uint32 LE]
count * {
  [session_id: uint32 LE]  — Unix timestamp of recording start
  [file_size: uint32 LE]   — Raw Opus frame bytes (without BLE packet headers)
  [scene: uint16 LE]       — Recording mode (1 = standard)
}
```

## File Transfer (Voice Packet Capture)

1. Host sends `SYNC_FILE_START` (cmd 28): `[session_id: 4LE][offset: 4LE][file_size: 4LE]`
2. Device responds with cmd 28: `[session_id: 4LE][status: 1B]` (status 0 = OK)
3. Device streams `proto_type=0x02` notifications. Host strips proto byte, concatenates payloads.
4. Device sends `SYNC_FILE_TAIL` (cmd 29): `[session_id: 4LE][crc: 2LE]`
5. Host sends `FILE_CHECKSUM` (cmd 116): `[0x00][crc: 2LE]`
6. Device responds with `FILE_CHECKSUM_RSP` (cmd 117)

**CRC:** Device sends `0xFFFF` (initial value) for voice-mode transfers — skip verification. CRC algorithm is CRC-16/CCITT-FALSE (poly=0x1021, init=0xFFFF).

**Transfer speed:** ~20-30 KB/s over BLE. Stall detection after 10s of no data.

## Voice Data Packet Structure

The concatenated voice data (from proto_type=0x02 payloads) consists of 89-byte packets:

```
[session_id: 4 bytes LE]  — same for all packets in a file
[offset: 4 bytes LE]      — PCM byte offset of this frame
[frame_size: 1 byte]      — actual Opus frame length (typically 80)
[opus_frame: 80 bytes]    — Opus audio data, padded if frame_size < 80
```

Audio: Opus codec, 16kHz sample rate, mono, 20ms frame duration, 320 PCM samples/frame.

`file_size` from session listing = `frame_count * 80` (raw Opus bytes). Actual BLE transfer = `frame_count * 89` (with headers).

## WiFi Fast Transfer (Alternative)

WiFi uses an inverted WebSocket protocol — phone runs WS server on port 8081, device connects as client.

WiFi credentials: SSID = `"Plaud" + last4(serial)`, password = `last8(serial)`.

WiFi PDU: `[total_size:3LE][version:1][msg_type:2LE][json_size:2LE][json][binary]`

Message types: 0x0001 HANDSHAKE_REQ, 0x0002 HANDSHAKE_RSP, 0x0003 FILE_LIST_REQ, 0x0004 FILE_LIST_RSP, 0x0005 FILE_DOWNLOAD_REQ, 0x0006 FILE_DOWNLOAD_RSP, 0x0007 FILE_DELETE_REQ, 0x0008 FILE_DELETE_RSP, 0x0009 DISCONNECT_REQ.

## Device Info

* Chipset: Nordic Semiconductor (manufacturer ID 0x0059)
* BLE: 5.2
* Storage: 64GB
* Audio codec: Opus (16kHz mono, 80-byte frames, 20ms)
* Custom service UUID: 0x1910
* Standard services: Battery (0x180F), Device Info (0x180A), Nordic DFU (0xFE59)

## Token Extraction

The binding token can be extracted from an unencrypted iPhone backup using `scripts/extract_token_from_backup.py`. It is a 32-character hex string stored by the PLAUD Flutter app. Alternative: factory reset and re-bind.

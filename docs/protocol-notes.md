# PLAUD Note Protocol Notes

## Device Overview

- **Chipset**: Nordic Semiconductor (manufacturer ID 0x0059)
- **BLE**: 5.2
- **Storage**: 64GB
- **Audio**: Records Opus internally (16kHz mono, 80-byte frames, 20ms duration)
- **App**: Flutter-based iOS app, Android demo SDK available

## BLE GATT Services

### Custom PLAUD Service: `0x1910`
| Characteristic | UUID | Properties | Purpose |
|---|---|---|---|
| TX (device->host) | `0x2BB0` | Notify | Responses and voice data |
| RX (host->device) | `0x2BB1` | Write | Commands |

### Standard Services
| Service | UUID | Notes |
|---|---|---|
| Generic Access | `0x1800` | Device name, appearance |
| Generic Attribute | `0x1801` | Service changed |
| Battery | `0x180F` | Battery level (characteristic `0x2A19`) |
| Device Info | `0x180A` | Model, firmware, serial, etc. |
| Nordic DFU | `0xFE59` | Firmware update service |

## BLE Protocol

### Packet Format
```
[proto_type: uint8][cmd_id: uint16 LE][payload...]
```

| proto_type | Meaning |
|---|---|
| 0x01 | Command |
| 0x02 | Voice data |
| 0x03 | OTA update |

### Command IDs
| ID | Name | Direction | Payload |
|---|---|---|---|
| 1 | HANDSHAKE | Both | See handshake section |
| 2 | GET_SSN | -> Device | |
| 3 | GET_STATE | Both | Status, recording state |
| 4 | TIME_SYNC | -> Device | uint32 LE seconds |
| 5 | DEPAIR | -> Device | |
| 6 | GET_STORAGE | -> Device | |
| 7 | RESET_PASSWORD | -> Device | |
| 8 | COMMON_SETTINGS | Both | Read/write device settings |
| 9 | BATT_STATUS | <- Device | Battery level |
| 10 | WIFI_OPEN | -> Device | Activate WiFi hotspot |
| 11 | GET_DATA | -> Device | |
| 12 | CLEAR_DATA | -> Device | |
| 13 | WIFI_CLOSE | -> Device | Deactivate WiFi |
| 14 | SET_WIFI_SSID | -> Device | |
| 15 | GET_WIFI_SSID | -> Device | |
| 17 | SET_WS_PROFILE | -> Device | |
| 18 | TEST_WS | -> Device | |
| 20 | RECORD_START | -> Device | scene parameter |
| 23 | RECORD_STOP | -> Device | scene parameter |
| 26 | GET_REC_SESSIONS | Both | Recording file list |
| 28 | SYNC_FILE_START | Both | Begin file transfer |
| 112 | FILE_INFO_SYNC | Both | File metadata |
| 114 | FILE_SYNC_DATA | Both | File data chunks |
| 116 | FILE_CHECKSUM | Both | CRC verification |

### Handshake Protocol

#### Request Format
```
[0x01][0x01 0x00]          — proto=CMD, cmd=HANDSHAKE
[0x02]                     — handshake type (always 2)
[0x00]                     — config value (always 0)
[0x00]                     — extra byte (only if portVersion >= 3)
[token: 16 or 32 bytes]   — token, zero-padded (16 if portVer < 9, 32 if >= 9)
```

#### Response Format (HandShakeRsp)
| Offset | Size | Field | Notes |
|---|---|---|---|
| 3 | 1 | status | 0=success, 1=TOKEN_NOT_MATCH, 2=RECORDING_NOW, 3=USER_REFUSE, 4=SSN_FAILED, 255=MODE_NOT_MATCH |
| 4 | 2 | portVersion | uint16 LE, protocol version |
| 6 | 1 | timezone | |
| 7 | 1 | timezoneMin | |
| 8 | 1 | audioChannel | |
| 9 | 1 | supportWifi | 1=yes |
| 10 | 1 | noNsAgc | |
| 11 | 1 | isOggAudio | |

#### Token Authentication

**The BLE handshake token is NOT the device serial number** for a bound device. The demo SDK passes serialNumber as the token, but this only works for unbound/demo devices. A production-bound device rejects the serial with status=1 (TOKEN_NOT_MATCH).

The production iOS app (Flutter) obtains a different token during initial device binding:
1. App calls `POST /api/oauth/sdk-token` to get an SDK authentication token
2. App calls `POST /api/sdk/api-token` to get an API token
3. App calls `POST /api/devices/bind` with device serial
4. The binding process sets a token on the device
5. Subsequent BLE handshakes require this binding token

**How to obtain the token:**
- Extract from iPhone backup (see Token Extraction guide in docs)
- Obtain from PLAUD API using correct account credentials
- Factory reset the device and re-bind with known token

### Commands That Work Without Authentication
| Command | Response |
|---|---|
| HANDSHAKE (cmd=1) | Returns status (success/fail) + port version |
| BATT_STATUS (cmd=9) | Battery level |
| GET_STATE (cmd=3) | Device state |

All other commands are silently ignored until a successful handshake.

## WiFi Fast Transfer Protocol

WiFi transfer uses an **inverted WebSocket protocol**: the phone runs a WebSocket server on port 8081, and the device connects as a client.

### WiFi Credentials
- **SSID**: `"Plaud" + last4(serial)`
- **Password**: `last8(serial)`

### WiFi PDU Format
```
[total_size: 3 bytes LE]  — 24-bit total PDU size
[version: 1 byte]         — always 0x01
[msg_type: 2 bytes LE]    — message type
[json_size: 2 bytes LE]   — JSON payload length
[json: N bytes]           — JSON payload
[binary: remaining]       — binary data (optional)
```

### WiFi Message Types
| Type | Name | Direction |
|---|---|---|
| 0x0001 | HANDSHAKE_REQ | Device->Phone |
| 0x0002 | HANDSHAKE_RSP | Phone->Device |
| 0x0003 | FILE_LIST_REQ | Phone->Device |
| 0x0004 | FILE_LIST_RSP | Device->Phone |
| 0x0005 | FILE_DOWNLOAD_REQ | Phone->Device |
| 0x0006 | FILE_DOWNLOAD_RSP | Device->Phone |
| 0x0007 | FILE_DELETE_REQ | Phone->Device |
| 0x0008 | FILE_DELETE_RSP | Device->Phone |
| 0x0009 | DISCONNECT_REQ | Phone->Device |

### WiFi File List Entry Format
Each file entry is 10 bytes:
```
[session_id: 4 bytes LE]  — uint32
[file_size: 4 bytes LE]   — uint32
[scene: 2 bytes LE]       — uint16
```

## Cloud API

### Servers
| Server | Region |
|---|---|
| `https://api.plaud.ai` | Global (US West) |
| `https://api-euc1.plaud.ai` | EU (Frankfurt) |

### Authentication
All API calls use `Authorization: Bearer <jwt_token>` header.

### SDK API Endpoints (from decompiled AAR)
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/oauth/sdk-token` | Get SDK token |
| POST | `/api/sdk/api-token` | Get API token |
| GET | `/api/sdk/config` | Get feature permissions |
| POST | `/api/devices/bind` | Bind device to account |
| POST | `/api/devices/unbind` | Unbind device |
| GET | `/api/files/list?path=/` | List files |
| POST | `/api/files/upload-s3/generate-presigned-urls` | Get upload URLs |
| POST | `/api/files/upload-s3/complete-upload` | Complete upload |
| POST | `/api/workflows/submit` | Submit AI workflow |
| GET | `/api/workflows/{id}/status` | Workflow status |
| GET | `/api/workflows/{id}/result` | Workflow result |
| GET | `/api/sdk/latest-version` | Firmware version |

## Error Codes

### BLE Handshake Status
| Code | Name | Description |
|---|---|---|
| 0 | SUCCESS | Handshake accepted |
| 1 | TOKEN_NOT_MATCH | Wrong binding token |
| 2 | RECORDING_NOW | Device is recording, can't pair |
| 3 | USER_REFUSE | User manually refused |
| 4 | SSN_FAILED | Serial number verification failed |
| 255 | MODE_NOT_MATCH | Device not in connection mode |

### SDK Error Codes
| Code | Name |
|---|---|
| -8 | SYNC_TIME_FAIL |
| -7 | SN_NOT_MATCH |
| -6 | APP_KEY_NOT_MATCH |
| -5 | HANDSHAKE_FAIL |
| -4 | HANDSHAKE_CMD_SEND_FAIL |
| -3 | UUID_IS_EMPTY |
| -2 | TIME_OUT |
| -1 | BLE_CONNECT_FAILED |

## Device Settings (BLE command 8)
| Code | Setting |
|---|---|
| 1 | BACK_LIGHT_TIME |
| 2 | BACK_LIGHT_BRIGHTNESS |
| 3 | LANGUAGE |
| 4 | AUTO_DELETE_RECORD_FILE |
| 15 | ENABLE_VAD |
| 16 | REC_SCENE |
| 17 | REC_MODE |
| 18 | VAD_SENSITIVITY |
| 19 | VPU_GAIN |
| 20 | MIC_GAIN |
| 21 | WIFI_CHANNEL |
| 23 | AUTO_POWER_OFF |
| 24 | SAVE_RAW_FILE |

## Key Findings

1. **Device advertises with Nordic manufacturer data** (0x0059), NOT necessarily as "PLAUD" or with service UUID 0x1910 in the advertisement
2. **BLE handshake requires cloud-issued binding token** — serial number is rejected (status=1) on production-bound devices
3. **Only 3 BLE commands work without auth**: HANDSHAKE, BATT_STATUS, GET_STATE
4. **PLAUD iOS app is Flutter-based** — HTTP traffic bypasses iOS system proxy settings, making mitmproxy interception ineffective without VPN-level capture
5. **WiFi Fast Transfer is inverted** — phone acts as WebSocket server (port 8081), device connects as client
6. **`sendHttpTokenToDevice`**: After BLE handshake, the SDK sends the `apiToken` to the device over BLE (cmd 112 FILE_INFO_SYNC) — this is for cloud upload, not for authentication
## NB100 v20 — verified notes (firmware 2.2)

These are the byte-level findings that make `plaude sync` work. They were
reverse-engineered live against a PLAUD Note model **NB100** (serial
`88831807738023788B`, firmware 2.2) and verified end-to-end: auth, file list,
download to WAV, `afinfo`/`afplay`.

### Connection & auth (portVersion >= 20, project 888)

1. **Service/characteristics**
   - Service: `0x1910`
   - RX (host → device): `0x2BB1` (write)
   - TX (device → host): `0x2BB0` (notify)

2. **RSA pre-handshake** — required before the main handshake:
   - Send SN signature in chunks: opcode `0xFE20`, frame
     `[opcode:2][count:1][index:1][chunk:100B]`.
   - Wait for `0xFE11` confirm (`11 fe 00`).
   - Send user RSA public key in chunks: opcode `0xFE12` (same framing).
   - Device returns `3x 0xFE12` chunks: `[fe 12][count:1][index:1][data...]`.
     Strip the 4-byte header per chunk, concatenate, and RSA-PKCS1v15-decrypt
     with the user private key. Result: `[key:32][nonce:12][ad:12][ChaCha20
     ciphertext]`. Decrypt the ciphertext with those key/nonce/ad and verify it
     is `b"PLAUD.AI"`.

3. **ChaCha20-Poly1305 (IETF) session**:
   - `send_counter` starts at 1 and is incremented BEFORE each encryption, so
     the first encrypted packet uses counter=2.
   - Plaintext = `[counter LE:4] + command_frame`. Counter is INSIDE the
     encryption.
   - On receive: decrypt, then strip the first 4 bytes (the counter).

4. **Main handshake** (encrypted): `[0x01][cmd 0x01 LE] + MTU_INDICATOR
   (02 00) + portVersion byte (20) + bindToken (32 bytes, zero-padded)`.
   - Response status is at **frame[3]** (payload[0]); portVersion at frame[4:6].
   - status 0 = SUCCESS.

5. **Two-handshake (v20+)**: after the main handshake, the device pushes its
   SSN as cmd `0x02` (null-terminated string at frame[3]). The host replies
   with the same handshake frame plus the 8-byte zero-padded SSN.

### Commands

| cmd | name | payload |
|-----|------|---------|
| 0x01 | HANDSHAKE | token/SSN |
| 0x02 | GET_SSN | — |
| 0x03 | GET_STATE | — (resp: state=payload[0], 1=idle 3=recording) |
| 0x09 | BATT_STATUS | (resp: payload = `[charging:1][level:1]`) |
| 0x04 | TIME_SYNC | `[unix:4]` |
| 0x05 | RECORD_SWITCH | `[0/1]` |
| 0x1A | GET_REC_SESSIONS | `[ts:4][ts:4][flag:1]` |
| 0x1C | SYNC_FILE_HEAD | `[sessionId:4][startPos:4][fileSize:4]` |
| 0x1D | SYNC_FILE_TAIL | (device pushes as EOF signal) |
| 0x1E | SYNC_FILE_STOP | `[sessionId:4]` |

> **cmd 0x14 is the RECORD command** (`[1][scene]` start / `[0][1]` stop). It is
> NEVER used for file sync. There is NO "prepare" command — do not send 0x14
> during a download or the device starts recording (red light).

### File listing (GET_REC_SESSIONS 0x1A)

Request `[ts:4][ts:4][flag:1]`. Response:
`[type:1][cmd:2][ts:4][total:2 LE][entries...]` where entries (portVersion>=20)
are **10 bytes each**: `[session_id:4][file_size:4][file_type:1][file_index:1]`,
starting at frame offset 11 (payload offset 8).

The device returns no response (or total=0) **while recording** (state=3); it
answers when idle (state=1). Session IDs are unix timestamps.

### File download

```
-> cmd 0x1C SYNC_FILE_HEAD [sessionId:4][startPos:4][fileSize:4]
<- cmd 0x1C response   (confirm)
<- data packets  (type 0x02) until EOF
<- cmd 0x1D SYNC_FILE_TAIL  (EOF)
-> cmd 0x1E SYNC_FILE_STOP [sessionId:4]
```

Data packet layout: `[type:1][session_id:4][offset:4][chunk_len:1][data:chunk_len]`.
- **chunk_len is a single byte** (0x50 = 80 bytes). Reading it as 2 bytes
  mis-slices data and produces "offset mismatch: expected N, got N+79".
- The offset advances by exactly `chunk_len` each packet. There is **no**
  length-16 field.
- EOF is signalled by `SYNC_FILE_TAIL` (cmd 0x1D) or a data packet with offset
  `0xFFFFFFFF`.

`startPos` is honored: sending a nonzero startPosition resumes from a previous
offset (useful after a BLE drop).

### Device behavior notes

- The device sleeps aggressively; it must be woken (single tap on the Record
  button) before it advertises, and it drops connections mid-large-transfer.
- Resume: reconnect → handshake → re-issue SYNC_FILE_HEAD with the last offset.
- `plaude sync` writes partials to the raw path so a killed run is resumable.
- There is **no BLE delete-file command** in the SDK (checked: cmd 120/123/124
  are not per-file deletes). Deletion is done in the official app.


## PLAUD.AI container (E2EE recordings)

Header, little-endian:

```
[0x000:8]   "PLAUD.AI"          [0x008:2] version (=1)
[0x00A:2]   headerSize (=512)   [0x030:2] fileType   [0x032:2] channel
[0x084:12]  ChaCha20 nonce      [0x090:4] segment (=80)
[0x100:256] keyCipher (RSA-2048 PKCS1v15)   [0x200:...] encrypted audio
```

RSA-decrypt keyCipher with the user private key; audio decrypts in `segment`
byte chunks, each with a fresh ChaCha20 keystream (counter 0, header nonce), not
one continuous stream. The plaintext is bare 80-byte Opus frames.

## Freeing a recording

`SYNC_FILE_STOP` after a complete transfer is what makes the device drop the
recording — verified on hardware: session count 7 to 6, and STOP alone (no
transfer) takes 6 to 5. There is no BLE delete command; the 0x1A delete-shaped
payload only filters the list.

## Ogg/Opus muxing

Bare Opus frames need an Ogg container before a hosted decoder accepts them.
Granule positions are in 48kHz samples regardless of source rate: one 20ms
frame advances the granule by 960. Using the source rate makes a 1505s file
report as 501s while still decoding. A malformed packet is dropped before
muxing: one junk frame in 1728 makes a decoder reject the whole recording.

## Repetition loops

Hosted Whisper runs at temperature 0.0 and exposes none of OpenAI's fallback
controls, so a degenerate window repeats forever. Retrying at 0.2/0.4/0.6/0.8
with `repetition_penalty` 1.1 clears it: measured 25.4% looped text to 0% on
one chunk.

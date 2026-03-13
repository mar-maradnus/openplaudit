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

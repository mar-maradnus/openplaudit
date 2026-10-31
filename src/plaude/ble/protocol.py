"""BLE protocol primitives — packet building, CRC, command constants.

portVersion>=20 devices (NB100 etc.) use ChaCha20-Poly1305 encryption with a
RSA pre-handshake. All command frames sent after the handshake are wrapped in
ChaCha20; every incoming notification is unwrapped the same way before the
[type][cmd][payload] frame is inspected. See PlaudCrypto (opendict) for the
upstream reference of this scheme.
"""

import struct

# PLAUD BLE UUIDs
SERVICE_UUID = "00001910-0000-1000-8000-00805f9b34fb"
TX_UUID = "00002bb0-0000-1000-8000-00805f9b34fb"  # device -> host (notify)
RX_UUID = "00002bb1-0000-1000-8000-00805f9b34fb"  # host -> device (write)

# Protocol types
PROTO_COMMAND = 0x01
PROTO_VOICE = 0x02

CMD_HANDSHAKE = 0x01
CMD_GET_SSN = 0x02
CMD_GET_STATE = 0x03
CMD_TIME_SYNC = 0x04
CMD_RECORD_SWITCH = 0x05
CMD_GET_DEVICE_INFO = 0x09
CMD_GET_FILE_LIST = 0x0A
CMD_GET_STORAGE = 0x0D
CMD_GET_REC_SESSIONS = 0x1A  # real file/session list (APK ii/v), NOT 0x0A
CMD_RECORD = 0x14
CMD_SYNC_FILE_HEAD = 0x1C
CMD_SYNC_FILE_TAIL = 0x1D
CMD_SYNC_FILE_STOP = 0x1E
CMD_FILE_CHECKSUM = 0x74      # 116
CMD_FILE_CHECKSUM_RSP = 0x75  # 117

CMD_PRE_HANDSHAKE_NEW = 0xFE20
CMD_PRE_HANDSHAKE_CNF = 0xFE11
CMD_SEND_RSA_PUBKEY = 0xFE12

PRE_HANDSHAKE_CMDS = {
    CMD_PRE_HANDSHAKE_NEW,
    CMD_PRE_HANDSHAKE_CNF,
    CMD_SEND_RSA_PUBKEY,
}

PACKET_FILE_DATA = 0x02  # session_id(4) offset(4) chunk_len(1) data...
PACKET_FILE_DATA_ALT = 0x03
PACKET_FILE_DATA_ALT2 = 0x05

CMD_NAMES = {
    0x01: "HANDSHAKE", 0x02: "GET_SSN", 0x03: "GET_STATE", 0x04: "TIME_SYNC",
    0x09: "GET_DEVICE_INFO", 0x0A: "GET_FILE_LIST", 0x0D: "GET_STORAGE",
    0x14: "RECORD", 0x15: "FILE_SYNC_START", 0x16: "FILE_SYNC_STOP",
    0x17: "FILE_SYNC_CONFIG", 0x18: "DELETE_FILE",
    0x1A: "GET_REC_SESSIONS",
    0x1C: "SYNC_FILE_HEAD", 0x1D: "SYNC_FILE_TAIL", 0x1E: "SYNC_FILE_STOP",
    0x74: "FILE_CHECKSUM", 0x75: "FILE_CHECKSUM_RSP",
    0xFE20: "PRE_HANDSHAKE_NEW", 0xFE11: "PRE_HANDSHAKE_CNF",
    0xFE12: "SEND_RSA_PUBKEY",
}

HANDSHAKE_STATUS = {
    0: "SUCCESS",
    1: "TOKEN_NOT_MATCH",
    2: "RECORDING_NOW",
    3: "USER_REFUSE",
    4: "SSN_FAILED",
    255: "MODE_NOT_MATCH",
}

CHUNK_SIZE = 100

MTU_INDICATOR = bytes([0x02, 0x00])

def build_cmd(cmd_id: int, payload: bytes = b"") -> bytes:
    """Build a BLE command packet: [proto_type:1][cmd_id:2LE][payload]."""
    return struct.pack("<BH", PROTO_COMMAND, cmd_id) + payload

def build_pre_handshake_chunk(cmd_id: int, total: int, index: int, data: bytes) -> bytes:
    """Build a pre-handshake chunk: [cmd_id:2LE][total:1][index:1][data].

    Only used during the pre-handshake phase — never encrypted.
    """
    return struct.pack("<HBB", cmd_id, total, index) + data

def build_handshake_packet(token: bytes, port_version: int) -> bytes:
    """Build the handshake command payload: MTU + portVersion + token."""
    return build_cmd(
        CMD_HANDSHAKE,
        MTU_INDICATOR + bytes([port_version & 0xFF]) + token[:32].ljust(32, b"\x00"),
    )

def build_two_handshake_packet(token: bytes, port_version: int, ssn: str) -> bytes:
    """Two-handshake for v20+: MTU + portVersion + token + 8-byte SSN."""
    ssn_bytes = ssn.encode()[:8].ljust(8, b"\x00")
    return build_cmd(
        CMD_HANDSHAKE,
        MTU_INDICATOR + bytes([port_version & 0xFF]) + token[:32].ljust(32, b"\x00") + ssn_bytes,
    )

def build_sync_time_packet(now: int | None = None, tz_offset_hours: int | None = None) -> bytes:
    """Sync-time payload: [unix_ts:4LE][tz_offset_hours:1]."""
    if now is None:
        import time as _time
        now = int(_time.time())
    if tz_offset_hours is None:
        import datetime as _dt
        tz_offset_hours = -(_dt.datetime.now().astimezone().utcoffset() or _dt.timedelta(0)).total_seconds() // 3600
        tz_offset_hours = int(tz_offset_hours)
    return build_cmd(CMD_TIME_SYNC, struct.pack("<Ib", now, tz_offset_hours))

def parse_handshake_response(frame: bytes) -> dict:
    """Parse a (decrypted) handshake response frame.

    Frame: [type:1][cmd:2LE][status:1][portVersion:2LE][tz:1]...version bytes
    """
    out = {"status": -1, "portVersion": 0, "raw": frame}
    if len(frame) >= 4:
        out["status"] = frame[3]
    if len(frame) >= 6:
        out["portVersion"] = struct.unpack("<H", frame[4:6])[0]
    if len(frame) >= 4:
        out["firmware"] = frame[3:].hex()
    return out

def parse_ssn_response(frame: bytes) -> str:
    """SSN is a null-terminated ASCII string starting at frame[3]."""
    start = 3
    end = start
    while end < min(len(frame), 58) and frame[end] != 0:
        end += 1
    return frame[start:end].decode("ascii", errors="replace")

def parse_file_data_packet(frame: bytes) -> dict:
    """Parse a file data packet (type 0x02) for portVersion >= 7.

    Layout: [type:1][session_id:4][offset:4][chunk_len:1][data:chunk_len]

    chunk_len is a single byte (0x50 = 80 for data chunks). The data follows
    the 10-byte header. A 2-byte length read mis-sliced data to frame[11:],
    producing "offset mismatch: expected 79, got 80"; the correct slice is
    frame[10:10+chunk_len].
    """
    if len(frame) < 10:
        return {"session_id": 0, "offset": 0, "chunk_len": 0, "data": b""}
    chunk_len = frame[9]
    return {
        "session_id": struct.unpack("<I", frame[1:5])[0],
        "offset": struct.unpack("<I", frame[5:9])[0],
        "chunk_len": chunk_len,
        "data": frame[10:10 + chunk_len],
    }

def parse_tail_crc(frame: bytes) -> int | None:
    """Extract the device CRC from a SYNC_FILE_TAIL (cmd 0x1D) frame.

    Layout: [type:1][cmd:2LE][session_id:4][crc:2LE]. Returns None if the frame
    is too short, or 0xFFFF (which the device uses to mean "skip verification").
    """
    if len(frame) < 9:
        return None
    return struct.unpack("<H", frame[7:9])[0]

def crc16_ccitt(data: bytes) -> int:
    """CRC-16/CCITT-FALSE used by PLAUD for file transfer verification."""
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
            crc &= 0xFFFF
    return crc
def parse_sessions(payload: bytes) -> list[dict]:
    """Parse GET_REC_SESSIONS response into a list of session dicts.

    Payload format:
        [4 bytes unknown][count:4LE]
        Then `count` entries of: [session_id:4LE][file_size:4LE][scene:2LE]
    """
    if len(payload) < 8:
        return []

    count = struct.unpack("<I", payload[4:8])[0]
    sessions = []
    offset = 8
    for _ in range(count):
        if offset + 10 > len(payload):
            break
        session_id = struct.unpack("<I", payload[offset:offset + 4])[0]
        file_size = struct.unpack("<I", payload[offset + 4:offset + 8])[0]
        scene = struct.unpack("<H", payload[offset + 8:offset + 10])[0]
        sessions.append({
            "session_id": session_id,
            "file_size": file_size,
            "scene": scene,
        })
        offset += 10
    return sessions

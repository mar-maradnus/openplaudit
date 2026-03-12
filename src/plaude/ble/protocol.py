"""BLE protocol primitives — packet building, CRC, command constants."""

import struct

# PLAUD BLE UUIDs
SERVICE_UUID = "00001910-0000-1000-8000-00805f9b34fb"
TX_UUID = "00002bb0-0000-1000-8000-00805f9b34fb"  # device -> host (notify)
RX_UUID = "00002bb1-0000-1000-8000-00805f9b34fb"  # host -> device (write)

# Protocol types
PROTO_COMMAND = 0x01
PROTO_VOICE = 0x02

# Command IDs
CMD_HANDSHAKE = 1
CMD_GET_STATE = 3
CMD_TIME_SYNC = 4
CMD_GET_STORAGE = 6
CMD_GET_REC_SESSIONS = 26
CMD_SYNC_FILE_START = 28
CMD_SYNC_FILE_TAIL = 29
CMD_FILE_INFO_SYNC = 112
CMD_FILE_INFO_SYNC_RSP = 113
CMD_FILE_SYNC_DATA = 114
CMD_FILE_CHECKSUM = 116
CMD_FILE_CHECKSUM_RSP = 117

CMD_NAMES = {
    1: "HANDSHAKE", 3: "GET_STATE", 4: "TIME_SYNC", 6: "GET_STORAGE",
    26: "GET_REC_SESSIONS", 28: "SYNC_FILE_HEAD", 29: "SYNC_FILE_TAIL",
    112: "FILE_INFO_SYNC", 113: "FILE_INFO_SYNC_RSP",
    114: "FILE_SYNC_DATA", 116: "FILE_CHECKSUM", 117: "FILE_CHECKSUM_RSP",
}


def build_cmd(cmd_id: int, payload: bytes = b"") -> bytes:
    """Build a BLE command packet: [proto_type:1][cmd_id:2LE][payload]."""
    return struct.pack("<BH", PROTO_COMMAND, cmd_id) + payload


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

"""Tests for BLE protocol primitives — packet building, CRC, session parsing."""

from plaude.ble.protocol import build_cmd, crc16_ccitt, parse_sessions, PROTO_COMMAND
import struct


class TestBuildCmd:
    def test_builds_correct_header(self):
        pkt = build_cmd(1)
        assert pkt[0] == PROTO_COMMAND
        assert struct.unpack("<H", pkt[1:3])[0] == 1
        assert len(pkt) == 3

    def test_appends_payload(self):
        payload = b"\xaa\xbb\xcc"
        pkt = build_cmd(26, payload)
        assert pkt[0] == PROTO_COMMAND
        assert struct.unpack("<H", pkt[1:3])[0] == 26
        assert pkt[3:] == payload

    def test_handshake_packet_structure(self):
        token = "00112233445566778899aabbccddeeff"
        token_bytes = token.encode("utf-8")[:32].ljust(32, b"\x00")
        payload = bytes([0x02, 0x00, 0x00]) + token_bytes
        pkt = build_cmd(1, payload)
        assert len(pkt) == 3 + 3 + 32  # header + handshake header + token


class TestCrc16Ccitt:
    def test_empty_data(self):
        assert crc16_ccitt(b"") == 0xFFFF

    def test_known_value(self):
        # "123456789" should yield 0x29B1 for CRC-16/CCITT-FALSE
        assert crc16_ccitt(b"123456789") == 0x29B1

    def test_deterministic(self):
        data = b"\x00\x01\x02\x03" * 100
        assert crc16_ccitt(data) == crc16_ccitt(data)

    def test_different_data_different_crc(self):
        assert crc16_ccitt(b"\x00") != crc16_ccitt(b"\x01")


class TestParseSessions:
    def test_empty_payload(self):
        assert parse_sessions(b"") == []
        assert parse_sessions(b"\x00" * 4) == []

    def test_zero_count(self):
        payload = b"\x00" * 4 + struct.pack("<I", 0)
        assert parse_sessions(payload) == []

    def test_single_session(self):
        session_id = 1741747438  # 2025-03-12 09:43:58
        file_size = 96720
        scene = 1
        payload = b"\x00" * 4 + struct.pack("<I", 1)
        payload += struct.pack("<IIH", session_id, file_size, scene)
        sessions = parse_sessions(payload)
        assert len(sessions) == 1
        assert sessions[0]["session_id"] == session_id
        assert sessions[0]["file_size"] == file_size
        assert sessions[0]["scene"] == scene

    def test_multiple_sessions(self):
        payload = b"\x00" * 4 + struct.pack("<I", 3)
        for i in range(3):
            payload += struct.pack("<IIH", 1000 + i, 5000 * (i + 1), i)
        sessions = parse_sessions(payload)
        assert len(sessions) == 3
        assert sessions[2]["session_id"] == 1002
        assert sessions[2]["file_size"] == 15000

    def test_truncated_payload_returns_partial(self):
        payload = b"\x00" * 4 + struct.pack("<I", 2)
        payload += struct.pack("<IIH", 1000, 5000, 0)
        # Only add 5 bytes of the second entry (truncated)
        payload += b"\x00" * 5
        sessions = parse_sessions(payload)
        assert len(sessions) == 1

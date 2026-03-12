"""Tests for Opus frame extraction from raw BLE packets."""

import struct

from plaude.audio.decoder import extract_opus_frames, PACKET_SIZE, HEADER_SIZE


def _make_packet(session_id: int, offset: int, frame_size: int, frame_data: bytes = b"") -> bytes:
    """Build a fake 89-byte PLAUD packet."""
    header = struct.pack("<II", session_id, offset) + bytes([frame_size])
    data = frame_data[:frame_size].ljust(PACKET_SIZE - HEADER_SIZE, b"\x00")
    return header + data


class TestExtractOpusFrames:
    def test_empty_data(self):
        assert extract_opus_frames(b"") == []

    def test_single_packet(self):
        frame = bytes(range(80))
        pkt = _make_packet(1000, 0, 80, frame)
        assert len(pkt) == PACKET_SIZE
        frames = extract_opus_frames(pkt)
        assert len(frames) == 1
        assert frames[0] == frame

    def test_multiple_packets(self):
        raw = b""
        for i in range(5):
            raw += _make_packet(1000, i * 80, 80, bytes([i] * 80))
        frames = extract_opus_frames(raw)
        assert len(frames) == 5
        assert frames[3] == bytes([3] * 80)

    def test_variable_frame_sizes(self):
        raw = _make_packet(1000, 0, 60, bytes([0xAA] * 60))
        raw += _make_packet(1000, 60, 40, bytes([0xBB] * 40))
        frames = extract_opus_frames(raw)
        assert len(frames) == 2
        assert len(frames[0]) == 60
        assert len(frames[1]) == 40

    def test_zero_frame_size_skipped(self):
        raw = _make_packet(1000, 0, 0)
        raw += _make_packet(1000, 80, 80, bytes([0xFF] * 80))
        frames = extract_opus_frames(raw)
        assert len(frames) == 1

    def test_frame_size_exceeding_80_skipped(self):
        header = struct.pack("<II", 1000, 0) + bytes([81])
        pkt = header + b"\x00" * (PACKET_SIZE - HEADER_SIZE)
        frames = extract_opus_frames(pkt)
        assert len(frames) == 0

    def test_real_file_packet_count(self):
        """A 96720-byte raw file should contain 96720/89 = 1086 packets (with remainder)."""
        file_size = 96720
        expected_full_packets = file_size // PACKET_SIZE  # 1086
        raw = b"\x00" * file_size
        # Frame size byte at offset 8 in each packet is 0, so no frames extracted
        # This just tests we don't crash on real-sized data
        frames = extract_opus_frames(raw)
        assert isinstance(frames, list)

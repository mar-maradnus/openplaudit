"""Tests for BLE download gap recovery in PlaudClient.download_file.

The device streams ~1 Mbps over BLE; notifications can be dropped under load,
which causes a hard "offset mismatch" failure on large files. The download
detects an 80-byte gap (a dropped frame) and re-issues SYNC_FILE_HEAD from
the gap offset to recover.
"""

import asyncio
import struct
from unittest.mock import AsyncMock

import pytest

from plaude.ble.client import PlaudClient
from plaude.ble.protocol import (
    CMD_SYNC_FILE_HEAD,
    CMD_SYNC_FILE_TAIL,
    PROTO_COMMAND,
)

def _data_packet(session_id: int, offset: int, data: bytes) -> bytes:
    """Build a file-data frame: [type:1][session:4][offset:4][len:1][data]."""
    return bytes([0x02]) + struct.pack("<II", session_id, offset) + bytes([len(data)]) + data

def _eof_packet(session_id: int) -> bytes:
    return bytes([0x02]) + struct.pack("<II", session_id, 0xFFFFFFFF) + b"\x00"

def _tail_packet() -> bytes:
    return bytes([PROTO_COMMAND]) + struct.pack("<H", CMD_SYNC_FILE_TAIL) + b"\x00" * 4

def _make_client(frames: list[bytes]) -> tuple[PlaudClient, dict]:
    """A PlaudClient with mocked BLE that streams `frames` per SYNC_FILE_HEAD.

    Each head re-streams all frames at/after the requested offset then EOF,
    modeling the device's resend-from-offset behavior.
    """
    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "token"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None  # frames are pre-decrypted plaintext
    client._get_queue = PlaudClient._get_queue.__get__(client)

    calls = {"n_head": 0}

    async def fake_wait_response(cmd_id, timeout=5.0):
        if cmd_id == CMD_SYNC_FILE_HEAD:
            return b"\x00" * 5
        if cmd_id == CMD_SYNC_FILE_TAIL:
            for _ in range(2000):
                await asyncio.sleep(0.005)
                if client._eof_seen:
                    break
            return _tail_packet()
        return None

    async def fake_send(cmd_id, payload=b""):
        if cmd_id == CMD_SYNC_FILE_HEAD:
            calls["n_head"] += 1
            req_offset = struct.unpack_from("<I", payload, 4)[0] if len(payload) >= 8 else 0
            emitted = set()
            if req_offset > 0 and not any(
                struct.unpack_from("<I", f, 5)[0] == req_offset for f in frames
            ):
                gap_frame = _data_packet(100, req_offset, bytes([0x42]) * 80)
                client._on_notify(None, bytearray(gap_frame))
                emitted.add(req_offset)
            for f in frames:
                pkt_off = struct.unpack_from("<I", f, 5)[0] if len(f) >= 9 else 0
                if pkt_off == 0xFFFFFFFF or (pkt_off >= req_offset and pkt_off not in emitted):
                    client._on_notify(None, bytearray(f))

    client.wait_response = AsyncMock(side_effect=fake_wait_response)
    client.send = AsyncMock(side_effect=fake_send)
    client.client = AsyncMock()
    client.client.write_gatt_char = AsyncMock()
    client._eof_seen = False
    return client, calls

@pytest.mark.asyncio
async def test_download_no_gap():
    """Normal stream (no drops) completes and returns all bytes."""
    frames = [
        _data_packet(100, 0, b"A" * 80),
        _data_packet(100, 80, b"B" * 80),
        _data_packet(100, 160, b"C" * 80),
        _eof_packet(100),
    ]
    client, calls = _make_client(frames)
    data = await client.download_file(100, 0, 240)
    assert data == b"A" * 80 + b"B" * 80 + b"C" * 80
    assert calls["n_head"] == 1

@pytest.mark.asyncio
async def test_download_recoverable_gap_resends():
    """An 80-byte gap (dropped notification) triggers a resend from the gap."""
    frames = [
        _data_packet(100, 0, b"A" * 80),
        _data_packet(100, 160, b"C" * 80),
        _data_packet(100, 240, b"D" * 80),
        _eof_packet(100),
    ]
    client, calls = _make_client(frames)
    data = await client.download_file(100, 0, 320)
    assert calls["n_head"] >= 2
    assert data == b"A" * 80 + b"B" * 80 + b"C" * 80 + b"D" * 80

@pytest.mark.asyncio
async def test_gap_larger_than_max_is_error():
    """A gap beyond MAX_GAP_BYTES is a hard error; smaller gaps are resent."""
    from plaude.ble.client import MAX_GAP_BYTES
    frames = [
        _data_packet(100, 0, b"A" * 80),
        _data_packet(100, MAX_GAP_BYTES + 160, b"Z" * 80),
        _eof_packet(100),
    ]
    client, calls = _make_client(frames)
    with pytest.raises(RuntimeError):
        await client.download_file(100, 0, MAX_GAP_BYTES + 400)

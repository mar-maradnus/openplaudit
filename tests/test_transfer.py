"""Tests for PlaudClient.download_file — progress I/O, session filtering, resume.

These cover the SHIPPED path (PlaudClient.download_file in client.py), unlike
Tests/test_transfer.py, which still targets the pre-5432718 transfer.py
contract.

Regression under test: the old progress writer rewrote the whole accumulated
buffer every 20KB from inside the BLE notification callback, so write cost per
chunk grew with file size. That starved the receive path, overflowed the OS BLE
buffer, and dropped notifications in bursts late in large transfers
(observed: "expected 939040, got 940880" at 93%).
"""

import asyncio
import struct
from pathlib import Path

import pytest

from plaude.ble.client import PlaudClient
from plaude.ble.protocol import CMD_SYNC_FILE_HEAD, CMD_SYNC_FILE_TAIL, PROTO_COMMAND

SESSION = 1792274184
OTHER_SESSION = 1792270000

def _data_packet(session_id: int, offset: int, data: bytes) -> bytes:
    return bytes([0x02]) + struct.pack("<II", session_id, offset) + bytes([len(data)]) + data

def _eof_packet(session_id: int) -> bytes:
    return bytes([0x02]) + struct.pack("<II", session_id, 0xFFFFFFFF) + b"\x00"

def _make_client(payload: bytes, *, drop_at: int | None = None,
                 interleave_other_session: bool = False) -> PlaudClient:
    """PlaudClient whose fake device streams `payload` on SYNC_FILE_HEAD."""
    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "token"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None
    client._get_queue = PlaudClient._get_queue.__get__(client)

    async def fake_wait_response(cmd_id, timeout=5.0):
        if cmd_id == CMD_SYNC_FILE_HEAD:
            return b"\x00" * 5
        return None

    state = {"dropped": False}

    async def fake_send(cmd_id, payload=b""):
        if cmd_id != CMD_SYNC_FILE_HEAD:
            return
        start = struct.unpack_from("<I", payload, 4)[0]
        end = len(payload_data)
        off = start
        while off < end:
            n = min(80, end - off)
            if drop_at is not None and off == drop_at and not state["dropped"]:
                state["dropped"] = True
                off += n
                continue
            if interleave_other_session and off == 0:
                client._file_handler(_data_packet(OTHER_SESSION, 2_900_400, b"x" * 80))
            client._file_handler(_data_packet(SESSION, off, payload_data[off:off + n]))
            await asyncio.sleep(0)
            off += n
        client._file_handler(_eof_packet(SESSION))

    payload_data = payload
    client.send = fake_send
    client.wait_response = fake_wait_response
    return client

@pytest.mark.asyncio
async def test_completes_and_returns_full_payload(tmp_path):
    payload = bytes((i * 7) % 251 for i in range(8000))
    client = _make_client(payload)
    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload

@pytest.mark.asyncio
async def test_progress_file_matches_returned_bytes(tmp_path):
    """The progress file must end up byte-identical to the returned data."""
    payload = bytes((i * 3) % 251 for i in range(20000))
    progress = tmp_path / "x.opus"
    client = _make_client(payload)
    out = await client.download_file(SESSION, 0, len(payload),
                                     progress_path=str(progress))
    assert out == payload
    assert progress.read_bytes() == payload

@pytest.mark.asyncio
async def test_progress_writes_are_not_quadratic(tmp_path, monkeypatch):
    """Total bytes written equal the payload; the writer appends, not rewrites.

    The previous writer rewrote everything accumulated so far at every 20KB
    boundary, so a 200KB file wrote roughly 1MB. Counting the bytes handed to
    the progress file, rather than to a Path helper the append path never
    calls, is what makes this able to fail.
    """
    payload = bytes(200000)
    progress = tmp_path / "big.opus"
    counts = {"bytes": 0, "calls": 0}

    class CountingFile:
        def __init__(self, fh):
            self._fh = fh

        def write(self, data):
            counts["bytes"] += len(data)
            counts["calls"] += 1
            return self._fh.write(data)

        def __getattr__(self, name):
            return getattr(self._fh, name)

    real_open = Path.open

    def counting_open(self, *args, **kwargs):
        fh = real_open(self, *args, **kwargs)
        mode = args[0] if args else kwargs.get("mode", "r")
        return CountingFile(fh) if "w" in mode or "a" in mode else fh

    monkeypatch.setattr(Path, "open", counting_open)
    client = _make_client(payload)
    await client.download_file(SESSION, 0, len(payload), progress_path=str(progress))

    assert progress.read_bytes() == payload
    assert counts["bytes"] == len(payload)
    assert counts["calls"] > 100

@pytest.mark.asyncio
async def test_ignores_frames_from_other_session():
    """Stale frames from a previous recording must not desync the transfer.

    Without session filtering this produced 'offset mismatch: expected 0,
    got 2900400' on every file after the first.
    """
    payload = bytes(4000)
    client = _make_client(payload, interleave_other_session=True)
    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload

@pytest.mark.asyncio
async def test_recovers_from_multi_frame_gap():
    """A burst gap (many frames, not exactly one) must be resendable.

    The old code only accepted a gap of exactly 80 bytes; real drops were
    1840 and 2400 bytes, so recovery never fired.
    """
    payload = bytes((i * 11) % 251 for i in range(8000))
    client = _make_client(payload, drop_at=4000)
    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload, "multi-frame gap should be recovered by resend"

@pytest.mark.asyncio
async def test_resume_from_partial_returns_whole_file(tmp_path):
    """Resuming must return the WHOLE file, not just the tail.

    Regression: callers do `raw_path.write_bytes(raw_data)` after download, so
    returning only the resumed tail would clobber the partial it resumed from.
    """
    payload = bytes((i * 13) % 251 for i in range(8000))
    progress = tmp_path / "r.opus"
    progress.write_bytes(payload[:3200])

    client = _make_client(payload)
    out = await client.download_file(SESSION, 0, len(payload),
                                     start_offset=3200,
                                     progress_path=str(progress))
    assert out == payload, "resume must return the complete file"
    assert progress.read_bytes() == payload

@pytest.mark.asyncio
async def test_resume_refuses_when_partial_size_mismatches(tmp_path):
    """Resuming against a wrong-length partial must fail loudly, not corrupt."""
    payload = bytes(4000)
    progress = tmp_path / "bad.opus"
    progress.write_bytes(b"\x00" * 999)  # not 3200

    client = _make_client(payload)
    with pytest.raises(RuntimeError, match="Cannot resume"):
        await client.download_file(SESSION, 0, len(payload),
                                   start_offset=3200,
                                   progress_path=str(progress))

@pytest.mark.asyncio
async def test_recovers_from_gap_with_async_delivery():
    """Gap recovery must work when frames arrive ASYNCHRONOUSLY.

    The synchronous mock in _make_client hides a whole class of bug: if the
    per-pass `done` event is not reset before a resend, _wait_complete returns
    immediately and a truncated file is reported as success. On hardware frames
    always arrive asynchronously, so this test models that.
    """
    payload = bytes((i * 17) % 251 for i in range(16000))

    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "t"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None
    client._get_queue = PlaudClient._get_queue.__get__(client)

    dropped = {"done": False}

    async def fake_wait_response(cmd_id, timeout=5.0):
        return b"\x00" * 5 if cmd_id == CMD_SYNC_FILE_HEAD else None

    async def stream(start: int):
        await asyncio.sleep(0.01)  # let _wait_complete start polling first
        off = start
        while off < len(payload):
            n = min(80, len(payload) - off)
            if off == 8000 and not dropped["done"]:
                dropped["done"] = True  # one-shot burst gap
                off += n
                continue
            handler = client._file_handler
            if handler is not None:
                handler(_data_packet(SESSION, off, payload[off:off + n]))
            off += n
            if off % 800 == 0:
                await asyncio.sleep(0.001)
        handler = client._file_handler
        if handler is not None:
            handler(_eof_packet(SESSION))

    async def fake_send(cmd_id, payload_=b""):
        if cmd_id != CMD_SYNC_FILE_HEAD:
            return
        start = struct.unpack_from("<I", payload_, 4)[0]
        asyncio.create_task(stream(start))

    client.send = fake_send
    client.wait_response = fake_wait_response

    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload

def _make_client_with_drops(payload: bytes, drop_offsets: set[int]) -> PlaudClient:
    """Client whose fake device drops each offset in `drop_offsets` once."""
    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "t"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None
    client._get_queue = PlaudClient._get_queue.__get__(client)
    dropped: set[int] = set()

    async def fake_wait_response(cmd_id, timeout=5.0):
        return b"\x00" * 5 if cmd_id == CMD_SYNC_FILE_HEAD else None

    async def fake_send(cmd_id, payload_=b""):
        if cmd_id != CMD_SYNC_FILE_HEAD:
            return
        start = struct.unpack_from("<I", payload_, 4)[0]
        off = start
        while off < len(payload):
            n = min(80, len(payload) - off)
            if off in drop_offsets and off not in dropped:
                dropped.add(off)
                off += n
                continue
            handler = client._file_handler
            if handler is not None:
                handler(_data_packet(SESSION, off, payload[off:off + n]))
            off += n
        handler = client._file_handler
        if handler is not None:
            handler(_eof_packet(SESSION))

    client.send = fake_send
    client.wait_response = fake_wait_response
    return client

@pytest.mark.asyncio
async def test_many_separate_gaps_do_not_exhaust_budget():
    """The resend budget must be per-gap, not per-transfer.

    25 gaps is more than MAX_GAP_RESENDS (20). With a single global budget the
    transfer aborts even though every gap was recovered and the transfer kept
    making progress — which would fail long recordings that hiccup repeatedly.
    """
    payload = bytes((i * 19) % 251 for i in range(24000))
    drops = {off for off in range(800, 24000, 800)}  # 29 distinct offsets
    assert len(drops) > 20
    client = _make_client_with_drops(payload, drops)
    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload

@pytest.mark.asyncio
async def test_stuck_at_same_offset_gives_up():
    """Repeated gaps at ONE offset mean no progress; that must be abandoned."""
    payload = bytes((i * 23) % 251 for i in range(20000))

    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "t"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None
    client._get_queue = PlaudClient._get_queue.__get__(client)

    async def fake_wait_response(cmd_id, timeout=5.0):
        return b"\x00" * 5 if cmd_id == CMD_SYNC_FILE_HEAD else None

    async def fake_send(cmd_id, payload_=b""):
        if cmd_id != CMD_SYNC_FILE_HEAD:
            return
        start = struct.unpack_from("<I", payload_, 4)[0]
        handler = client._file_handler
        if handler is None:
            return
        off = start
        while off < 4000:
            handler(_data_packet(SESSION, off, payload[off:off + 80]))
            off += 80
        handler(_data_packet(SESSION, 4080, payload[4080:4160]))

    client.send = fake_send
    client.wait_response = fake_wait_response

    import plaude.ble.client as clientmod
    old = clientmod.STALL_SECONDS
    old_grace = clientmod.STALL_GRACE_SECONDS
    clientmod.STALL_SECONDS = 0.3
    clientmod.STALL_GRACE_SECONDS = 0.1
    try:
        with pytest.raises(RuntimeError, match="stalled"):
            await client.download_file(SESSION, 0, len(payload))
    finally:
        clientmod.STALL_SECONDS = old
        clientmod.STALL_GRACE_SECONDS = old_grace

@pytest.mark.asyncio
async def test_short_transfer_is_not_reported_as_success():
    """Device sent everything then EOF, but fewer bytes than it listed."""
    payload = bytes(4000)

    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "t"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None
    client._get_queue = PlaudClient._get_queue.__get__(client)

    async def fake_wait_response(cmd_id, timeout=5.0):
        return b"\x00" * 5 if cmd_id == CMD_SYNC_FILE_HEAD else None

    async def fake_send(cmd_id, payload_=b""):
        if cmd_id != CMD_SYNC_FILE_HEAD:
            return
        handler = client._file_handler
        for off in range(0, len(payload), 80):
            handler(_data_packet(SESSION, off, payload[off:off + 80]))
        handler(_eof_packet(SESSION))

    client.send = fake_send
    client.wait_response = fake_wait_response
    with pytest.raises(RuntimeError, match="Transfer incomplete"):
        await client.download_file(SESSION, 0, 9000)

def _tail_with_crc(session_id: int, crc: int) -> bytes:
    return (bytes([PROTO_COMMAND]) + struct.pack("<H", CMD_SYNC_FILE_TAIL)
            + struct.pack("<I", session_id) + struct.pack("<H", crc))

def _crc_client(payload: bytes, device_crc: int | None):
    """Client whose device ends the stream with SYNC_FILE_TAIL + a CRC."""
    from plaude.ble.protocol import crc16_ccitt
    client = PlaudClient.__new__(PlaudClient)
    client.address = "00:00:00:00:00:00"
    client.token = "t"
    client.verbose = False
    client.creds_path = None
    client._queues = {}
    client._file_handler = None
    client.authenticated = True
    client.port_version = 20
    client.crypto = None
    client._get_queue = PlaudClient._get_queue.__get__(client)
    sent = []

    async def fake_wait_response(cmd_id, timeout=5.0):
        return b"\x00" * 5

    async def fake_send(cmd_id, payload_=b""):
        sent.append((cmd_id, payload_))
        if cmd_id != CMD_SYNC_FILE_HEAD:
            return
        handler = client._file_handler
        for off in range(0, len(payload), 80):
            handler(_data_packet(SESSION, off, payload[off:off + 80]))
        if device_crc is None:
            handler(_eof_packet(SESSION))
        else:
            client._get_queue(CMD_SYNC_FILE_TAIL).put_nowait(
                _tail_with_crc(SESSION, device_crc))
            await asyncio.sleep(0.3)

    client.send = fake_send
    client.wait_response = fake_wait_response
    client._sent = sent
    return client

@pytest.mark.asyncio
async def test_crc_match_accepted():
    from plaude.ble.protocol import crc16_ccitt
    payload = bytes((i * 29) % 251 for i in range(4000))
    client = _crc_client(payload, crc16_ccitt(payload))
    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload
    checksum_sends = [p for c, p in client._sent if c == 116]
    assert checksum_sends, "host must acknowledge with FILE_CHECKSUM (cmd 116)"
    assert checksum_sends[0][0] == 0, "ack payload starts with 0x00"
    assert struct.unpack_from("<H", checksum_sends[0], 1)[0] == crc16_ccitt(payload)

@pytest.mark.asyncio
async def test_crc_mismatch_rejected():
    """Corrupted data must fail loudly rather than be saved as a good file."""
    payload = bytes((i * 31) % 251 for i in range(4000))
    client = _crc_client(payload, 0x1234)  # deliberately wrong
    with pytest.raises(RuntimeError, match="CRC mismatch"):
        await client.download_file(SESSION, 0, len(payload))

@pytest.mark.asyncio
async def test_crc_0xffff_means_skip():
    """The device signals 'skip verification' with 0xFFFF."""
    payload = bytes((i * 37) % 251 for i in range(4000))
    client = _crc_client(payload, 0xFFFF)
    out = await client.download_file(SESSION, 0, len(payload))
    assert out == payload

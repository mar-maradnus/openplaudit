"""Tests for download_file — failure paths, CRC validation, size checks."""

import asyncio
import struct
import pytest
from unittest.mock import AsyncMock, PropertyMock

from plaude.ble.transfer import download_file, DownloadError
from plaude.ble.protocol import crc16_ccitt


# --- Helpers ---

def _make_mock_client(voice_data: bytes, tail_payload: bytes | None,
                      head_payload: bytes = b"\x00" * 5,
                      ack_payload: bytes = b"\x01",
                      head_timeout: bool = False,
                      ack_timeout: bool = False):
    """Build a mock PlaudClient that simulates a BLE transfer."""
    client = AsyncMock()
    client.voice_data = bytearray()
    client.voice_packets = 0
    client.receiving = False

    # Track which command we're waiting for
    call_count = {"wait": 0}

    async def fake_wait_response(cmd_id, timeout=5.0):
        # CMD_SYNC_FILE_START = 28, CMD_SYNC_FILE_TAIL = 29, CMD_FILE_CHECKSUM_RSP = 117
        if cmd_id == 28:
            if head_timeout:
                return None
            return head_payload
        elif cmd_id == 29:
            call_count["wait"] += 1
            if call_count["wait"] == 1:
                # First poll: inject voice data to simulate BLE transfer
                client.voice_data.extend(voice_data)
                client.voice_packets = len(voice_data) // 89
                return None  # No tail yet
            # Second poll: tail arrives
            return tail_payload
        elif cmd_id == 117:
            if ack_timeout:
                return None
            return ack_payload
        return None

    client.wait_response = AsyncMock(side_effect=fake_wait_response)
    return client


def _make_voice_data(n_packets=10):
    """Generate fake 89-byte BLE packets."""
    data = bytearray()
    for i in range(n_packets):
        header = (1000).to_bytes(4, "little") + (i * 80).to_bytes(4, "little") + bytes([80])
        frame = bytes(80)
        data.extend(header + frame)
    return bytes(data)


def _make_tail(crc: int) -> bytes:
    """Build a 6-byte tail payload with CRC at offset 4."""
    return b"\x00" * 4 + struct.pack("<H", crc)


# --- Tests ---

class TestDownloadError:
    def test_is_exception(self):
        with pytest.raises(DownloadError, match="stall"):
            raise DownloadError("Transfer stalled at 500 bytes")

    def test_carries_message(self):
        e = DownloadError("CRC mismatch: device=0x1234 local=0x5678")
        assert "CRC mismatch" in str(e)
        assert "0x1234" in str(e)


class TestNoHeadResponse:
    @pytest.mark.asyncio
    async def test_raises_on_no_head(self):
        client = _make_mock_client(b"", None, head_timeout=True)
        with pytest.raises(DownloadError, match="No file head response"):
            await download_file(client, 1000, 800)


class TestTransferRejected:
    @pytest.mark.asyncio
    async def test_raises_on_nonzero_status(self):
        head = b"\x00" * 4 + bytes([1])  # status byte = 1 (rejected)
        client = _make_mock_client(b"", None, head_payload=head)
        with pytest.raises(DownloadError, match="Transfer rejected"):
            await download_file(client, 1000, 800)


class TestMalformedTailPacket:
    @pytest.mark.asyncio
    async def test_raises_on_short_tail(self):
        voice = _make_voice_data(10)
        short_tail = b"\x00\x01"  # Only 2 bytes, need >= 6
        client = _make_mock_client(voice, short_tail)
        with pytest.raises(DownloadError, match="Malformed tail"):
            await download_file(client, 1000, 800)

    @pytest.mark.asyncio
    async def test_raises_on_empty_tail(self):
        voice = _make_voice_data(10)
        client = _make_mock_client(voice, b"")
        with pytest.raises(DownloadError, match="Malformed tail"):
            await download_file(client, 1000, 800)


class TestChecksumAcknowledgement:
    @pytest.mark.asyncio
    async def test_raises_on_missing_ack(self):
        voice = _make_voice_data(10)
        tail = _make_tail(0xFFFF)  # CRC skipped
        client = _make_mock_client(voice, tail, ack_timeout=True)
        with pytest.raises(DownloadError, match="No checksum acknowledgement"):
            await download_file(client, 1000, 800)


class TestCrcValidation:
    @pytest.mark.asyncio
    async def test_crc_skipped_when_device_sends_ffff(self):
        voice = _make_voice_data(10)
        tail = _make_tail(0xFFFF)
        client = _make_mock_client(voice, tail)
        result = await download_file(client, 1000, 800)
        assert result == voice

    @pytest.mark.asyncio
    async def test_crc_match_succeeds(self):
        voice = _make_voice_data(10)
        local_crc = crc16_ccitt(voice)
        tail = _make_tail(local_crc)
        client = _make_mock_client(voice, tail)
        result = await download_file(client, 1000, 800)
        assert result == voice

    @pytest.mark.asyncio
    async def test_crc_mismatch_raises(self):
        voice = _make_voice_data(10)
        bad_crc = 0x1234
        tail = _make_tail(bad_crc)
        client = _make_mock_client(voice, tail)
        with pytest.raises(DownloadError, match="CRC mismatch"):
            await download_file(client, 1000, 800)


class TestSizeValidation:
    @pytest.mark.asyncio
    async def test_empty_data_raises(self):
        """Tail arrives but no voice data was captured."""
        tail = _make_tail(0xFFFF)
        client = _make_mock_client(b"", tail)
        with pytest.raises(DownloadError, match="no data received"):
            await download_file(client, 1000, 800)

    @pytest.mark.asyncio
    async def test_short_transfer_raises(self):
        """Data received is far below expected size."""
        tiny = _make_voice_data(1)  # 89 bytes, expected ~890
        tail = _make_tail(0xFFFF)
        client = _make_mock_client(tiny, tail)
        with pytest.raises(DownloadError, match="Transfer too short"):
            await download_file(client, 1000, 800)


class TestAlignmentValidation:
    @pytest.mark.asyncio
    async def test_misaligned_data_raises(self):
        """Data that is not 89-byte aligned indicates corruption."""
        # 890 bytes = 10 packets (aligned), add 5 extra bytes to break alignment
        voice = _make_voice_data(10) + b"\x00" * 5
        tail = _make_tail(0xFFFF)
        client = _make_mock_client(voice, tail)
        with pytest.raises(DownloadError, match="not 89-byte aligned"):
            await download_file(client, 1000, 800)

    @pytest.mark.asyncio
    async def test_aligned_data_succeeds(self):
        """Properly aligned data passes validation."""
        voice = _make_voice_data(10)  # 890 bytes = 10 * 89
        assert len(voice) % 89 == 0
        tail = _make_tail(0xFFFF)
        client = _make_mock_client(voice, tail)
        result = await download_file(client, 1000, 800)
        assert result == voice


class TestReceivingFlagCleanup:
    @pytest.mark.asyncio
    async def test_receiving_cleared_on_success(self):
        voice = _make_voice_data(10)
        tail = _make_tail(0xFFFF)
        client = _make_mock_client(voice, tail)
        await download_file(client, 1000, 800)
        assert client.receiving is False

    @pytest.mark.asyncio
    async def test_receiving_cleared_on_failure(self):
        client = _make_mock_client(b"", None, head_timeout=True)
        with pytest.raises(DownloadError):
            await download_file(client, 1000, 800)
        assert client.receiving is False

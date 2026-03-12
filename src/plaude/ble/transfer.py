"""File download over BLE — voice packet capture approach."""

import struct
import time

from .client import PlaudClient
from .protocol import (
    CMD_SYNC_FILE_START, CMD_SYNC_FILE_TAIL,
    CMD_FILE_CHECKSUM, CMD_FILE_CHECKSUM_RSP,
    crc16_ccitt,
)


class DownloadError(Exception):
    """Raised when a file download fails deterministically."""


async def download_file(
    client: PlaudClient,
    session_id: int,
    file_size: int,
    verbose: bool = False,
) -> bytes:
    """Download a recording from the device.

    The device sends file data as proto_type=0x02 (voice) packets after
    SYNC_FILE_START, then sends SYNC_FILE_TAIL with CRC when done.

    Returns raw Opus bytes (with 9-byte per-frame headers).
    Raises DownloadError on any failure (no head response, stall, CRC mismatch).
    """
    # Reset voice buffer
    client.voice_data = bytearray()
    client.voice_packets = 0
    client.receiving = True

    # file_size from device = raw frame bytes; actual BLE data includes 9-byte headers
    # per 80-byte frame, so expected_size ≈ file_size * 89/80
    expected_size = int(file_size * 89 / 80)

    try:
        # SYNC_FILE_START (cmd 28): session_id, offset=0, file_size
        payload = struct.pack("<III", session_id, 0, file_size)
        await client.send(CMD_SYNC_FILE_START, payload)

        head = await client.wait_response(CMD_SYNC_FILE_START, timeout=10.0)
        if head is None:
            raise DownloadError("No file head response from device")

        if len(head) >= 5 and head[4] != 0:
            raise DownloadError(f"Transfer rejected by device (status={head[4]})")

        # Collect voice packets until SYNC_FILE_TAIL
        start = time.time()
        last_size = 0
        stall_count = 0
        tail = None

        while True:
            tail = await client.wait_response(CMD_SYNC_FILE_TAIL, timeout=0.5)
            if tail is not None:
                break

            current = len(client.voice_data)
            if current != last_size:
                stall_count = 0
                last_size = current
                if verbose:
                    elapsed = time.time() - start
                    speed = current / elapsed if elapsed > 0 else 0
                    pct = min(current / expected_size * 100, 100.0)
                    print(f"\r  {current}/{expected_size} ({pct:.1f}%) "
                          f"{speed / 1024:.1f} KB/s [{client.voice_packets} pkts]",
                          end="", flush=True)
            else:
                stall_count += 1
                if stall_count > 20:  # 10s with no data
                    if verbose:
                        print()
                    raise DownloadError(
                        f"Transfer stalled at {current}/{expected_size} bytes "
                        f"after {time.time() - start:.0f}s"
                    )

        if verbose:
            print()

        file_data = bytes(client.voice_data)

        if not file_data:
            raise DownloadError("Transfer completed but no data received")

        # Size sanity check: expected_size is approximate (89/80 expansion), so
        # allow 10% under-delivery to account for device rounding and padding.
        # Anything below 90% of expected indicates a truncated transfer.
        min_acceptable = int(expected_size * 0.90)
        if len(file_data) < min_acceptable:
            raise DownloadError(
                f"Transfer too short: got {len(file_data)} bytes, "
                f"expected >= {min_acceptable} (~{expected_size})"
            )

        # Structural invariant: BLE voice packets are 89 bytes each.
        # Non-aligned data indicates corruption, truncation, or protocol drift.
        if len(file_data) % 89 != 0:
            raise DownloadError(
                f"Data not 89-byte aligned: {len(file_data)} bytes "
                f"(remainder={len(file_data) % 89}). "
                f"Possible packet corruption or firmware protocol change."
            )

        # Tail packet validation — must contain enough bytes for CRC field
        if tail is None or len(tail) < 6:
            raise DownloadError(
                f"Malformed tail packet: expected >=6 bytes, "
                f"got {len(tail) if tail else 0}"
            )

        device_crc = struct.unpack("<H", tail[4:6])[0]
        local_crc = crc16_ccitt(file_data)

        # Device sends 0xFFFF when it skips CRC (voice-mode transfers)
        crc_skipped = device_crc == 0xFFFF
        if verbose:
            if crc_skipped:
                print(f"  CRC: skipped by device (0xFFFF)")
            else:
                match = "OK" if device_crc == local_crc else "MISMATCH"
                print(f"  CRC: 0x{device_crc:04x}/0x{local_crc:04x} {match}")

        await client.send(CMD_FILE_CHECKSUM, struct.pack("<BH", 0, local_crc))
        ack = await client.wait_response(CMD_FILE_CHECKSUM_RSP, timeout=5.0)
        if ack is None:
            raise DownloadError("No checksum acknowledgement from device")

        if not crc_skipped and device_crc != local_crc:
            raise DownloadError(
                f"CRC mismatch: device=0x{device_crc:04x} local=0x{local_crc:04x}"
            )

        return file_data

    finally:
        client.receiving = False

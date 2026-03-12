"""Opus frame extraction and decoding to WAV.

Raw file format from PLAUD BLE transfer:
  Sequence of 89-byte packets:
    [session_id:4][offset:4][frame_size:1][opus_frame:80]
  Each opus frame is 20ms of 16kHz mono audio (320 PCM samples).
"""

import io
import struct
import wave

import opuslib

SAMPLE_RATE = 16000
CHANNELS = 1
FRAME_DURATION_MS = 20
SAMPLES_PER_FRAME = SAMPLE_RATE * FRAME_DURATION_MS // 1000  # 320
PACKET_SIZE = 89
HEADER_SIZE = 9  # session_id(4) + offset(4) + frame_size(1)


def extract_opus_frames(raw_data: bytes) -> list[bytes]:
    """Extract Opus frames from raw PLAUD BLE packets.

    Each packet is 89 bytes: 9-byte header + up to 80-byte Opus frame.
    The frame_size byte at offset 8 gives the actual Opus frame length.
    """
    frames = []
    offset = 0
    while offset + HEADER_SIZE <= len(raw_data):
        if offset + PACKET_SIZE > len(raw_data):
            # Partial trailing packet — extract what we can
            remaining = len(raw_data) - offset
            if remaining > HEADER_SIZE:
                frame_size = raw_data[offset + 8]
                available = remaining - HEADER_SIZE
                if frame_size > 0 and available >= frame_size:
                    frames.append(raw_data[offset + HEADER_SIZE:offset + HEADER_SIZE + frame_size])
            break

        frame_size = raw_data[offset + 8]
        if frame_size > 0 and frame_size <= 80:
            frames.append(raw_data[offset + HEADER_SIZE:offset + HEADER_SIZE + frame_size])
        offset += PACKET_SIZE

    return frames


def decode_opus_frames(frames: list[bytes]) -> bytes:
    """Decode a list of Opus frames to raw PCM (16-bit LE, 16kHz mono)."""
    decoder = opuslib.Decoder(SAMPLE_RATE, CHANNELS)
    pcm_chunks = []
    for frame in frames:
        try:
            pcm = decoder.decode(frame, SAMPLES_PER_FRAME)
            pcm_chunks.append(pcm)
        except opuslib.OpusError:
            # Insert silence for corrupted frames
            pcm_chunks.append(b"\x00" * SAMPLES_PER_FRAME * 2)
    return b"".join(pcm_chunks)


def decode_opus_raw(raw_data: bytes) -> bytes:
    """Decode raw PLAUD BLE data to PCM audio."""
    frames = extract_opus_frames(raw_data)
    return decode_opus_frames(frames)


def save_wav(pcm_data: bytes, path: str, sample_rate: int = SAMPLE_RATE) -> None:
    """Write raw PCM data to a WAV file."""
    with wave.open(path, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_data)


def pcm_to_wav_bytes(pcm_data: bytes, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Convert raw PCM data to in-memory WAV bytes."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_data)
    return buf.getvalue()

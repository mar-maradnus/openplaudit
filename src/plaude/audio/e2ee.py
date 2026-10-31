"""PLAUD.AI E2EE file decryption.

On-device recordings from portVersion>=20 devices are stored in a
"PLAUD.AI" container:

  [0x000:8]   "PLAUD.AI" magic
  [0x008:2]   version (=1)
  [0x00A:2]   headerSize (=512)
  [0x00C:4]   crc
  [0x010:32]  userId (fixed-size field; unbound devices show a placeholder)
  [0x030:2]   fileType (=5)
  [0x032:2]   channel (=1)
  [0x034:2]   encryptType (=1)
  [0x036:4]   duration
  [0x03A:4]   counter
  [0x03E:70]  reserved
  [0x084:12]  nonce (ChaCha20 nonce)
  [0x090:4]   segment (=80)
  [0x094:108] algParams (zeros)
  [0x100:256] keyCipher (RSA-2048 / PKCS1v15-wrapped 32-byte symmetric key)
  [0x200:...] encrypted audio

Decryption:

1. RSA-decrypt keyCipher with the user's private key -> 32-byte symmetric key.
2. The audio is encrypted in `segment`-byte chunks (80 bytes on NB100).
   For each chunk, decrypt with ChaCha20 (IETF RFC7539), counter=0, the
   header nonce — i.e. a fresh keystream per chunk, NOT one continuous stream.
3. The decrypted payload is a sequence of raw 80-byte Opus frames (20 ms,
   16 kHz mono) with no Ogg container.

The Android AudioExporter uses exactly this loop:
`while (pos < length) { read segment bytes; decryptChaCha20(seg, key, nonce, 0); }`.
"""

from __future__ import annotations

import struct

import opuslib

from .decoder import SAMPLE_RATE, CHANNELS

PLAUD_AI_MAGIC = b"PLAUD.AI"
HEADER_SIZE = 512
KEYCIPHER_OFFSET = 0x100
NONCE_OFFSET = 0x84
SEGMENT_OFFSET = 0x90
SAMPLES_PER_FRAME = 320  # 20ms @ 16kHz
MAX_FRAME_SIZE = 80

def parse_header(raw_data: bytes) -> dict:
    """Parse the PLAUD.AI header fields needed for decryption."""
    if raw_data[:8] != PLAUD_AI_MAGIC:
        raise ValueError("Not a PLAUD.AI E2EE container")
    if len(raw_data) < HEADER_SIZE:
        raise ValueError(f"PLAUD.AI file too short: {len(raw_data)}B")
    return {
        "version": struct.unpack_from("<H", raw_data, 0x08)[0],
        "header_size": struct.unpack_from("<H", raw_data, 0x0A)[0],
        "userId": raw_data[0x10:0x30].rstrip(b"\x00").decode(errors="replace"),
        "fileType": struct.unpack_from("<H", raw_data, 0x30)[0],
        "channel": struct.unpack_from("<H", raw_data, 0x32)[0],
        "encryptType": struct.unpack_from("<H", raw_data, 0x34)[0],
        "nonce": raw_data[NONCE_OFFSET:NONCE_OFFSET + 12],
        "segment": struct.unpack_from("<I", raw_data, SEGMENT_OFFSET)[0],
        "keyCipher": raw_data[KEYCIPHER_OFFSET:KEYCIPHER_OFFSET + 256],
    }

def decrypt_symmetric_key(key_cipher: bytes, private_key_pem: str) -> bytes:
    """RSA-decrypt the wrapped symmetric key (PKCS1v15). Returns 32 bytes."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    sym = key.decrypt(key_cipher, padding.PKCS1v15())
    if len(sym) < 32:
        raise ValueError(f"Decrypted symmetric key too short: {len(sym)}B")
    return sym[:32]

def decrypt_audio(raw_data: bytes, private_key_pem: str) -> bytes:
    """Decrypt the audio region of a PLAUD.AI container to raw Opus frames.

    Returns the concatenated decrypted chunks (each `segment` bytes decrypted
    with a fresh ChaCha20 keystream, counter=0, header nonce). The result is
    a stream of raw 80-byte Opus frames.
    """
    hdr = parse_header(raw_data)
    sym = decrypt_symmetric_key(hdr["keyCipher"], private_key_pem)
    segment = hdr["segment"] if hdr["segment"] > 0 else 80
    nonce = hdr["nonce"]

    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms

    audio = raw_data[HEADER_SIZE:]
    iv = (0).to_bytes(4, "little") + nonce
    out = bytearray()
    for off in range(0, len(audio), segment):
        chunk = audio[off:off + segment]
        c = Cipher(algorithms.ChaCha20(sym, iv), mode=None).decryptor()
        out += c.update(chunk)
    return bytes(out)

def decode_opus_frames(opus_data: bytes) -> bytes:
    """Decode a stream of raw Opus frames to 16kHz mono PCM.

    Real device payloads are fixed 80-byte slots (20ms @ 16kHz mono). Each
    slot decodes as one frame; invalid slots decode as silence.
    """
    decoder = opuslib.Decoder(SAMPLE_RATE, CHANNELS)
    pcm = bytearray()
    ok = 0
    total = 0
    for i in range(0, len(opus_data) - (MAX_FRAME_SIZE - 1), MAX_FRAME_SIZE):
        frame = opus_data[i:i + MAX_FRAME_SIZE]
        total += 1
        try:
            pcm += decoder.decode(frame, SAMPLES_PER_FRAME)
            ok += 1
        except opuslib.OpusError:
            pcm += b"\x00" * (SAMPLES_PER_FRAME * 2)
    if ok == 0:
        raise ValueError("No valid Opus frames in decrypted audio")
    return bytes(pcm)

def decode_plaud_ai_e2ee(raw_data: bytes, private_key_pem: str) -> bytes:
    """Decode a PLAUD.AI E2EE container to PCM (16kHz mono 16-bit LE)."""
    opus_data = decrypt_audio(raw_data, private_key_pem)
    return decode_opus_frames(opus_data)

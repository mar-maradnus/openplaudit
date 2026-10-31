"""Tests for PLAUD.AI E2EE decryption (audio/e2ee.py).

These build a synthetic PLAUD.AI container on the encrypt side (RSA-wrap a
random symmetric key, then encrypt a stream of real Opus frames in 80-byte
segments with fresh ChaCha20 keystreams, matching the device behavior) and
assert the decryptor recovers the exact PCM.
"""

import struct
import array

import opuslib
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric import padding as asym_padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms

from plaude.audio.decoder import SAMPLE_RATE
from plaude.audio.e2ee import (
    PLAUD_AI_MAGIC,
    HEADER_SIZE,
    decrypt_audio,
    decrypt_symmetric_key,
    decode_opus_frames,
    decode_plaud_ai_e2ee,
    parse_header,
)

def _make_keypair() -> tuple[str, str]:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    priv = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return pub, priv

def _make_opus_frames(n: int = 10, seed: int = 0) -> bytes:
    """Generate `n` valid Opus frames.

    Real NB100 frames are exactly 80 bytes (20ms @ 16kHz mono). Speech-like
    input (a chirp) produces large packets; we take whatever opuslib emits
    and concatenate. The ChaCha20/RSA round-trip tests only need the frames
    to be valid Opus; frame size need not be exactly 80 here.
    """
    enc = opuslib.Encoder(SAMPLE_RATE, 1, opuslib.APPLICATION_VOIP)
    chirp = array.array("h", (int(2000 * ((i % 640) / 640)) for i in range(640))).tobytes()
    frames = bytearray()
    for i in range(n):
        base = enc.encode(chirp, 640)
        frames += base
    return bytes(frames)

def _encrypt_audio(sym_key: bytes, nonce: bytes, opus_data: bytes, segment: int = 80) -> bytes:
    """Encrypt raw Opus frames the way the device does: per-segment ChaCha20,
    counter=0 restart each segment."""
    iv = (0).to_bytes(4, "little") + nonce
    out = bytearray()
    for off in range(0, len(opus_data), segment):
        chunk = opus_data[off:off + segment]
        c = Cipher(algorithms.ChaCha20(sym_key, iv), mode=None).encryptor()
        out += c.update(chunk)
    return bytes(out)

def _make_e2ee_file(pub_pem: str, opus_data: bytes, seed: int = 1) -> tuple[bytes, bytes]:
    """Build a synthetic PLAUD.AI container. Returns (file_bytes, sym_key)."""
    nonce = bytes(range(12))
    sym_key = bytes((i * 7) & 0xFF for i in range(32))
    cipher = _encrypt_audio(sym_key, nonce, opus_data)

    pub = serialization.load_pem_public_key(pub_pem.encode())
    key_cipher = pub.encrypt(sym_key, asym_padding.PKCS1v15())

    hdr = bytearray(HEADER_SIZE)
    hdr[0:8] = PLAUD_AI_MAGIC
    struct.pack_into("<H", hdr, 0x08, 1)          # version
    struct.pack_into("<H", hdr, 0x0A, HEADER_SIZE)  # headerSize
    hdr[0x10:0x30] = b"userid_0123456789abcdefghijklmno"
    struct.pack_into("<H", hdr, 0x30, 5)          # fileType
    struct.pack_into("<H", hdr, 0x32, 1)          # channel
    struct.pack_into("<H", hdr, 0x34, 1)          # encryptType
    hdr[0x84:0x90] = nonce
    struct.pack_into("<I", hdr, 0x90, 80)         # segment
    hdr[0x100:0x200] = key_cipher
    return bytes(hdr) + cipher, sym_key

class TestParseHeader:
    def test_parse_real_shape(self):
        pub, priv = _make_keypair()
        opus = _make_opus_frames(5)
        data, sym = _make_e2ee_file(pub, opus)
        h = parse_header(data)
        assert h["version"] == 1
        assert h["segment"] == 80
        assert h["channel"] == 1
        assert h["encryptType"] == 1
        assert h["userId"] == "userid_0123456789abcdefghijklmno"
        assert len(h["keyCipher"]) == 256
        assert len(h["nonce"]) == 12

    def test_parse_rejects_non_plaud_ai(self):
        with pytest.raises(ValueError):
            parse_header(b"NOTPLAUD" + b"\x00" * 600)

class TestDecrypt:
    def test_decrypt_symmetric_key_roundtrip(self):
        pub, priv = _make_keypair()
        opus = _make_opus_frames(5)
        data, sym = _make_e2ee_file(pub, opus)
        got = decrypt_symmetric_key(data[0x100:0x200], priv)
        assert got == sym

    def test_decrypt_audio_recovers_opus(self):
        pub, priv = _make_keypair()
        opus = _make_opus_frames(12, seed=3)
        data, sym = _make_e2ee_file(pub, opus)
        dec = decrypt_audio(data, priv)
        assert dec == opus

    def test_decrypt_audio_roundtrip(self):
        """The RSA + per-segment ChaCha20 decrypt recovers the exact opus."""
        pub, priv = _make_keypair()
        opus = _make_opus_frames(4, seed=5)
        data, _ = _make_e2ee_file(pub, opus)
        assert decrypt_audio(data, priv) == opus

class TestErrorHandling:
    def test_wrong_key_does_not_produce_same_key(self):
        """A wrong RSA key either fails PKCS1 or yields a different key.
        (The ~1/67620 chance of a wrong key passing PKCS1 padding makes a hard
        raises() assertion flaky; what is guaranteed is that the wrong key
        never recovers the original symmetric key.)"""
        pub1, priv1 = _make_keypair()
        _, priv2 = _make_keypair()
        opus = _make_opus_frames(4)
        data, sym = _make_e2ee_file(pub1, opus)
        try:
            got = decrypt_symmetric_key(data[0x100:0x200], priv2)
        except Exception:
            got = None
        assert got != sym
        assert decrypt_symmetric_key(data[0x100:0x200], priv1) == sym

    def test_short_file_rejected(self):
        with pytest.raises(ValueError):
            parse_header(b"PLAUD.AI" + b"\x00" * 100)

    def test_invalid_opus_frames_raises(self):
        with pytest.raises(ValueError):
            decode_opus_frames(b"\xff" * 80)

"""BleakClient wrapper — connect, v20 pre-handshake auth, time sync, file listing.

portVersion>=20 devices (NB100, project 888) require:
  1. RSA pre-handshake (0xFE20 SN signature -> 0xFE11 -> 0xFE12 RSA pubkey ->
     device returns RSA-encrypted ChaCha20 session keys)
  2. Main handshake (CMD 0x01), encrypted with the session keys
  3. Two-handshake (CMD 0x01 + SSN) for v20+
  4. All subsequent commands encrypted with ChaCha20-Poly1305.

Credentials (sn_signature, user_rsa_public_key, user_rsa_private_key) come
from ~/plaud-credentials.md. The device must be awake (tap the Record button)
before it advertises.
"""

import asyncio
import base64
import logging
import re
import struct
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner

from .protocol import (
    CMD_HANDSHAKE, CMD_GET_SSN, CMD_TIME_SYNC, CMD_RECORD_SWITCH,
    CMD_GET_REC_SESSIONS, CMD_SYNC_FILE_HEAD,
    CMD_SYNC_FILE_TAIL, CMD_SYNC_FILE_STOP, CMD_PRE_HANDSHAKE_NEW,
    CMD_PRE_HANDSHAKE_CNF, CMD_SEND_RSA_PUBKEY, PRE_HANDSHAKE_CMDS,
    CMD_NAMES, PROTO_COMMAND, SERVICE_UUID, TX_UUID, RX_UUID,
    CHUNK_SIZE, HANDSHAKE_STATUS, build_cmd, build_pre_handshake_chunk,
    build_handshake_packet, build_two_handshake_packet, build_sync_time_packet,
    parse_handshake_response, parse_ssn_response, parse_file_data_packet,
    parse_tail_crc, crc16_ccitt,
    CMD_FILE_CHECKSUM, CMD_FILE_CHECKSUM_RSP,
)

DEFAULT_CREDS_PATH = "~/plaud-credentials.md"

log = logging.getLogger(__name__)

MAX_GAP_BYTES = 65536
MAX_GAP_RESENDS = 20
STALL_SECONDS = 120.0
STALL_GRACE_SECONDS = 15.0
PROGRESS_FLUSH_BYTES = 65536

class AuthError(Exception):
    """Raised when device authentication fails."""

class Crypto:
    """ChaCha20-Poly1305 session crypto with the PLAUD counter scheme.

    send_counter starts at 1 and is incremented BEFORE each encryption, so the
    first encrypted packet uses counter=2. Every plaintext is prepended with
    the 4-byte LE counter inside the sealed blob; decryption strips it.
    """

    def __init__(self, key: bytes, nonce: bytes, ad: bytes):
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
        self._chacha = ChaCha20Poly1305(key)
        self.nonce = nonce
        self.ad = ad
        self.send_counter = 1
        self.receive_counter = 0

    def encrypt(self, plaintext: bytes) -> bytes:
        self.send_counter += 1
        return self._chacha.encrypt(
            self.nonce, struct.pack("<I", self.send_counter) + plaintext, self.ad
        )

    def decrypt(self, ciphertext: bytes) -> bytes:
        plain = self._chacha.decrypt(self.nonce, ciphertext, self.ad)
        counter = struct.unpack("<I", plain[:4])[0]
        if counter <= self.receive_counter:
            log.debug("out-of-order counter %d (last %d); device may resend",
                      counter, self.receive_counter)
        self.receive_counter = counter
        return plain[4:]

def load_credentials(path: str | Path = DEFAULT_CREDS_PATH) -> dict:
    """Load sn_signature + RSA keys from the credentials file."""
    path = Path(path).expanduser()
    if not path.exists():
        raise FileNotFoundError(f"Credentials file not found: {path}")

    text = path.read_text()
    flags = re.DOTALL  # PEM blocks are multi-line; '.' must span newlines
    def _field(pattern: str) -> str:
        m = re.search(pattern, text, flags)
        if not m:
            raise ValueError(f"Missing credential field matching {pattern!r} in {path}")
        return m.group(1)

    return {
        "sn_signature": _field(r"sn_signature:\s*(\S+)"),
        "rsa_public_key": _field(
            r"user_rsa_public_key:\s*(-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----)"
        ),
        "rsa_private_key": _field(
            r"user_rsa_private_key:\s*(-----BEGIN PRIVATE KEY-----.*?-----END PRIVATE KEY-----)"
        ),
    }

class PlaudClient:
    """High-level BLE client for PLAUD Note (portVersion>=20)."""

    def __init__(self, address: str, token: str, verbose: bool = False,
                 creds_path: str | Path = DEFAULT_CREDS_PATH):
        self.address = address
        self.token = token
        self.verbose = verbose
        self.creds_path = Path(creds_path).expanduser()
        self.client = BleakClient(address, timeout=30.0)
        self._queues: dict[int, asyncio.Queue] = {}
        self.authenticated = False
        self.port_version = 0
        self.ssn: str | None = None
        self.crypto: Crypto | None = None
        self._decrypt_failures = 0
        self._file_handler = None

    def _get_queue(self, cmd_id: int) -> asyncio.Queue:
        if cmd_id not in self._queues:
            self._queues[cmd_id] = asyncio.Queue()
        return self._queues[cmd_id]

    def _on_notify(self, sender, data: bytearray):
        raw = bytes(data)
        if self.verbose:
            print(f"  [RX] {raw.hex()[:80]}")
        if len(raw) < 1:
            return

        opcode = struct.unpack("<H", raw[:2])[0] if len(raw) >= 2 else -1
        if opcode in PRE_HANDSHAKE_CMDS:
            self._get_queue(opcode).put_nowait(raw)
            return

        if self.crypto is not None:
            try:
                raw = self.crypto.decrypt(raw)
            except Exception as e:
                self._decrypt_failures += 1
                log.debug("decrypt failed (%d so far): %s", self._decrypt_failures, e)
                return

        if len(raw) < 1:
            return
        proto = raw[0]

        if proto == PROTO_COMMAND:
            if len(raw) < 3:
                return
            cmd = struct.unpack("<H", raw[1:3])[0]
            payload = raw[3:]
            if self.verbose:
                name = CMD_NAMES.get(cmd, f"CMD_{cmd}")
                print(f"  <- [{name}] {payload.hex()[:80]}")
            self._get_queue(cmd).put_nowait(raw)
            return

        if self._file_handler is not None:
            if self.verbose:
                print(f"  [DATA len={len(raw)}] {raw[:16].hex()}")
            self._file_handler(raw)
            return

    async def wait_response(self, cmd_id: int, timeout: float = 5.0) -> bytes | None:
        """Wait for a response frame to a specific command ID."""
        try:
            return await asyncio.wait_for(self._get_queue(cmd_id).get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None

    async def send(self, cmd_id: int, payload: bytes = b""):
        """Send a command packet, encrypted when crypto is active."""
        pkt = build_cmd(cmd_id, payload)
        if self.crypto is not None:
            pkt = self.crypto.encrypt(pkt)
        if self.verbose:
            name = CMD_NAMES.get(cmd_id, f"CMD_{cmd_id}")
            print(f"  -> [{name}] {pkt.hex()[:80]}")
        await self.client.write_gatt_char(RX_UUID, pkt, response=True)

    async def _send_raw(self, data: bytes):
        await self.client.write_gatt_char(RX_UUID, data, response=True)

    async def connect(self):
        """Connect to the device and subscribe to notifications."""
        await self.client.connect()
        if self.verbose:
            print(f"Connected (MTU={self.client.mtu_size})")
        await self.client.start_notify(TX_UUID, self._on_notify)

    async def disconnect(self):
        """Disconnect from the device."""
        try:
            await self.client.disconnect()
        except Exception:
            pass

    async def _rsa_decrypt(self, secret: bytes, private_key_pem: str) -> bytes:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
        return key.decrypt(secret, padding.PKCS1v15())

    async def depair(self, clear_files: bool = False) -> bytes | None:
        """Unbind the device from the current binding key.

        cmd 5 (APP_DEPAIR_REQ) with payload [clear_files:1]. Sends the depair
        request and waits for the depair confirmation (cmd 5 response). After
        this, the device is unbound and will accept a new binding key on the
        next pre-handshake.

        Returns the raw depair response frame, or None on timeout.
        """
        payload = bytes([1 if clear_files else 0])
        await self.send(CMD_RECORD_SWITCH, payload)
        resp = await self.wait_response(CMD_RECORD_SWITCH, timeout=6.0)
        return resp

    async def _perform_pre_handshake(self, creds: dict) -> Crypto:
        """Run the RSA pre-handshake and return session Crypto.

        Sends the SN signature (0xFE20), waits for 0xFE11 confirm, sends the
        RSA public key (0xFE12), then collects the RSA-encrypted session keys
        and decrypts them. Also verifies the "PLAUD.AI" verification blob.
        """
        if self.verbose:
            print("  [pre-handshake] SN signature ->")
        sn = base64.b64decode(creds["sn_signature"])
        total = (len(sn) + CHUNK_SIZE - 1) // CHUNK_SIZE
        for i in range(total):
            await self._send_raw(build_pre_handshake_chunk(
                CMD_PRE_HANDSHAKE_NEW, total, i, sn[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]))
        confirm = await self.wait_response(CMD_PRE_HANDSHAKE_CNF, timeout=10.0)
        if confirm is None:
            raise AuthError("Pre-handshake: no 0xFE11 confirm from device")
        if self.verbose:
            print(f"  <- 0xFE11 confirm ({len(confirm)}B)")

        if self.verbose:
            print("  [pre-handshake] RSA public key ->")
        pub = creds["rsa_public_key"].encode()
        total = (len(pub) + CHUNK_SIZE - 1) // CHUNK_SIZE
        for i in range(total):
            await self._send_raw(build_pre_handshake_chunk(
                CMD_SEND_RSA_PUBKEY, total, i, pub[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]))

        pkts: dict[int, bytes] = {}
        count = None
        deadline = time.time() + 15.0
        q = self._get_queue(CMD_SEND_RSA_PUBKEY)
        while time.time() < deadline:
            try:
                chunk = await asyncio.wait_for(q.get(), timeout=min(1.0, deadline - time.time()))
            except asyncio.TimeoutError:
                break
            cnt = chunk[2]
            idx = chunk[3]
            if count is None:
                count = cnt
            if cnt == count:
                pkts[idx] = chunk[4:]
            if count is not None and len(pkts) >= count:
                break

        if not (count and len(pkts) >= count):
            raise AuthError(f"Pre-handshake: incomplete key material ({len(pkts)}/{count})")
        secret = b"".join(pkts[i] for i in range(count))

        dec = await self._rsa_decrypt(secret, creds["rsa_private_key"])
        if len(dec) < 56:
            raise AuthError(f"Pre-handshake: decrypted key material too short ({len(dec)}B)")
        key, nonce, ad = dec[0:32], dec[32:44], dec[44:56]

        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
        try:
            ver = ChaCha20Poly1305(key).decrypt(nonce, dec[56:], ad)
        except Exception:
            ver = b""
        if self.verbose:
            print(f"  [pre-handshake] keys ok, verify={ver!r}")
        if b"PLAUD.AI" not in ver:
            raise AuthError("Pre-handshake: 'PLAUD.AI' verification failed — wrong session keys")

        return Crypto(key, nonce, ad)

    async def handshake(self, creds: dict | None = None) -> bool:
        """Authenticate with the device (v20 pre-handshake + main + two-handshake).

        `creds` may override the credential file loaded from `self.creds_path`
        (used by the self-bind flow to present a freshly generated keypair).
        """
        if creds is None:
            creds = load_credentials(self.creds_path)
        self.crypto = await self._perform_pre_handshake(creds)

        if self.verbose:
            print("  [handshake] encrypted handshake ->")
        await self._send_raw(self.crypto.encrypt(
            build_handshake_packet(self.token.encode(), 20)))
        resp = await self.wait_response(CMD_HANDSHAKE, timeout=10.0)
        if resp is None:
            raise AuthError("Handshake: no response from device")
        parsed = parse_handshake_response(resp)
        if self.verbose:
            print(f"  <- [HANDSHAKE] status={parsed['status']} "
                  f"({HANDSHAKE_STATUS.get(parsed['status'], 'UNKNOWN')}) "
                  f"port={parsed['portVersion']}")
        if parsed["status"] != 0:
            raise AuthError(
                f"Handshake failed: status={parsed['status']} "
                f"({HANDSHAKE_STATUS.get(parsed['status'], 'UNKNOWN')})")
        self.port_version = parsed["portVersion"]
        self.authenticated = True

        if self.port_version >= 20:
            ssn_frame = await self.wait_response(CMD_GET_SSN, timeout=5.0)
            if ssn_frame is not None:
                self.ssn = parse_ssn_response(ssn_frame)
                if self.verbose:
                    print(f"  <- [SSN] {self.ssn!r}")
                await self._send_raw(self.crypto.encrypt(
                    build_two_handshake_packet(self.token.encode(), self.port_version, self.ssn)))

        return True

    async def record_switch(self, start: bool, scene: int = 0):
        """Start or stop a recording.

        Start:  CMD 0x14 payload [1][scene]   (Q3(1, scene) in the APK)
        Stop:   CMD 0x14 payload [reason][1]  (R3(reason, 1) in the APK)
        Returns the parsed response (ji/k0): sessionId/fileSize/status.
        """
        if start:
            payload = bytes([1, scene & 0xFF])
        else:
            payload = bytes([0, 1])
        await self.send(CMD_RECORD_SWITCH, payload)
        resp = await self.wait_response(CMD_RECORD_SWITCH, timeout=6.0)
        if resp is None or len(resp) < 12:
            return None
        return {
            "session_id": struct.unpack("<Q", resp[3:11])[0],
            "status": resp[11],
            "raw": resp,
        }

    async def time_sync(self):
        """Sync current time to the device."""
        await self.send(CMD_TIME_SYNC, struct.pack("<I", int(time.time())))
        await self.wait_response(CMD_TIME_SYNC, timeout=3.0)

    async def get_sessions(self, retries: int = 6) -> list[dict]:
        """List recordings on the device (GET_REC_SESSIONS cmd 0x1A).

        The device is flaky: while idle it sometimes returns an empty list
        (total=0) even though recordings exist. We retry a few times with a
        short delay; a retry with total>0 wins.

        Request:  [ts:4][ts:4][flag:1]
        Response (verified raw, firmware 2.2):
          [type:1][cmd:2][ts:4][total:2 LE][entries...]
          Entry: [session_id:4][file_size:4][file_type:1][file_index:1]
            = 10 bytes per entry, starting at payload[6].
        """
        for attempt in range(max(1, retries)):
            now = int(time.time())
            await self.send(CMD_GET_REC_SESSIONS,
                            struct.pack("<IIB", now, 0, 0))
            resp = await self.wait_response(CMD_GET_REC_SESSIONS, timeout=6.0)
            if resp is None or len(resp) < 9:
                await asyncio.sleep(0.4)
                continue
            payload = resp[3:]  # strip [type:1][cmd:2]
            total = struct.unpack("<H", payload[4:6])[0]
            if total == 0:
                await asyncio.sleep(0.4)
                continue
            entries = []
            off = 8  # entries start at payload[8] after [ts:4][total:2][pad:2]
            while off + 10 <= len(payload) and len(entries) < total:
                session_id = struct.unpack("<I", payload[off:off + 4])[0]
                file_size = struct.unpack("<I", payload[off + 4:off + 8])[0]
                file_type = payload[off + 8]
                file_index = payload[off + 9]
                entries.append({
                    "session_id": session_id,
                    "file_size": file_size,
                    "file_index": file_index,
                    "file_type": file_type,
                    "scene": 0,
                })
                off += 10
            if entries:
                return entries
        return []

    async def delete_session(self, session_id: int) -> list[dict]:
        """Delete a recording on the device (cmd 0x1A, delete-shaped payload).

        The APK's delete path (mi/r3.D3 -> M) sends cmd 26 (0x1A) with payload
        [now:4][session_id:4][flag:1=0] — the same command as the list, but
        with the target session in the middle field. The device responds with
        the updated session list (parsed like get_sessions).
        """
        now = int(time.time())
        await self.send(CMD_GET_REC_SESSIONS,
                        struct.pack("<IIB", now, session_id & 0xFFFFFFFF, 0))
        resp = await self.wait_response(CMD_GET_REC_SESSIONS, timeout=8.0)
        if resp is None or len(resp) < 9:
            return []
        payload = resp[3:]
        total = struct.unpack("<H", payload[4:6])[0]
        entries = []
        off = 8
        while off + 10 <= len(payload) and len(entries) < total:
            sid = struct.unpack("<I", payload[off:off + 4])[0]
            size = struct.unpack("<I", payload[off + 4:off + 8])[0]
            ftype = payload[off + 8]
            fidx = payload[off + 9]
            entries.append({
                "session_id": sid,
                "file_size": size,
                "file_index": fidx,
                "file_type": ftype,
                "scene": 0,
            })
            off += 10
        return entries

    async def download_file(self, session_id: int, file_index: int,
                            file_size: int, file_type: int = 0,
                            verbose: bool = False, start_offset: int = 0,
                            progress_path: str | None = None) -> bytes:
        """Download a recording (v20 file-sync protocol). Returns raw Opus bytes.

        Flow (per APK mi/r3.java, method around line 3298):
          cmd 28 SYNC_FILE_HEAD [sessionId][startPos][fileSize] -> device
          streams data (0x02 packets, offset-sliced) -> EOF marker
          offset==0xFFFFFFFF -> cmd 30 SyncRecFileStop [sessionId].

        There is NO "prepare" command — the APK sends cmd 28 (ii/v0) and waits
        for response cmd 29. Cmd 0x14 is the RECORD command (ji/j0), never
        touched during download.

        `start_offset` resumes from a previous position (the device accepts a
        nonzero startPosition in SYNC_FILE_HEAD).

        `progress_path`: when set, downloaded bytes are APPENDED to this file as
        they arrive, so an interrupted transfer (killed process, device drop)
        still leaves a valid partial to resume from on the next run.
        """
        if self.verbose or verbose:
            print(f"  [sync] file {file_index} (from offset {start_offset}), size={file_size}")
        self._decrypt_failures = 0

        received = bytearray()
        expected_offset = start_offset
        done = asyncio.Event()
        error = None
        gap_at = None

        # Append; rewriting the whole buffer per chunk starved the BLE path.
        progress_fh = None
        if progress_path is not None:
            try:
                p = Path(progress_path)
                p.parent.mkdir(parents=True, exist_ok=True)
                if start_offset == 0:
                    progress_fh = p.open("wb")
                elif p.exists() and p.stat().st_size == start_offset:
                    # `received` holds the whole file from offset 0.
                    received.extend(p.read_bytes())
                    progress_fh = p.open("ab")
                else:
                    raise RuntimeError(
                        f"Cannot resume from {start_offset}: {p} is missing or "
                        f"has a different size")
            except RuntimeError:
                raise
            except Exception:
                progress_fh = None

        if start_offset > 0 and len(received) != start_offset:
            raise RuntimeError(
                f"Cannot resume from {start_offset}: no partial available "
                f"(pass progress_path pointing at the existing file)")

        tail_frame: list = [None]
        last_progress = time.monotonic()
        flushed_to = start_offset
        resync_from = None

        def on_data(frame: bytes):
            nonlocal expected_offset, error, gap_at, last_progress, resync_from, flushed_to
            pkt = parse_file_data_packet(frame)
            if pkt["offset"] == 0xFFFFFFFF:
                done.set()
                return
            if pkt["session_id"] != session_id:
                return
            if gap_at is not None:
                return
            if resync_from is not None:
                if pkt["offset"] != resync_from:
                    return  # stale frame from the aborted stream
                resync_from = None
            if pkt["offset"] != expected_offset:
                gap = pkt["offset"] - expected_offset
                if 0 < gap <= MAX_GAP_BYTES:
                    gap_at = expected_offset
                    done.set()
                    return
                error = (f"offset mismatch: expected {expected_offset}, "
                         f"got {pkt['offset']} (gap {gap})")
                done.set()
                return
            received.extend(pkt["data"])
            expected_offset += len(pkt["data"])
            last_progress = time.monotonic()
            if progress_fh is not None:
                try:
                    progress_fh.write(pkt["data"])
                    if expected_offset - flushed_to >= PROGRESS_FLUSH_BYTES:
                        progress_fh.flush()
                        flushed_to = expected_offset
                except Exception:
                    pass
            if self.verbose or verbose:
                pct = min(expected_offset / file_size * 100, 100.0) if file_size else 0
                print(f"\r  {expected_offset}/{file_size} ({pct:.1f}%)", end="", flush=True)

        self._file_handler = on_data

        async def _wait_complete(head_timeout=10.0, stall_grace=0.0):
            head = await self.wait_response(CMD_SYNC_FILE_HEAD, timeout=head_timeout)
            if head is None:
                raise RuntimeError("No SYNC_FILE_HEAD response from device")
            while True:
                if done.is_set() or error is not None or gap_at is not None:
                    break
                tail_q = self._get_queue(CMD_SYNC_FILE_TAIL)
                if not tail_q.empty():
                    tail_frame[0] = tail_q.get_nowait()
                    break
                _stall = globals()["STALL_SECONDS"]
                if time.monotonic() - last_progress > _stall + stall_grace:
                    raise RuntimeError(
                        f"Transfer stalled at {expected_offset}/{file_size} "
                        f"(no data for {_stall + stall_grace:.0f}s)")
                await asyncio.sleep(0.25)
            if error is not None:
                raise RuntimeError(error)

        try:
            # Drain control frames first; a leftover SYNC_FILE_TAIL reads as EOF.
            for _stale in (CMD_GET_REC_SESSIONS, CMD_SYNC_FILE_TAIL):
                try:
                    while not self._get_queue(_stale).empty():
                        self._get_queue(_stale).get_nowait()
                except Exception:
                    pass
            await self.send(CMD_SYNC_FILE_HEAD,
                            struct.pack("<III", session_id, start_offset, file_size))
            await _wait_complete()
            # MAX_GAP_RESENDS bounds resends per gap, not per transfer.
            resends = 0
            resends_at_offset = 0
            last_resume = -1
            while gap_at is not None:
                resume = gap_at
                gap_at = None
                if resume == last_resume:
                    resends_at_offset += 1
                else:
                    resends_at_offset = 1
                    last_resume = resume
                if resends_at_offset > MAX_GAP_RESENDS:
                    raise RuntimeError(
                        f"Transfer stuck at {resume}/{file_size}: "
                        f"{MAX_GAP_RESENDS} resends made no progress")
                resends += 1
                if self.verbose or verbose:
                    print(f"\n  [resend] #{resends} (x{resends_at_offset} at this "
                          f"offset) from {resume}")
                if 0 <= resume < expected_offset:
                    del received[resume:]
                    expected_offset = resume
                    flushed_to = resume
                    if progress_fh is not None:
                        try:
                            progress_fh.seek(resume)
                            progress_fh.truncate()
                        except Exception:
                            pass
                # A resend must not clear `error` or reuse a set `done`.
                done = asyncio.Event()
                last_progress = time.monotonic()
                # Accept only a frame at exactly `resume` until it arrives.
                resync_from = resume
                await self.send(CMD_SYNC_FILE_HEAD,
                                struct.pack("<III", session_id, resume, file_size))
                await _wait_complete(head_timeout=10.0,
                                     stall_grace=STALL_GRACE_SECONDS)
            if self._decrypt_failures:
                raise RuntimeError(
                    f"{self._decrypt_failures} frame(s) failed to decrypt")
            if not received:
                raise RuntimeError("Transfer completed but no data received")
            if tail_frame[0] is not None:
                device_crc = parse_tail_crc(tail_frame[0])
                local_crc = crc16_ccitt(bytes(received))
                crc_skipped = device_crc is None or device_crc == 0xFFFF
                try:
                    await self.send(CMD_FILE_CHECKSUM,
                                    struct.pack("<BH", 0, local_crc))
                    await self.wait_response(CMD_FILE_CHECKSUM_RSP, timeout=5.0)
                except Exception:
                    pass
                if not crc_skipped and device_crc != local_crc:
                    raise RuntimeError(
                        f"CRC mismatch: device=0x{device_crc:04x} "
                        f"local=0x{local_crc:04x} — data corrupted in transit")
                if self.verbose or verbose:
                    state = "skipped by device" if crc_skipped else (
                        "OK" if device_crc == local_crc else "MISMATCH")
                    print(f"\n  [crc] 0x{local_crc:04x} {state}")
            if file_size and expected_offset < file_size:
                raise RuntimeError(
                    f"Transfer incomplete: device listed {file_size} bytes but "
                    f"sent {expected_offset}")
        finally:
            # Never send cmd 0x16 / [0][1] here: it lights the red LED.
            try:
                await self.send(CMD_SYNC_FILE_STOP, struct.pack("<I", session_id))
            except Exception:
                pass
            self._file_handler = None
            if progress_fh is not None:
                try:
                    progress_fh.close()
                except Exception:
                    pass
            if self.verbose or verbose:
                print()

        return bytes(received)

    @staticmethod
    async def scan(timeout: float = 15.0) -> list[dict]:
        """Scan for PLAUD BLE devices. Returns list of {name, address, rssi}."""
        devices = await BleakScanner.discover(
            timeout=timeout, return_adv=True,
            service_uuids=[SERVICE_UUID],
        )

        found = []
        for device, adv in devices.values():
            found.append({
                "name": device.name or adv.local_name or "(unnamed)",
                "address": device.address,
                "rssi": adv.rssi,
            })

        if not found:
            # Fallback: broader scan looking for Nordic chipset or PLAUD name
            all_devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
            for device, adv in all_devices.values():
                name = device.name or adv.local_name or ""
                mfr = adv.manufacturer_data or {}
                if "plaud" in name.lower() or 0x0059 in mfr:
                    found.append({
                        "name": name or "(unnamed)",
                        "address": device.address,
                        "rssi": adv.rssi,
                    })

        return found

"""BleakClient wrapper — connect, handshake, time sync, session listing."""

import asyncio
import struct
import time

from bleak import BleakClient, BleakScanner

from .protocol import (
    CMD_HANDSHAKE, CMD_TIME_SYNC, CMD_GET_REC_SESSIONS,
    CMD_NAMES, PROTO_COMMAND, PROTO_VOICE, SERVICE_UUID,
    TX_UUID, RX_UUID, build_cmd, parse_sessions,
)


class PlaudClient:
    """High-level BLE client for PLAUD Note."""

    def __init__(self, address: str, token: str, verbose: bool = False):
        self.address = address
        self.token = token
        self.verbose = verbose
        self.client = BleakClient(address, timeout=30.0)
        self._queues: dict[int, asyncio.Queue] = {}
        self.authenticated = False

        # Voice packet capture state (used by transfer module)
        self.voice_data = bytearray()
        self.voice_packets = 0
        self.receiving = False

    def _get_queue(self, cmd_id: int) -> asyncio.Queue:
        if cmd_id not in self._queues:
            self._queues[cmd_id] = asyncio.Queue()
        return self._queues[cmd_id]

    def _on_notify(self, sender, data: bytearray):
        raw = bytes(data)
        if len(raw) < 1:
            return

        proto = raw[0]

        if proto == PROTO_VOICE:
            if self.receiving:
                self.voice_data.extend(raw[1:])
                self.voice_packets += 1
            return

        if proto != PROTO_COMMAND or len(raw) < 3:
            return

        cmd = struct.unpack("<H", raw[1:3])[0]
        payload = raw[3:]
        if self.verbose:
            name = CMD_NAMES.get(cmd, f"CMD_{cmd}")
            print(f"  <- [{name}] {payload.hex()[:80]}")
        self._get_queue(cmd).put_nowait(payload)

    async def wait_response(self, cmd_id: int, timeout: float = 5.0) -> bytes | None:
        """Wait for a response to a specific command ID."""
        try:
            return await asyncio.wait_for(self._get_queue(cmd_id).get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None

    async def send(self, cmd_id: int, payload: bytes = b""):
        """Send a command packet to the device."""
        pkt = build_cmd(cmd_id, payload)
        if self.verbose:
            name = CMD_NAMES.get(cmd_id, f"CMD_{cmd_id}")
            print(f"  -> [{name}] {pkt.hex()[:80]}")
        await self.client.write_gatt_char(RX_UUID, pkt, response=True)

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

    async def handshake(self) -> bool:
        """Authenticate with the device using the binding token."""
        token_bytes = self.token.encode("utf-8")[:32].ljust(32, b"\x00")
        payload = bytes([0x02, 0x00, 0x00]) + token_bytes
        await self.send(CMD_HANDSHAKE, payload)

        resp = await self.wait_response(CMD_HANDSHAKE, timeout=5.0)
        if resp is None or len(resp) < 1:
            return False

        status = resp[0]
        if status == 0:
            self.authenticated = True
            return True
        return False

    async def time_sync(self):
        """Sync current time to the device."""
        await self.send(CMD_TIME_SYNC, struct.pack("<I", int(time.time())))
        await self.wait_response(CMD_TIME_SYNC, timeout=3.0)

    async def get_sessions(self) -> list[dict]:
        """Retrieve the list of recording sessions from the device."""
        await self.send(CMD_GET_REC_SESSIONS)
        resp = await self.wait_response(CMD_GET_REC_SESSIONS, timeout=5.0)
        if resp is None:
            return []
        return parse_sessions(resp)

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

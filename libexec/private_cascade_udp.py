#!/usr/bin/env python3
"""Split authenticated loopback Trojan UDP into immutable local VLESS streams."""

import argparse
import asyncio
import hashlib
import hmac
import json
import os
import signal
import stat
import struct
import sys
import uuid
from dataclasses import dataclass

MAX_SESSIONS = 64
MAX_FLOWS = 256
MAX_SESSION_FLOWS = 32
QUEUE_SIZE = 32
MAX_PAYLOAD = 8190  # Xray's bare VLESS packet writer reserves two bytes of its 8K buffer.
IO_TIMEOUT = 5
IDLE_TIMEOUT = 120


class ProtocolError(ValueError):
    """Identify malformed or unsupported relay protocol data."""
    pass


@dataclass(frozen=True)
class Config:
    """Hold local endpoints and independent credentials from renderer output."""
    listen_port: int
    dispatch_port: int
    password: str
    client_id: uuid.UUID

    @classmethod
    def from_file(cls, path):
        """Read protected secrets and require authenticated, loopback-only endpoints."""
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as file:
            info = os.fstat(file.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.geteuid())
                    or info.st_mode & 0o027):
                raise ProtocolError("Config must be protected and owned by root or the caller")
            data = json.load(file)
        relays = [o for o in data.get("outbounds", []) if o.get("tag") == "private-cascade-udp-relay"]
        dispatchers = [i for i in data.get("inbounds", []) if i.get("tag") == "private-cascade-udp-dispatch"]
        if len(relays) != 1 or len(dispatchers) != 1:
            raise ProtocolError("Expected one UDP relay and dispatcher")
        relay, dispatch = relays[0], dispatchers[0]
        servers = relay.get("settings", {}).get("servers", [])
        clients = dispatch.get("settings", {}).get("clients", [])
        if len(servers) != 1 or len(clients) != 1:
            raise ProtocolError("Expected one local server and credential")
        server = servers[0]
        password = server.get("password")
        if (relay.get("protocol") != "trojan" or server.get("address") != "127.0.0.1"
                or dispatch.get("protocol") != "vless" or dispatch.get("listen") != "127.0.0.1"
                or dispatch.get("settings", {}).get("decryption") != "none"
                or dispatch.get("settings", {}).get("fallbacks")
                or clients[0].get("flow")
                or any(item.get("streamSettings", {}).get("network") != "tcp"
                       or item.get("streamSettings", {}).get("security") != "none"
                       for item in (relay, dispatch))
                or not isinstance(password, str) or not 16 <= len(password.encode()) <= 255):
            raise ProtocolError("UDP relay requires authenticated loopback-only TCP endpoints")
        ports = server.get("port"), dispatch.get("port")
        if any(type(p) is not int or not 1024 <= p <= 65535 for p in ports) or ports[0] == ports[1]:
            raise ProtocolError("UDP relay ports must be distinct valid ports")
        return cls(*ports, password, uuid.UUID(clients[0]["id"]))


@dataclass(frozen=True)
class Destination:
    """Retain exact Trojan identity and port-first VLESS framing without DNS."""
    wire: bytes
    vless: bytes


async def read_destination(reader):
    """Decode an address without resolving it or merging distinct flow keys."""
    kind = await reader.readexactly(1)
    if kind == b"\x01":
        address = await reader.readexactly(4)
        vless_kind = b"\x01"
    elif kind == b"\x04":
        address = await reader.readexactly(16)
        vless_kind = b"\x03"
    elif kind == b"\x03":
        size = await reader.readexactly(1)
        if not size[0]:
            raise ProtocolError("Empty domain")
        name = await reader.readexactly(size[0])
        if any(c < 33 or c > 126 for c in name):
            raise ProtocolError("Invalid domain encoding")
        address = size + name
        vless_kind = b"\x02"
    else:
        raise ProtocolError("Unknown address type")
    port = await reader.readexactly(2)
    if port == b"\0\0":
        raise ProtocolError("Invalid destination port")
    return Destination(kind + address + port, port + vless_kind + address)


async def read_packet(reader):
    """Read a complete datagram, rejecting lengths that exceed Xray's framing budget."""
    destination = await read_destination(reader)
    size = struct.unpack("!H", await reader.readexactly(2))[0]
    if not 1 <= size <= min(MAX_PAYLOAD, 8192 - len(destination.wire) - 4) or await reader.readexactly(2) != b"\r\n":
        raise ProtocolError("Invalid UDP frame")
    return destination, await reader.readexactly(size)


async def close_writer(writer):
    """Release a local stream within the I/O deadline, including failed connections."""
    if writer is not None:
        writer.close()
        try:
            await asyncio.wait_for(writer.wait_closed(), IO_TIMEOUT)
        except (OSError, asyncio.TimeoutError):
            pass


class Flow:
    """Confine one destination to one backend stream with bounded pending packets."""

    def __init__(self, session, destination):
        """Create a bounded queue and schedule its immutable-destination stream."""
        self.session = session
        self.destination = destination
        self.queue = asyncio.Queue(QUEUE_SIZE)
        self.last_active = asyncio.get_running_loop().time()
        self.task = asyncio.create_task(self.run())
        self.task.add_done_callback(self.finished)

    def finished(self, task):
        """Release capacity even when cancellation preceded the flow's first execution."""
        self.session.flows.pop(self.destination.wire, None)
        self.session.relay.flow_count -= 1
        if not task.cancelled() and task.exception() is not None:
            print("UDP relay flow failed unexpectedly", file=sys.stderr)
            self.session.writer.close()

    async def send(self, writer):
        """Preserve datagram boundaries while bounding stalled backend writes."""
        while True:
            payload = await self.queue.get()
            writer.write(struct.pack("!H", len(payload)) + payload)
            await asyncio.wait_for(writer.drain(), IO_TIMEOUT)

    async def receive(self, reader):
        """Restore original reply labels and serialize writes to the frontend stream."""
        if await reader.readexactly(2) != b"\0\0":
            raise ProtocolError("Unexpected local VLESS response")
        while True:
            size = struct.unpack("!H", await reader.readexactly(2))[0]
            if not 1 <= size <= min(MAX_PAYLOAD, 8192 - len(self.destination.wire) - 4):
                raise ProtocolError("Invalid local VLESS packet length")
            payload = await reader.readexactly(size)
            self.last_active = self.session.last_active = asyncio.get_running_loop().time()
            frame = self.destination.wire + struct.pack("!H", size) + b"\r\n" + payload
            async with self.session.write_lock:
                self.session.writer.write(frame)
                await asyncio.wait_for(self.session.writer.drain(), IO_TIMEOUT)

    async def idle(self):
        """Expire an inactive backend flow without switching its selected exit."""
        while True:
            await asyncio.sleep(min(1, IDLE_TIMEOUT / 2))
            if asyncio.get_running_loop().time() - self.last_active >= IDLE_TIMEOUT:
                return

    async def run(self):
        """Own one fixed VLESS stream and cancel all directions when any task ends."""
        writer = None
        tasks = []
        try:
            config = self.session.relay.config
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", config.dispatch_port), IO_TIMEOUT)
            # Send the first packet before waiting for Xray's buffered response header.
            writer.write(b"\0" + config.client_id.bytes + b"\0\x02" + self.destination.vless)
            tasks = [asyncio.create_task(self.send(writer)), asyncio.create_task(self.receive(reader)),
                     asyncio.create_task(self.idle())]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (ProtocolError, asyncio.IncompleteReadError, OSError, asyncio.TimeoutError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await close_writer(writer)


class Session:
    """Keep each authenticated client's destination map and replies isolated."""

    def __init__(self, relay, reader, writer):
        """Allocate client-local flow identity, response ordering and idle state."""
        self.relay, self.reader, self.writer = relay, reader, writer
        self.flows = {}
        self.write_lock = asyncio.Lock()
        self.last_active = asyncio.get_running_loop().time()

    async def read(self):
        """Split destinations into bounded flows and drop overload without rerouting."""
        while True:
            destination, payload = await read_packet(self.reader)
            self.last_active = asyncio.get_running_loop().time()
            flow = self.flows.get(destination.wire)
            if flow is None:
                if len(self.flows) >= MAX_SESSION_FLOWS or self.relay.flow_count >= MAX_FLOWS:
                    continue
                flow = self.flows[destination.wire] = Flow(self, destination)
                self.relay.flow_count += 1
            flow.last_active = self.last_active
            try:
                flow.queue.put_nowait(payload)
            except asyncio.QueueFull:
                pass

    async def idle(self):
        """End a session after both client packets and backend replies become inactive."""
        while True:
            await asyncio.sleep(min(1, IDLE_TIMEOUT / 2))
            if asyncio.get_running_loop().time() - self.last_active >= IDLE_TIMEOUT:
                return

    async def run(self):
        """Tie every backend socket and task to the frontend connection lifetime."""
        tasks = [asyncio.create_task(self.read()), asyncio.create_task(self.idle())]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            flows = [flow.task for flow in self.flows.values()]
            for task in flows:
                task.cancel()
            await asyncio.gather(*flows, return_exceptions=True)


class Relay:
    """Authenticate local Trojan streams before allowing per-destination splitting."""

    def __init__(self, config):
        """Track authentication and global capacity without logging credentials or data."""
        self.config = config
        self.key = hashlib.sha224(config.password.encode()).hexdigest().encode()
        self.clients = set()
        self.handlers = set()
        self.flow_count = 0
        self.server = None

    async def authenticate(self, reader):
        """Accept only the configured password hash and Trojan UDP request command."""
        if not hmac.compare_digest(await reader.readexactly(56), self.key):
            raise ProtocolError("Authentication failed")
        if await reader.readexactly(3) != b"\r\n\x03":
            raise ProtocolError("Only UDP is supported")
        await read_destination(reader)
        if await reader.readexactly(2) != b"\r\n":
            raise ProtocolError("Invalid request header")

    async def handle(self, reader, writer):
        """Enforce admission and handshake limits before allocating client flows."""
        task = asyncio.current_task()
        self.handlers.add(task)
        try:
            if writer.get_extra_info("peername")[0] != "127.0.0.1" or len(self.clients) >= MAX_SESSIONS:
                return
            self.clients.add(writer)
            await asyncio.wait_for(self.authenticate(reader), IO_TIMEOUT)
            await Session(self, reader, writer).run()
        except (ProtocolError, asyncio.IncompleteReadError, OSError, asyncio.TimeoutError):
            pass
        finally:
            self.clients.discard(writer)
            await close_writer(writer)
            self.handlers.discard(task)

    async def start(self):
        """Expose the authenticated relay only on IPv4 loopback."""
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", self.config.listen_port)

    async def close(self):
        """Stop admission and await cleanup of every accepted client."""
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()
        tasks = list(self.handlers)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def serve(config):
    """Install termination hooks and release all clients before process exit."""
    relay = Relay(config)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stopped.set)
    try:
        await relay.start()
        await stopped.wait()
    finally:
        await relay.close()


def main():
    """Load renderer output and report startup failures without disclosing secrets."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    try:
        config = Config.from_file(args.config)
        asyncio.run(serve(config))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        parser.exit(1, "UDP relay could not read its protected configuration or bind its listener.\n")


if __name__ == "__main__":
    main()

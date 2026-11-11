#!/usr/bin/env python3
"""Local wire-level regression checks; no external connections or host mutations."""

import asyncio
import contextlib
import hashlib
import importlib.util
import ipaddress
import io
import json
import pathlib
import struct
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("private_cascade_udp", ROOT / "libexec/private_cascade_udp.py")
relay = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = relay
SPEC.loader.exec_module(relay)

PASSWORD = "only-local-test-password"
CLIENT_ID = uuid.UUID("11111111-2222-4333-8444-555555555555")


def destination(host, port):
    """Build independent IPv4, IPv6 or domain wire addresses for protocol probes."""
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        name = host.encode()
        wire = b"\x03" + bytes([len(name)]) + name
    else:
        wire = (b"\x01" if address.version == 4 else b"\x04") + address.packed
    return wire + struct.pack("!H", port)


def packet(target, payload):
    """Frame test datagrams independently of the relay's decoder."""
    return target + struct.pack("!H", len(payload)) + b"\r\n" + payload


async def eventually(condition):
    """Await asynchronous cleanup with a finite polling budget."""
    for _ in range(100):
        if condition():
            return
        await asyncio.sleep(.01)
    raise AssertionError("State did not settle")


class WireTests(unittest.IsolatedAsyncioTestCase):
    """Exercise authenticated splitting against an isolated bare VLESS echo peer."""

    async def asyncSetUp(self):
        """Start temporary loopback peers without touching host routing or services."""
        self.records = []
        self.backend_tasks = set()
        self.backend = await asyncio.start_server(self.backend_client, "127.0.0.1", 0)
        port = self.backend.sockets[0].getsockname()[1]
        self.proxy = relay.Relay(relay.Config(0, port, PASSWORD, CLIENT_ID))
        await self.proxy.start()
        self.port = self.proxy.server.sockets[0].getsockname()[1]
        self.writers = []

    async def asyncTearDown(self):
        """Close fixture peers and require complete relay capacity and task release."""
        for writer in self.writers:
            writer.close()
        await self.proxy.close()
        self.backend.close()
        await self.backend.wait_closed()
        for task in list(self.backend_tasks):
            task.cancel()
        await asyncio.gather(*self.backend_tasks, return_exceptions=True)
        self.assertEqual(self.proxy.flow_count, 0)
        self.assertFalse(self.proxy.clients)
        self.assertFalse(self.proxy.handlers)

    async def backend_client(self, reader, writer):
        """Observe fixed VLESS targets and inject bounded response failures on request."""
        task = asyncio.current_task()
        self.backend_tasks.add(task)
        record = None
        try:
            prefix = await reader.readexactly(19)
            self.assertEqual(prefix, b"\0" + CLIENT_ID.bytes + b"\0\x02")
            port = await reader.readexactly(2)
            kind = await reader.readexactly(1)
            if kind == b"\x01":
                address, label = await reader.readexactly(4), b"\x01"
            elif kind == b"\x03":
                address, label = await reader.readexactly(16), b"\x04"
            elif kind == b"\x02":
                size = await reader.readexactly(1)
                address, label = size + await reader.readexactly(size[0]), b"\x03"
            else:
                self.fail("Unexpected VLESS address family")
            record = {"target": label + address + port, "payloads": [], "closed": False}
            self.records.append(record)
            first = True
            while True:
                size = struct.unpack("!H", await reader.readexactly(2))[0]
                payload = await reader.readexactly(size)
                record["payloads"].append(payload)
                if first:
                    writer.write(b"\x01\0" if payload == b"wrong-version" else b"\0\0")
                    first = False
                if payload == b"oversize-reply":
                    writer.write(struct.pack("!H", relay.MAX_PAYLOAD + 1))
                else:
                    writer.write(struct.pack("!H", size) + payload)
                await writer.drain()
        except (asyncio.IncompleteReadError, OSError):
            pass
        finally:
            if record is not None:
                record["closed"] = True
            writer.close()
            await writer.wait_closed()
            self.backend_tasks.discard(task)

    async def connect(self, password=PASSWORD, command=b"\x03"):
        """Open a test frontend with selectable credentials and command."""
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        self.writers.append(writer)
        key = hashlib.sha224(password.encode()).hexdigest().encode()
        writer.write(key + b"\r\n" + command + destination("192.0.2.1", 4000) + b"\r\n")
        await writer.drain()
        return reader, writer

    async def response(self, reader):
        """Require a complete frontend reply within the fixture deadline."""
        return await asyncio.wait_for(relay.read_packet(reader), 1)

    async def test_one_authenticated_stream_splits_and_reuses_exact_destinations(self):
        """Require independent backend targets while reusing only identical endpoints."""
        reader, writer = await self.connect()
        targets = [destination("192.0.2.1", 4000), destination("example.ru", 4000),
                   destination("192.0.2.1", 4001), destination("2001:db8::1", 4000)]
        for n, target in enumerate(targets):
            payload = ("payload-%d" % n).encode()
            writer.write(packet(target, payload))
            await writer.drain()
            response, data = await self.response(reader)
            self.assertEqual((response.wire, data), (target, payload))
        writer.write(packet(targets[0], b"again"))
        self.assertEqual((await self.response(reader))[1], b"again")
        self.assertEqual(len(self.records), 4)
        self.assertEqual(self.records[0]["payloads"], [b"payload-0", b"again"])
        self.assertEqual({r["target"] for r in self.records}, set(targets))

    async def test_two_clients_same_destination_are_isolated(self):
        """Keep equal destinations and one client's disconnect isolated across clients."""
        a, aw = await self.connect()
        b, bw = await self.connect()
        target = destination("192.0.2.1", 4000)
        aw.write(packet(target, b"alice"))
        bw.write(packet(target, b"bob"))
        self.assertEqual((await self.response(a))[1], b"alice")
        self.assertEqual((await self.response(b))[1], b"bob")
        self.assertEqual(len(self.records), 2)
        self.assertNotEqual(self.records[0]["payloads"], self.records[1]["payloads"])
        aw.close()
        await eventually(lambda: self.proxy.flow_count == 1)
        bw.write(packet(target, b"bob-still"))
        self.assertEqual((await self.response(b))[1], b"bob-still")

    async def test_wrong_auth_and_tcp_or_mux_commands_never_reach_classifier(self):
        """Reject unauthorized or non-UDP traffic before any backend connection."""
        for password, command in [("wrong-test-password", b"\x03"), (PASSWORD, b"\x01"),
                                  (PASSWORD, b"\x7f")]:
            reader, writer = await self.connect(password, command)
            writer.write(packet(destination("192.0.2.1", 4000), b"rejected"))
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(self.records, [])

    async def test_malformed_and_oversize_packets_close_without_destination_dial(self):
        """Reject invalid frames, zero ports and oversized lengths before forwarding."""
        malformed = [b"\x09", destination("192.0.2.1", 4000) + b"\0\0\r\n",
                     destination("192.0.2.1", 4000) + struct.pack("!H", relay.MAX_PAYLOAD + 1),
                     destination("192.0.2.1", 4000) + b"\0\x01xxz", b"\x03\0",
                     destination("192.0.2.1", 0) + b"\0\x01\r\nz"]
        for bad in malformed:
            reader, writer = await self.connect()
            writer.write(bad)
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(self.records, [])

    async def test_control_disconnect_cleans_all_backend_flows(self):
        """Require frontend EOF to close every destination stream and return capacity."""
        reader, writer = await self.connect()
        for port in range(4000, 4003):
            writer.write(packet(destination("192.0.2.1", port), b"ok"))
            await self.response(reader)
        writer.close()
        await eventually(lambda: self.proxy.flow_count == 0)
        await eventually(lambda: all(r["closed"] for r in self.records))

    async def test_payload_boundary_is_byte_exact_and_oversize_never_truncated(self):
        """Echo the largest IPv4 frame intact and reject one extra byte entirely."""
        reader, writer = await self.connect()
        target = destination("192.0.2.1", 4000)
        largest = bytes(range(251)) * 32 + b"x" * 149  # 8181 bytes: exact IPv4 Trojan frame capacity.
        self.assertEqual(len(largest), 8192 - len(target) - 4)
        writer.write(packet(target, largest))
        self.assertEqual((await self.response(reader))[1], largest)
        writer.write(packet(target, largest + b"x"))
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(self.records[0]["payloads"], [largest])

    async def test_limits_drop_new_destinations_but_existing_flow_continues(self):
        """Keep established flows usable when a client reaches its destination cap."""
        with patch.object(relay, "MAX_SESSION_FLOWS", 1), patch.object(relay, "MAX_FLOWS", 1):
            reader, writer = await self.connect()
            target = destination("192.0.2.1", 4000)
            writer.write(packet(target, b"first"))
            await self.response(reader)
            writer.write(packet(destination("192.0.2.2", 4000), b"over-limit"))
            writer.write(packet(target, b"still-good"))
            self.assertEqual((await self.response(reader))[1], b"still-good")
            self.assertEqual(len(self.records), 1)
            self.assertEqual(self.proxy.flow_count, 1)

    async def test_idle_expiry_and_invalid_backend_response_release_resources(self):
        """Reclaim capacity after idle expiry or invalid VLESS reply framing."""
        with patch.object(relay, "IDLE_TIMEOUT", .06):
            reader, writer = await self.connect()
            writer.write(packet(destination("192.0.2.1", 4000), b"idle"))
            await self.response(reader)
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        for payload in [b"wrong-version", b"oversize-reply"]:
            _, writer = await self.connect()
            writer.write(packet(destination("192.0.2.1", 4000), payload))
            await eventually(lambda: any(payload in r["payloads"] for r in self.records))
            await eventually(lambda: self.proxy.flow_count == 0)

    async def test_global_capacity_is_shared_and_released_for_other_clients(self):
        """Enforce the shared cap and make released slots available to another client."""
        with patch.object(relay, "MAX_SESSION_FLOWS", 2), patch.object(relay, "MAX_FLOWS", 1):
            a, aw = await self.connect()
            b, bw = await self.connect()
            aw.write(packet(destination("192.0.2.1", 4000), b"occupy"))
            await self.response(a)
            target = destination("192.0.2.2", 4000)
            bw.write(packet(target, b"over-limit"))
            await asyncio.sleep(.02)
            self.assertEqual(len(self.records), 1)
            aw.close()
            await eventually(lambda: self.proxy.flow_count == 0)
            bw.write(packet(target, b"capacity-returned"))
            self.assertEqual((await self.response(b))[1], b"capacity-returned")
            self.assertEqual(self.records[-1]["payloads"], [b"capacity-returned"])

    async def test_pending_queue_is_bounded_without_losing_other_destinations(self):
        """Drop excess queued packets while preserving admitted packets and new flows."""
        gate = asyncio.Event()
        original = relay.Flow.send

        async def delayed_send(flow, writer):
            """Hold the backend sender so the fixture can saturate its pending queue."""
            await gate.wait()
            await original(flow, writer)

        with patch.object(relay, "QUEUE_SIZE", 3), patch.object(relay.Flow, "send", delayed_send):
            reader, writer = await self.connect()
            target = destination("192.0.2.1", 4000)
            writer.write(b"".join(packet(target, bytes([n])) for n in range(10)))
            await eventually(lambda: len(self.records) == 1)
            gate.set()
            values = [(await self.response(reader))[1] for _ in range(3)]
            self.assertEqual(values, [b"\0", b"\1", b"\2"])
            other = destination("192.0.2.2", 4000)
            writer.write(packet(other, b"other"))
            response, payload = await self.response(reader)
            self.assertEqual((response.wire, payload), (other, b"other"))
            self.assertEqual(self.records[0]["payloads"], values)

    async def test_unauthenticated_connection_limit_and_handshake_timeout(self):
        """Bound clients before authentication and expire incomplete handshakes."""
        with patch.object(relay, "MAX_SESSIONS", 1), patch.object(relay, "IO_TIMEOUT", .06):
            reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
            self.writers.append(writer)
            await eventually(lambda: len(self.proxy.clients) == 1)
            other, ow = await asyncio.open_connection("127.0.0.1", self.port)
            self.writers.append(ow)
            self.assertEqual(await asyncio.wait_for(other.read(), 1), b"")
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
            await eventually(lambda: not self.proxy.clients)

    async def test_unexpected_flow_failure_closes_client_without_logging_data(self):
        """Close faulty clients while keeping exception details and payloads out of logs."""
        async def failed_send(flow, writer):
            """Inject a private exception string to exercise sanitized error reporting."""
            raise RuntimeError("must-not-be-logged-payload")

        errors = io.StringIO()
        with patch.object(relay.Flow, "send", failed_send), contextlib.redirect_stderr(errors):
            reader, writer = await self.connect()
            writer.write(packet(destination("example.ru", 4000), b"private-payload"))
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
            await eventually(lambda: self.proxy.flow_count == 0)
        self.assertEqual(errors.getvalue(), "UDP relay flow failed unexpectedly\n")


class ConfigTests(unittest.TestCase):
    """Check file protection and local endpoint restrictions without opening sockets."""

    def test_protected_exact_local_schema(self):
        """Accept protected local settings and reject public, exposed or symlink inputs."""
        data = {"outbounds": [{"tag": "private-cascade-udp-relay", "protocol": "trojan",
                "settings": {"servers": [{"address": "127.0.0.1", "port": 30001, "password": PASSWORD}]},
                "streamSettings": {"network": "tcp", "security": "none"}}],
                "inbounds": [{"tag": "private-cascade-udp-dispatch", "protocol": "vless",
                "listen": "127.0.0.1", "port": 30002, "settings": {"clients": [{"id": str(CLIENT_ID)}],
                "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "none"}}]}
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "config.json"
            path.write_text(json.dumps(data))
            path.chmod(0o640)
            self.assertEqual(relay.Config.from_file(path), relay.Config(30001, 30002, PASSWORD, CLIENT_ID))
            path.chmod(0o644)
            with self.assertRaises(relay.ProtocolError):
                relay.Config.from_file(path)
            path.chmod(0o600)
            link = pathlib.Path(tmp) / "link.json"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                relay.Config.from_file(link)
            data["outbounds"][0]["settings"]["servers"][0]["address"] = "example.com"
            path.write_text(json.dumps(data))
            with self.assertRaises(relay.ProtocolError):
                relay.Config.from_file(path)


if __name__ == "__main__":
    unittest.main()

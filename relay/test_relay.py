import asyncio
import hashlib
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest
from padbridge_relay import Relay, packet, read_packet, HELLO, PRESENCE, ERROR, ENCRYPTED, KEEPALIVE


class RelayTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cert, key = root / "cert.pem", root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.server_context.minimum_version = ssl.TLSVersion.TLSv1_3
        cls.server_context.load_cert_chain(cert, key)
        cls.client_context = ssl.create_default_context(cafile=str(cert))
    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
    async def asyncSetUp(self):
        managed = self._testMethodName == "test_managed_host_proves_room_and_keeps_it_available"
        self.relay = Relay("" if managed else "a" * 64, managed=managed)
        self.server = await asyncio.start_server(self.relay.accept, "127.0.0.1", 0, ssl=self.server_context)
        self.port = self.server.sockets[0].getsockname()[1]
        self.writers = []
    async def asyncTearDown(self):
        for writer in self.writers:
            writer.close()
        for writer in self.writers:
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass
        self.server.close()
        await self.server.wait_closed()
        for _ in range(100):
            if self.relay.connections == 0:
                break
            await asyncio.sleep(0.01)
    async def connect(self, role, key="a" * 64, room="b" * 64, **options):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port, ssl=self.client_context, server_hostname="localhost")
        self.writers.append(writer)
        hello = {"role": role, "room": room, "key": key, "version": 2}
        hello.update(options)
        writer.write(packet(HELLO, json.dumps(hello).encode()))
        await writer.drain()
        return reader, writer
    async def test_managed_host_proves_room_and_keeps_it_available(self):
        key = hashlib.sha256(("PadBridge relay registration v3 " + "1" * 64).encode()).hexdigest()
        room = hashlib.sha256(key.encode()).hexdigest()
        denied, _ = await self.connect("host", room=room, version=3, key=room)
        self.assertEqual((await read_packet(denied))[0], ERROR)
        host, writer = await self.connect("host", room=room, version=3, key=key)
        self.assertEqual(await read_packet(host), (PRESENCE, b"\x00"))
        writer.write(packet(KEEPALIVE))
        await writer.drain()
        viewer, _ = await self.connect("viewer", managedRoom=room)
        self.assertEqual(await read_packet(viewer), (PRESENCE, b"\x01"))
        self.assertEqual(await read_packet(host), (PRESENCE, b"\x01"))
        body = os.urandom(128)
        writer.write(packet(ENCRYPTED, body))
        await writer.drain()
        self.assertEqual(await read_packet(viewer), (ENCRYPTED, body))
    async def test_tls_pair_forwards_opaque_packets_both_directions(self):
        host, host_writer = await self.connect("host")
        self.assertEqual(await read_packet(host), (PRESENCE, b"\x00"))
        viewer, viewer_writer = await self.connect("viewer")
        self.assertEqual(await read_packet(viewer), (PRESENCE, b"\x01"))
        self.assertEqual(await read_packet(host), (PRESENCE, b"\x01"))
        ciphertext = os.urandom(2048)
        host_writer.write(packet(ENCRYPTED, ciphertext)); await host_writer.drain()
        self.assertEqual(await read_packet(viewer), (ENCRYPTED, ciphertext))
        viewer_writer.write(packet(ENCRYPTED, ciphertext[::-1])); await viewer_writer.drain()
        self.assertEqual(await read_packet(host), (ENCRYPTED, ciphertext[::-1]))
        viewer_writer.close(); await viewer_writer.wait_closed()
        self.assertEqual(await read_packet(host), (PRESENCE, b"\x00"))
    async def test_rejects_wrong_host_key_and_unknown_room(self):
        reader, _ = await self.connect("host", key="c" * 64)
        self.assertEqual((await read_packet(reader))[0], ERROR)
        reader, _ = await self.connect("viewer")
        self.assertEqual((await read_packet(reader))[0], ERROR)
    async def test_rejects_duplicate_host_and_second_viewer(self):
        host, _ = await self.connect("host"); await read_packet(host)
        other, _ = await self.connect("host")
        self.assertEqual((await read_packet(other))[0], ERROR)
        viewer, _ = await self.connect("viewer"); await read_packet(viewer); await read_packet(host)
        other, _ = await self.connect("viewer")
        self.assertEqual((await read_packet(other))[0], ERROR)
    async def test_rejects_plaintext_and_cleans_up_room(self):
        host, writer = await self.connect("host"); await read_packet(host)
        writer.write(packet(5, b'{"action":"input"}')); await writer.drain()
        self.assertEqual((await read_packet(host))[0], ERROR)
        await host.read()
        self.assertNotIn("b" * 64, self.relay.rooms)
    async def test_rejects_unbounded_packet_and_invalid_config(self):
        with self.assertRaises(ValueError):
            Relay("short")
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port, ssl=self.client_context, server_hostname="localhost")
        self.writers.append(writer)
        writer.write(b"\xff\xff\xff\xff"); await writer.drain()
        self.assertEqual((await read_packet(reader))[0], ERROR)


if __name__ == "__main__":
    unittest.main()

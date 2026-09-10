import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from probe import (BoundaryError, Connection, MAX_FRAME_BYTES, MAX_INTERLEAVED_FRAMES,
                   probe, probe_app_tools, summarize, validate_endpoint)


def frame(message):
    data = json.dumps(message, ensure_ascii=False).encode()
    return struct.pack("<I", len(data)) + data


def receive(connection):
    def exact(count):
        data = b""
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise EOFError()
            data += chunk
        return data
    return json.loads(exact(struct.unpack("<I", exact(4))[0]))


def success(request, result):
    return {"type": "response", "requestId": request["requestId"], "method": request["method"],
            "resultType": "success", "handledByClientId": "test-owner", "result": result}


class Peer:
    def __init__(self, handler, connections=1):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "ipc.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.settimeout(2)
        self.listener.bind(str(self.path))
        self.path.chmod(0o600)
        self.listener.listen(4)
        self.errors = []

        def serve():
            try:
                for _ in range(connections):
                    connection, _ = self.listener.accept()
                    with connection:
                        connection.settimeout(2)
                        handler(connection)
            except (BrokenPipeError, ConnectionResetError):
                pass  # The bounded client deliberately closes rejected frames.
            except Exception as error:
                self.errors.append(error)

        self.thread = threading.Thread(target=serve, daemon=True)
        self.thread.start()

    def __enter__(self):
        return self

    def __exit__(self, kind, *_):
        self.thread.join(3)
        self.listener.close()
        self.directory.cleanup()
        if kind is None:
            if self.thread.is_alive():
                raise AssertionError("mock peer did not finish")
            if self.errors:
                raise self.errors[0]


class DesktopPreflightTests(unittest.TestCase):
    def assert_boundary(self, handler, expected, timeout=1):
        with Peer(handler) as peer, Connection(peer.path, timeout) as client:
            with self.assertRaises(BoundaryError) as raised:
                client.request("thread/list", {"limit": 1})
            self.assertEqual(raised.exception.code, expected)

    def test_fragmented_header_body_and_unicode(self):
        def handler(connection):
            request = receive(connection)
            for byte in frame(success(request, {"value": "Формула 👩🏽‍🏫"})):
                connection.sendall(bytes([byte]))
        with Peer(handler) as peer, Connection(peer.path) as client:
            response = client.request("thread/list", {"limit": 1})
        self.assertEqual(response["result"]["value"], "Формула 👩🏽‍🏫")

    def test_oversized_length_is_rejected_before_reading_body(self):
        def handler(connection):
            receive(connection)
            connection.sendall(struct.pack("<I", MAX_FRAME_BYTES + 1))
        self.assert_boundary(handler, "frame_size")

    def test_zero_length(self):
        def handler(connection):
            receive(connection)
            connection.sendall(b"\0\0\0\0")
        self.assert_boundary(handler, "frame_size")

    def test_truncated_body(self):
        def handler(connection):
            receive(connection)
            connection.sendall(struct.pack("<I", 10) + b"{")
        self.assert_boundary(handler, "peer_closed")

    def test_invalid_json_and_non_object(self):
        for data, expected in ((b"{", "invalid_json"), (b"[]", "invalid_message"),
                               (b'{"value":NaN}', "invalid_json"), (b"\xff", "invalid_json")):
            with self.subTest(data=data):
                def handler(connection):
                    receive(connection)
                    connection.sendall(struct.pack("<I", len(data)) + data)
                self.assert_boundary(handler, expected)

    def test_response_cannot_change_method(self):
        def handler(connection):
            request = receive(connection)
            response = success(request, {})
            response["method"] = "thread/start"
            connection.sendall(frame(response))
        self.assert_boundary(handler, "response_contract")

    def test_never_advertises_itself_as_an_agent_owner(self):
        def handler(connection):
            request = receive(connection)
            connection.sendall(frame({"type": "client-discovery-request", "requestId": "discovery"}))
            reply = receive(connection)
            self.assertEqual(reply, {"type": "client-discovery-response", "requestId": "discovery",
                                     "response": {"canHandle": False}})
            connection.sendall(frame(success(request, {"data": []})))
        with Peer(handler) as peer, Connection(peer.path) as client:
            self.assertEqual(client.request("thread/list", {})["status"], "available")

    def test_unsolicited_frames_are_bounded(self):
        def handler(connection):
            receive(connection)
            connection.sendall(frame({"type": "broadcast", "method": "unrelated"}) * MAX_INTERLEAVED_FRAMES)
        self.assert_boundary(handler, "interleaved_frame_budget")

    def test_interleaving_does_not_extend_deadline(self):
        def handler(connection):
            receive(connection)
            for _ in range(20):
                connection.sendall(frame({"type": "broadcast"}))
                time.sleep(0.02)
        with Peer(handler) as peer, Connection(peer.path, timeout=0.06) as client:
            started = time.monotonic()
            with self.assertRaises((BoundaryError, TimeoutError)):
                client.request("thread/list", {})
            self.assertLess(time.monotonic() - started, 1)

    def test_send_start_resume_and_stop_are_not_available(self):
        def handler(connection):
            self.assertEqual(connection.recv(1), b"")
        for method in ("thread/start", "thread/resume", "turn/start", "thread-follower-start-turn",
                       "thread-follower-interrupt-turn", "tools/call"):
            with self.subTest(method=method), Peer(handler) as peer, Connection(peer.path) as client:
                with self.assertRaises(BoundaryError) as raised:
                    client.request(method, {})
                self.assertEqual(raised.exception.code, "mutation_forbidden")

    def test_initialization_requires_matching_client_identity(self):
        def handler(connection):
            request = receive(connection)
            connection.sendall(frame(success(request, {"clientId": "different-owner"})))
        with Peer(handler) as peer, Connection(peer.path) as client:
            with self.assertRaisesRegex(BoundaryError, "initialization_contract"):
                client.initialize()

    def test_endpoint_rejects_symlink_permissions_and_wrong_uid(self):
        with tempfile.TemporaryDirectory() as directory:
            endpoint = Path(directory) / "ipc.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.bind(str(endpoint))
                endpoint.chmod(0o600)
                validate_endpoint(endpoint)
                link = Path(directory) / "link.sock"
                link.symlink_to(endpoint)
                with self.assertRaisesRegex(BoundaryError, "endpoint_type"):
                    validate_endpoint(link)
                endpoint.chmod(0o666)
                with self.assertRaisesRegex(BoundaryError, "endpoint_permissions"):
                    validate_endpoint(endpoint)
                endpoint.chmod(0o600)
                Path(directory).chmod(0o777)
                with self.assertRaisesRegex(BoundaryError, "endpoint_permissions"):
                    validate_endpoint(endpoint)
                Path(directory).chmod(0o1777)
                validate_endpoint(endpoint)
                Path(directory).chmod(0o700)
                with patch("probe.os.geteuid", return_value=os.geteuid() + 1):
                    with self.assertRaisesRegex(BoundaryError, "endpoint_owner"):
                        validate_endpoint(endpoint)

    def test_owner_alone_never_passes_catalogue_preflight(self):
        def handler(connection):
            init = receive(connection)
            connection.sendall(frame(success(init, {"clientId": "test-owner"})))
            request = receive(connection)
            if request["method"] == "thread-owner-discovery":
                self.assertEqual(request["version"], 1)
                response = success(request, {"supportsUntrustedAppInput": True})
            else:
                response = {"type": "response", "requestId": request["requestId"],
                            "resultType": "error", "error": "no-client-found"}
            connection.sendall(frame(response))
        with Peer(handler, connections=3) as peer:
            report = probe(peer.path, str(uuid.uuid4()))
        self.assertEqual(report["preflight"], "blocked")
        self.assertFalse(report["featureReady"])
        self.assertEqual(report["observations"]["owner"]["status"], "available")
        self.assertEqual(report["observations"]["catalogue"]["error"], "no-client-found")
        self.assertIn("sendMessage", report["notTested"])

    def test_successful_reads_are_not_full_feature_acceptance(self):
        def handler(connection):
            init = receive(connection)
            connection.sendall(frame(success(init, {"clientId": "test-owner"})))
            request = receive(connection)
            result = {"supportsUntrustedAppInput": True} if request["method"] == "thread-owner-discovery" else {
                "data": [{"text": "private task text"}], "tools": []}
            connection.sendall(frame(success(request, result)))
        with Peer(handler, connections=3) as peer:
            report = probe(peer.path, str(uuid.uuid4()))
        self.assertEqual(report["preflight"], "passed")
        self.assertFalse(report["featureReady"])
        self.assertNotIn("private task text", json.dumps(report))

    def test_owner_capability_is_not_coerced_from_a_string(self):
        result = summarize({"status": "available", "ownerClientID": "owner",
                            "result": {"supportsUntrustedAppInput": "true"}}, "owner")
        self.assertEqual(result["status"], "incompatible")

    def test_app_tools_peer_closure_is_not_a_claim_about_auth_reason(self):
        def handler(connection):
            request = receive(connection)
            self.assertEqual(request["method"], "tools/list")
        with Peer(handler) as peer:
            result = probe_app_tools(peer.path, timeout=1)
        self.assertEqual(result, {"status": "unavailable", "error": "peer_closed"})


if __name__ == "__main__":
    unittest.main()

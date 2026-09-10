#!/usr/bin/env python3
"""Read-only preflight for a connection to the existing Codex desktop owner.

This does not start Codex, resume a task, read rollout files, import credentials,
or claim that discovering an owner proves a working conversation bridge.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import json
import os
from pathlib import Path
import plistlib
import socket
import stat
import struct
import sys
import time
import uuid


MAX_FRAME_BYTES = 8 * 1024 * 1024
MAX_INTERLEAVED_FRAMES = 128
READ_METHODS = frozenset({"initialize", "thread-owner-discovery", "thread/list", "tools/list"})


class BoundaryError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def validate_endpoint(path: Path) -> None:
    """The last directory and socket belong to the same local OS user."""
    try:
        directory, endpoint = path.parent.lstat(), path.lstat()
    except OSError as error:
        raise BoundaryError("endpoint_unavailable") from error
    if not stat.S_ISDIR(directory.st_mode) or not stat.S_ISSOCK(endpoint.st_mode):
        raise BoundaryError("endpoint_type")
    if directory.st_uid != os.geteuid() or endpoint.st_uid != os.geteuid():
        raise BoundaryError("endpoint_owner")
    # Codex's separate app-tools pipe lives in a shared sticky directory.
    # The owned socket cannot be removed by another user there; getpeereid
    # still authenticates the actual connected process after pathname checks.
    unsafe_directory = directory.st_mode & 0o022 and not directory.st_mode & stat.S_ISVTX
    if unsafe_directory or endpoint.st_mode & 0o077:
        raise BoundaryError("endpoint_permissions")


def authenticate_peer(connection: socket.socket) -> None:
    if sys.platform == "darwin":
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        getpeereid = ctypes.CDLL(None, use_errno=True).getpeereid
        getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        getpeereid.restype = ctypes.c_int
        if getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise BoundaryError("peer_unavailable")
        peer_uid = uid.value
    elif hasattr(socket, "SO_PEERCRED"):
        _, peer_uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    else:
        raise BoundaryError("peer_authentication_unsupported")
    if peer_uid != os.geteuid():
        raise BoundaryError("peer_owner")


class Connection:
    def __init__(self, endpoint: Path, timeout: float = 5):
        validate_endpoint(endpoint)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.timeout = timeout
        self.client_id: str | None = None
        try:
            self.socket.settimeout(timeout)
            self.socket.connect(str(endpoint))
            authenticate_peer(self.socket)
        except Exception:
            self.socket.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.socket.close()

    def send(self, message: dict, deadline: float) -> None:
        encoded = json.dumps(message, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if not 0 < len(encoded) <= MAX_FRAME_BYTES:
            raise BoundaryError("frame_size")
        self.set_deadline(deadline)
        self.socket.sendall(struct.pack("<I", len(encoded)) + encoded)

    def set_deadline(self, deadline: float) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BoundaryError("deadline")
        self.socket.settimeout(remaining)

    def exact(self, count: int, deadline: float) -> bytes:
        chunks = bytearray()
        while len(chunks) < count:
            self.set_deadline(deadline)
            chunk = self.socket.recv(count - len(chunks))
            if not chunk:
                raise BoundaryError("peer_closed")
            chunks.extend(chunk)
        return bytes(chunks)

    def receive(self, deadline: float) -> dict:
        size = struct.unpack("<I", self.exact(4, deadline))[0]
        if not 0 < size <= MAX_FRAME_BYTES:
            raise BoundaryError("frame_size")
        try:
            message = json.loads(self.exact(size, deadline).decode("utf-8"),
                                 parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (UnicodeDecodeError, ValueError) as error:
            raise BoundaryError("invalid_json") from error
        if not isinstance(message, dict):
            raise BoundaryError("invalid_message")
        return message

    def request(self, method: str, params: dict, version: int = 0) -> dict:
        if method not in READ_METHODS:
            raise BoundaryError("mutation_forbidden")
        request_id = str(uuid.uuid4())
        deadline = time.monotonic() + self.timeout
        self.send({"type": "request", "requestId": request_id,
                   "sourceClientId": self.client_id or "initializing-client",
                   "method": method, "params": params, "version": version,
                   "timeoutMs": int(self.timeout * 1000)}, deadline)
        for _ in range(MAX_INTERLEAVED_FRAMES):
            message = self.receive(deadline)
            if message.get("type") == "client-discovery-request":
                discovery_id = message.get("requestId")
                if not isinstance(discovery_id, str):
                    raise BoundaryError("invalid_discovery")
                # The observer must never advertise itself as an agent owner.
                self.send({"type": "client-discovery-response", "requestId": discovery_id,
                           "response": {"canHandle": False}}, deadline)
            elif message.get("type") == "response" and message.get("requestId") == request_id:
                if message.get("resultType") == "error" and isinstance(message.get("error"), str):
                    return {"status": "unavailable", "error": message["error"][:256]}
                if (message.get("resultType") != "success" or message.get("method") != method
                        or not isinstance(message.get("result"), dict)
                        or not isinstance(message.get("handledByClientId"), str)
                        or not message["handledByClientId"]):
                    raise BoundaryError("response_contract")
                return {"status": "available", "ownerClientID": message["handledByClientId"],
                        "result": message["result"]}
        raise BoundaryError("interleaved_frame_budget")

    def initialize(self) -> None:
        response = self.request("initialize", {"clientType": "notebook-preflight-readonly"})
        client_id = response.get("result", {}).get("clientId")
        if not isinstance(client_id, str) or not client_id or client_id != response.get("ownerClientID"):
            raise BoundaryError("initialization_contract")
        self.client_id = client_id


def summarize(response: dict, capability: str) -> dict:
    """Never retain task text or a tool catalogue in the evidence report."""
    if response["status"] != "available":
        return response
    result = response["result"]
    if capability == "owner":
        if result.get("supportsUntrustedAppInput") is not True:
            return {"status": "incompatible", "error": "untrusted_input_not_supported"}
        return {"status": "available", "ownerClientID": response["ownerClientID"],
                "supportsUntrustedAppInput": True}
    key = "data" if capability == "catalogue" else "tools"
    if not isinstance(result.get(key), list):
        return {"status": "incompatible", "error": "catalogue_shape"}
    return {"status": "available", "count": len(result[key])}


def probe(endpoint: Path, thread_id: str, timeout: float = 5) -> dict:
    uuid.UUID(thread_id)
    observations = {}
    for key, method, params, version in (
        ("owner", "thread-owner-discovery", {"hostId": "local", "conversationId": thread_id}, 1),
        ("catalogue", "thread/list", {"limit": 1}, 0),
        ("appToolsOnRouter", "tools/list", {}, 0),
    ):
        try:
            with Connection(endpoint, timeout) as connection:
                connection.initialize()
                observations[key] = summarize(connection.request(method, params, version), key)
        except (BoundaryError, OSError) as error:
            observations[key] = {"status": "unavailable", "error": error_code(error)}
    ready = all(observations[key]["status"] == "available" for key in ("owner", "catalogue"))
    return {"schemaVersion": 1, "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "scope": "existing_desktop_owner_readonly", "threadID": thread_id,
            "preflight": "passed" if ready else "blocked", "featureReady": False,
            "observations": observations,
            "notTested": ["createTask", "openUnloadedTask", "sendMessage", "streamReply", "stopTurn",
                          "userApproval", "deliveryRecovery", "notebookTools", "physicalIPad"]}


def error_code(error: Exception) -> str:
    if isinstance(error, BoundaryError):
        return error.code
    if isinstance(error, TimeoutError):
        return "deadline"
    return type(error).__name__


def probe_app_tools(endpoint: Path, timeout: float) -> dict:
    """One ordinary client attempt; no signed-host impersonation or retry route."""
    try:
        with Connection(endpoint, timeout) as connection:
            deadline = time.monotonic() + timeout
            connection.send({"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                             "params": {"threadStartKind": "default"}}, deadline)
            result = connection.receive(deadline)
            if result.get("jsonrpc") != "2.0" or result.get("id") != 1:
                raise BoundaryError("response_contract")
            if "error" in result:
                return {"status": "unavailable", "error": "app_tools_rejected"}
            tools = result.get("result", {}).get("tools")
            if not isinstance(tools, list):
                raise BoundaryError("catalogue_shape")
            return {"status": "available", "count": len(tools)}
    except (BoundaryError, OSError) as error:
        return {"status": "unavailable", "error": error_code(error)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread", required=True, help="Existing local task UUID; no task is created or resumed")
    parser.add_argument("--socket", type=Path, default=Path.home() / ".codex/ipc/ipc.sock")
    parser.add_argument("--app-tools-socket", type=Path, help="Optional test-only endpoint supplied by the app owner")
    parser.add_argument("--app-bundle", type=Path, help="Read only version metadata, never application code")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("Use a fresh report path; an earlier receipt must not be overwritten")
    try:
        uuid.UUID(args.thread)
    except ValueError:
        parser.error("--thread must be a UUID")
    report = probe(args.socket, args.thread)
    if args.app_tools_socket:
        report["observations"]["appToolsExternalClient"] = probe_app_tools(args.app_tools_socket, 5)
    if args.app_bundle:
        with (args.app_bundle / "Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        report["desktopVersion"] = {key: info.get(key) for key in (
            "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("x", encoding="utf-8") as file:
        json.dump(report, file, ensure_ascii=False, indent=2)
        file.write("\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["preflight"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())

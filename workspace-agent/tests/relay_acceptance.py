"""Optional full Atermius WebSocket Relay leg for the two-node acceptance test."""

import base64
from contextlib import contextmanager
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import threading
import time
import uuid


def check(binary, root, workspace_port):
    import paramiko

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "integration"))
    from conftest import ApiClient, SigningKey
    from test_acceptance import _new_account_registration
    from test_relay import _websocket_handshake, _send_ticket

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    origin = f"http://127.0.0.1:{port}"
    db = root / "server-data"
    db.mkdir(mode=0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith("ATERMIUS_")}
    env.update(
        ATERMIUS_BIND=f"127.0.0.1:{port}",
        ATERMIUS_DATA_DIR=str(db),
        ATERMIUS_DATABASE_URL=f"sqlite://{db}/atermius.db?mode=rwc",
        ATERMIUS_RELAY_ENABLED="true",
        ATERMIUS_PUBLIC_ORIGIN=origin,
    )
    boot = subprocess.check_output(
        [binary, "bootstrap"], env=env, text=True, stderr=subprocess.PIPE
    )
    secret = re.findall(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", boot)[
        -1
    ]
    with (root / "api.log").open("wb") as log:
        proc = subprocess.Popen(
            [binary, "serve"], env=env, stdout=log, stderr=subprocess.STDOUT
        )
    ws = None
    try:
        api = ApiClient(origin)
        for _ in range(100):
            try:
                if api.request("GET", "/health/ready").status == 200:
                    break
            except OSError:
                pass
            time.sleep(0.1)
        else:
            raise AssertionError(
                f"Isolated Atermius Server did not become ready (process status {proc.poll()})"
            )
        keys = root / "api-keys"
        keys.mkdir(mode=0o700)
        device = str(uuid.uuid4())
        body = _new_account_registration(
            str(uuid.uuid4()),
            "ws-agent-test@example.test",
            device,
            base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="),
            SigningKey(keys, "owner"),
        )
        body["bootstrap_token"] = secret
        reg = api.request("POST", "/api/v1/auth/register", json_body=body)
        assert reg.status in (200, 201), reg.status
        ticket = api.request(
            "POST",
            "/api/v1/relay/tickets",
            token=reg.json()["access_token"],
            json_body={
                "device_id": device,
                "target_host": "192.0.2.11",
                "target_port": workspace_port,
            },
        )
        assert ticket.status == 200, ticket.status
        status, _, ws = _websocket_handshake(origin, origin)
        assert status == 101 and ws is not None
        _send_ticket(ws, ticket.json()["ticket"])
        with _relay_socket(ws) as local:
            transport = paramiko.Transport(local)
            try:
                transport.start_client(timeout=8)
                expected = paramiko.HostKeys(str(root / "known_hosts")).lookup(
                    f"[127.0.0.1]:{workspace_port}"
                )
                assert expected["ssh-ed25519"] == transport.get_remote_server_key()
                transport.auth_publickey(
                    "sandbox",
                    paramiko.Ed25519Key.from_private_key_file(str(root / "key")),
                )
                channel = transport.open_session(timeout=8)
                channel.settimeout(8)
                channel.exec_command("id -u")
                assert channel.makefile("rb").read().strip() == b"1000"
                assert channel.recv_exit_status() == 0
            finally:
                transport.close()
        print(
            "Authenticated Atermius API ticket and browser Relay WebSocket reached the workspace over SSH.",
            flush=True,
        )
    finally:
        if ws:
            ws.close()
        proc.terminate()
        proc.wait(timeout=10)


@contextmanager
def _relay_socket(ws):
    client, bridge = socket.socketpair()

    def transmit():
        try:
            while data := bridge.recv(16384):
                ws.send(2, data)
        except OSError:
            pass

    def receive():
        try:
            while True:
                opcode, data = ws.receive()
                if opcode != 2:
                    break
                bridge.sendall(data)
        except (OSError, EOFError, AssertionError):
            pass
        finally:
            try:
                bridge.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    threads = [threading.Thread(target=f, daemon=True) for f in (transmit, receive)]
    for thread in threads:
        thread.start()
    try:
        yield client
    finally:
        client.close()
        try:
            ws.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        for thread in threads:
            thread.join(timeout=2)
        bridge.close()

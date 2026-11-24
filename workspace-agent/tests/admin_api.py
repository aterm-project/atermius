#!/usr/bin/env python3
"""Disposable native Admin API/Hub acceptance. Optionally drive the compiled Web UI in Chromium."""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "integration"))
from conftest import ApiClient  # noqa: E402
from test_acceptance import _register_with_token  # noqa: E402

API = "/api/v1/admin/workspace-agents"


def run(args, **kw):
    return subprocess.run(
        list(map(str, args)),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kw,
    )


def wait(fn, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            value = fn()
            if value:
                return value
        except OSError:
            pass
        time.sleep(0.15)
    raise AssertionError("timed out waiting for isolated service")


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def execute(args, root):
    os.chmod(root, 0o700)
    server, hub = args.server.resolve(), args.agent.resolve()
    manage = ROOT / "workspace-agent/deploy/provision.py"
    proc = {}

    def launch(name, cmd, env=None):
        with (root / (name + ".log")).open("ab") as log:
            proc[name] = subprocess.Popen(
                list(map(str, cmd)), env=env, stdout=log, stderr=log
            )

    def stop(name):
        p = proc.pop(name, None)
        if p:
            p.terminate()
            try:
                p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    sock = root / "admin.sock"
    hp, sp, entry = port(), port(), port()
    origin = f"http://127.0.0.1:{sp}"
    username = "agent-admin-" + uuid.uuid4().hex[:8] + "@example.test"
    state = root / "hub-state"
    run([manage, "init", state, "--hostname", "localhost"])
    realm = (state / "realm").read_text().strip()
    clean = {k: v for k, v in os.environ.items() if not k.startswith("ATERMIUS_")}
    data = root / "data"
    data.mkdir(mode=0o700)
    env = dict(
        clean,
        ATERMIUS_BIND=f"127.0.0.1:{sp}",
        ATERMIUS_DATA_DIR=str(data),
        ATERMIUS_DATABASE_URL=f"sqlite://{data}/atermius.db?mode=rwc",
        ATERMIUS_REGISTRATION_OPEN="false",
        ATERMIUS_ADMIN_USERNAMES=username,
        ATERMIUS_PUBLIC_ORIGIN=origin,
    )
    if args.web_root:
        env["ATERMIUS_WEB_DIR"] = str(args.web_root.resolve())
    if args.postgres_url:
        parsed = urlsplit(args.postgres_url)
        assert parsed.path.lstrip("/").startswith("atermius_test_"), (
            "use a disposable test database"
        )
        schema = "wa_" + uuid.uuid4().hex

        def psql(sql):
            return run(
                [
                    "psql",
                    "-X",
                    "-w",
                    "-A",
                    "-t",
                    "-q",
                    "-v",
                    "ON_ERROR_STOP=1",
                    args.postgres_url,
                ],
                input=sql.encode(),
            ).stdout.decode()

        migrations = "\n".join(
            p.read_text()
            for p in sorted((ROOT / "server/migrations/postgres").glob("[0-9]*.sql"))
        )
        psql(f"CREATE SCHEMA {schema}; SET search_path TO {schema};\n" + migrations)
        for name in ["signing", "rate", "mfa"]:
            (root / name).write_bytes(os.urandom(32))
        (root / "objects").mkdir()
        env.update(
            ATERMIUS_SYNC_BACKEND="postgres",
            ATERMIUS_SYNC_PG_URL=args.postgres_url,
            ATERMIUS_SYNC_PG_SCHEMA=schema,
            ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE=str(root / "signing"),
            ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE=str(root / "rate"),
            ATERMIUS_MFA_ENCRYPTION_KEY_FILE=str(root / "mfa"),
            ATERMIUS_OBJECT_STORE_BACKEND="filesystem",
            ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT=str(root / "objects"),
        )
    api = ApiClient(origin)

    def start_server(configured):
        launch(
            "server",
            [server, "serve"],
            env=dict(
                env,
                **(
                    {"ATERMIUS_WORKSPACE_ADMIN_SOCKET": str(sock)} if configured else {}
                ),
            ),
        )
        wait(lambda: api.request("GET", "/health/ready").status == 200)

    def start_hub():
        launch(
            "hub",
            [hub, "hub", state / "hub", f"127.0.0.1:{hp}", "127.0.0.1"],
            env=dict(clean, ATERMIUS_WORKSPACE_ADMIN_SOCKET=str(sock)),
        )
        wait(sock.exists)

    try:
        start_hub()
        start_server(True)
        assert api.request("GET", API).status == 401
        assert (
            "workspace_agent_admin_v1"
            in api.request("GET", "/api/v1/instance").json()["capabilities"]
        )
        token = re.findall(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])",
            run([server, "bootstrap"], env=env, text=True).stdout,
        )[-1]
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", root / "user-key"])
        records = {}
        for n in ["alpha", "beta"]:
            f = root / (n + ".private.tar")
            opts = [
                manage,
                "enroll",
                state,
                "--prepare-only",
                "--binary",
                hub,
                "--node",
                n,
                "--server",
                f"https://localhost:{hp}",
                "--output",
                f,
            ]
            opts += ["--image", args.image, "--host-ssh-port", "22"]
            if n == "alpha":
                opts += [
                    "--cluster",
                    "engineering",
                    "--keys",
                    root / "user-key.pub",
                    "--port",
                    str(entry),
                ]
            run(opts)
            records[n] = json.loads(Path(str(f) + ".public.json").read_text())
            assert not json.loads(run([hub, "status", state / "hub"]).stdout)["nodes"]
            directory = root / n
            directory.mkdir()
            import tarfile

            with tarfile.open(f) as archive:
                for path in ["ca.crt", "node.crt", "node.key", "agent.json"]:
                    (directory / path).write_bytes(archive.extractfile(path).read())

        def agent(n):
            launch(n, [hub, "run", root / n, root / (n + "-state")], clean)

        agent("alpha")
        if args.web_root:
            (root / "browser.json").write_text(
                json.dumps(
                    dict(
                        origin=origin,
                        username=username,
                        bootstrap=token,
                        port=entry,
                        extra_port=port(),
                        host_port=port(),
                    )
                )
            )
            p = subprocess.Popen(
                ["node", str(Path(__file__).with_name("admin_browser.cjs")), str(root)]
            )
            try:
                end = time.monotonic() + 300
                while p.poll() is None:
                    if (root / "start-beta").exists() and "beta" not in proc:
                        agent("beta")
                    if time.monotonic() > end:
                        raise TimeoutError("browser acceptance")
                    time.sleep(0.2)
                assert p.returncode == 0, "browser acceptance failed"
            finally:
                if p.poll() is None:
                    p.terminate()
                    p.wait(timeout=10)
            admin_token = (root / "admin.token").read_text()
        else:
            admin_token = _register_with_token(
                api,
                username=username,
                key_dir=root / "keys",
                label="owner",
                bootstrap=token,
            )["access_token"]

        def get():
            return api.request("GET", API, token=admin_token)

        def action(command, expected=200):
            result = api.request("POST", API, token=admin_token, json_body=command)
            assert result.status == expected, (
                command["action"],
                result.status,
                result.json().get("error", {}).get("code"),
            )
            return result.json()

        if not args.web_root:
            assert get().json()["nodes"] == []
            for n in ["alpha", "beta"]:
                action({"action": "register_node", "registration": records[n]})
            wait(lambda: get().json()["clusters"][0]["phase"] == "Running")
            action(
                {
                    "action": "migrate",
                    "cluster": "engineering",
                    "destination": "beta",
                    "expected_generation": 1,
                }
            )
            wait(lambda: get().json()["clusters"][0]["phase"] == "Restore")
            action(
                {"action": "abort", "cluster": "engineering", "expected_generation": 2}
            )
            agent("beta")
            wait(lambda: get().json()["clusters"][0]["phase"] == "Running")
            gen = get().json()["clusters"][0]["generation"]
            action(
                {
                    "action": "migrate",
                    "cluster": "engineering",
                    "destination": "beta",
                    "expected_generation": gen,
                }
            )
            wait(
                lambda: (
                    get().json()["clusters"][0]["node"] == "beta"
                    and get().json()["clusters"][0]["phase"] == "Running"
                )
            )
        view = get().json()
        assert (
            view["configured"]
            and "authorized_keys" not in json.dumps(view)
            and "PRIVATE KEY" not in json.dumps(view)
        )
        action(
            {
                "action": "set_node_enabled",
                "node": "beta",
                "enabled": False,
                "expected_revision": 99999,
            },
            409,
        )
        action(
            {
                "action": "migrate",
                "cluster": "engineering",
                "destination": "alpha",
                "expected_generation": 1,
            },
            409,
        )
        action(
            {
                "action": "create_workspace",
                "cluster": "invalid",
                "node": "alpha",
                "port": 24023,
                "authorized_keys": "private-key",
            },
            400,
        )
        duplicate = dict(records["alpha"], node="other", fingerprint="e" * 64)
        action({"action": "register_node", "registration": duplicate}, 409)
        assert "other" not in [n["name"] for n in get().json()["nodes"]]
        # Ordinary authenticated account (the same checked path used by the admin UI).
        membername = "member-" + uuid.uuid4().hex[:8] + "@example.test"
        invite = run(
            [server, "create-account-invite", "--username", membername],
            env=env,
            text=True,
        ).stdout
        invitation = re.findall(
            r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])", invite
        )[-1]
        member = _register_with_token(
            api,
            username=membername,
            key_dir=root / "keys",
            label="member",
            invitation=invitation,
        )["access_token"]
        assert api.request("GET", API, token=member).status == 403
        assert (
            api.request(
                "POST",
                API,
                token=member,
                json_body={
                    "action": "abort",
                    "cluster": "engineering",
                    "expected_generation": 1,
                },
            ).status
            == 403
        )
        if not args.postgres_url:
            with sqlite3.connect(data / "atermius.db") as db:
                actions = {
                    r[0]
                    for r in db.execute(
                        "SELECT action FROM audit_events WHERE action LIKE 'admin.workspace_%'"
                    )
                }
        else:
            actions = set(
                psql(
                    f"SELECT action FROM {schema}.audit_events WHERE action LIKE 'admin.workspace_%'"
                ).splitlines()
            )
        assert {
            "admin.workspace_register_requested",
            "admin.workspace_migrate_accepted",
            "admin.workspace_abort_accepted",
            "admin.workspace_disable_rejected",
        } <= actions, actions
        stop("hub")
        assert get().status == 503
        stop("server")
        start_server(False)
        assert get().json() == {
            "configured": False,
            "nodes": [],
            "clusters": [],
            "ssh_host": None,
        }
        assert api.request("GET", API, token=member).status == 403
        print(
            "Native Admin API: real registration, migration, abort, role checks, stale state, audit and disabled/offline Hub passed.",
            flush=True,
        )
    finally:
        for n in list(proc):
            stop(n)
        if args.postgres_url:
            psql(f"DROP SCHEMA {schema} CASCADE")
        for kind in ["container", "volume"]:
            items = run(
                [
                    "docker",
                    kind,
                    "ls",
                    "-q",
                    *(["-a"] if kind == "container" else []),
                    "--filter",
                    "label=com.atermius.workspace",
                ]
            ).stdout.split()
            for item in items:
                uid = item.decode()
                field = ".Config.Labels" if kind == "container" else ".Labels"
                o = subprocess.run(
                    [
                        "docker",
                        kind,
                        "inspect",
                        "--format",
                        "{{index " + field + ' "com.atermius.workspace"}}',
                        uid,
                    ],
                    capture_output=True,
                )
                if o.stdout.decode().strip().startswith(realm + "/"):
                    subprocess.run(
                        [
                            "docker",
                            kind,
                            "rm",
                            *(["-f"] if kind == "container" else []),
                            uid,
                        ],
                        capture_output=True,
                    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server", required=True, type=Path)
    p.add_argument("--agent", required=True, type=Path)
    p.add_argument("--image", required=True)
    p.add_argument("--web-root", type=Path)
    p.add_argument("--postgres-url", help="empty disposable PostgreSQL database only")
    p.add_argument("--work-dir", type=Path)
    args = p.parse_args()
    os.umask(0o077)
    with tempfile.TemporaryDirectory(dir=args.work_dir) as tmp:
        execute(args, Path(tmp))

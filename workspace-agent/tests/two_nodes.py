#!/usr/bin/env python3
"""End-to-end test with real mTLS, two agents, Docker volumes and an OpenSSH client."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tarfile
import tempfile
import time


def run(*args, check=True, timeout=90, **kw):
    return subprocess.run(
        list(map(str, args)),
        check=check,
        timeout=timeout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kw,
    )


def eventually(fn, timeout=75):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = fn()
            if last:
                return last
        except (OSError, subprocess.SubprocessError) as err:
            last = err
        time.sleep(0.25)
    raise AssertionError(f"timed out: {last!r}")


def ports(n):
    sockets = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            sockets.append(s)
        return [s.getsockname()[1] for s in sockets]
    finally:
        for s in sockets:
            s.close()


def test(binary, image, root, server_binary=None):
    bind = "127.0.0.1"
    if server_binary:
        # The suite only binds all addresses in its disposable, loopback-only network namespace.
        links = json.loads(run("ip", "-j", "link").stdout)
        assert [link["ifname"] for link in links] == ["lo"]
        with socket.socket() as probe:
            probe.bind(("192.0.2.11", 0))
        bind = "0.0.0.0"
    scripts = Path(__file__).resolve().parents[1] / "deploy"
    state = root / "instance"
    hub_port, ssh_port, other_port, host_port = ports(4)
    run(scripts / "provision.py", "init", state, "--hostname", "localhost")
    realm = (state / "realm").read_text().strip()
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", root / "key")
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", root / "other-key")
    for node in ["alpha", "beta", "host-only"]:
        bundle = root / (node + ".tar")
        cmd = [
            scripts / "provision.py",
            "enroll",
            state,
            "--binary",
            binary,
            "--server",
            f"https://localhost:{hub_port}",
            "--node",
            node,
            "--output",
            bundle,
        ]
        cmd += (
            ["--host-ssh-port", other_port]
            if node == "host-only"
            else ["--image", image]
        )
        if node == "alpha":
            cmd += ["--cluster", "lab", "--keys", root / "key.pub", "--port", ssh_port]
        run(*cmd)
        config = root / node
        config.mkdir()
        with tarfile.open(bundle) as archive:
            for member in ["agent.json", "ca.crt", "node.crt", "node.key"]:
                (config / member).write_bytes(archive.extractfile(member).read())
        bundle.unlink()
    processes = {}
    logs = {}

    def start(id):
        command = (
            [binary, "hub", state / "hub", f"127.0.0.1:{hub_port}", bind]
            if id == "hub"
            else [binary, "run", root / id, root / (id + "-state")]
        )
        log = (root / (id + ".log")).open("ab")
        logs[id] = log
        processes[id] = subprocess.Popen(
            list(map(str, command)),
            stdout=log,
            stderr=log,
            env=dict(os.environ, PATH="/no-docker-here") if id == "host-only" else None,
        )

    def stop(id):
        proc = processes.pop(id)
        proc.terminate()
        proc.wait(timeout=8)
        logs.pop(id).close()

    def cli(*args):
        return run(binary, args[0], state / "hub", *args[1:]).stdout

    def state_of():
        return next(
            c for c in json.loads(cli("status"))["clusters"] if c["cluster"] == "lab"
        )

    def phase(name, node=None):
        c = state_of()
        return c if c["phase"] == name and (node is None or c["node"] == node) else None

    def ssh(command, known=True, port=ssh_port):
        key = root / ("other-key" if port in (other_port, host_port) else "key")
        return run(
            "ssh",
            "-q",
            "-i",
            key,
            "-p",
            port,
            "-oBatchMode=yes",
            "-oIdentitiesOnly=yes",
            "-oConnectTimeout=5",
            "-oServerAliveInterval=4",
            "-oServerAliveCountMax=2",
            "-oStrictHostKeyChecking=" + ("yes" if known else "accept-new"),
            "-oUserKnownHostsFile=" + str(root / "known_hosts"),
            "sandbox@127.0.0.1",
            command,
            timeout=15,
        )

    try:
        start("alpha")
        start("beta")
        start("hub")
        eventually(lambda: phase("Running", "alpha"))
        known = eventually(lambda: ssh("id -u", False).stdout.strip())
        assert known == b"1000"
        print("First enrollment provisioned a usable SSH workspace.", flush=True)
        if server_binary:
            from relay_acceptance import check

            check(server_binary.resolve(), root, ssh_port)

        # Also keep a second cluster running on alpha during the move.
        cli("create", "neighbor", "alpha", other_port, root / "other-key.pub")
        eventually(lambda: ssh("true", False, other_port))
        cli("publish-host", "external-host", "host-only", host_port)
        start("host-only")
        eventually(lambda: ssh("id -u", False, host_port).stdout.strip() == b"1000")
        print(
            "Separate outbound host-only agent carried SSH with no Docker executable.",
            flush=True,
        )
        denied = run(
            "ssh",
            "-q",
            "-i",
            root / "key",
            "-p",
            other_port,
            "-oBatchMode=yes",
            "-oIdentitiesOnly=yes",
            "-oStrictHostKeyChecking=yes",
            "-oUserKnownHostsFile=" + str(root / "known_hosts"),
            "sandbox@127.0.0.1",
            "true",
            check=False,
        )
        assert denied.returncode != 0
        # A valid certificate cannot announce a different registered node name.
        forged = root / "wrong-identity"
        forged.mkdir()
        for filename in ["node.crt", "node.key", "ca.crt"]:
            (forged / filename).write_bytes((root / "beta" / filename).read_bytes())
        config = json.loads((root / "beta/agent.json").read_text())
        config["node"] = "alpha"
        (forged / "agent.json").write_text(json.dumps(config))
        with (root / "wrong.log").open("wb") as log:
            candidate = subprocess.Popen(
                [binary, "run", forged, root / "wrong-state"], stdout=log, stderr=log
            )
            try:
                eventually(
                    lambda: b"identity mismatch" in (root / "wrong.log").read_bytes(),
                    15,
                )
            finally:
                candidate.terminate()
                candidate.wait(timeout=5)
        payload = os.urandom(100000)
        command = [
            "sftp",
            "-q",
            "-P",
            str(ssh_port),
            "-i",
            str(root / "key"),
            "-oBatchMode=yes",
            "-oStrictHostKeyChecking=yes",
            "-oUserKnownHostsFile=" + str(root / "known_hosts"),
            "-b",
            "-",
            "sandbox@127.0.0.1",
        ]
        (root / "payload").write_bytes(payload)
        run(
            *command,
            input=f"put {root}/payload .payload\nchmod 640 .payload\n".encode(),
        )
        assert (
            ssh("ln -s .payload pointer && sha256sum pointer")
            .stdout.split()[0]
            .decode()
            == hashlib.sha256(payload).hexdigest()
        )
        original_key = (root / "known_hosts").read_bytes()
        # Observe an interrupted handoff and durable desired state before starting the destination.
        stop("beta")
        cli("migrate", "lab", "beta")
        cli("migrate", "lab", "beta")
        eventually(lambda: phase("Restore", "alpha"))
        assert (
            run(
                binary, "migrate", state / "hub", "lab", "alpha", check=False
            ).returncode
            != 0
        )
        assert (
            run(
                "ssh",
                "-q",
                "-oBatchMode=yes",
                "-oConnectTimeout=2",
                "-p",
                ssh_port,
                "sandbox@127.0.0.1",
                "true",
                check=False,
            ).returncode
            != 0
        )
        assert ssh("test ! -f .payload", port=other_port).returncode == 0
        stop("hub")
        start("hub")
        start("beta")
        eventually(lambda: phase("Running", "beta"))
        eventually(lambda: state_of()["pending_cleanup"] == 0)
        assert ssh(
            'sha256sum pointer; stat -c "%a %u" .payload'
        ).stdout.decode().splitlines() == [
            hashlib.sha256(payload).hexdigest() + "  pointer",
            "640 1000",
        ]
        assert (root / "known_hosts").read_bytes() == original_key
        print(
            "Source fenced, hub restarted, same SSH endpoint and host key; files, symlink and permissions preserved.",
            flush=True,
        )
        # Return to the original agent, with a new file written after the first move.
        ssh("printf after-move > roundtrip")
        cli("migrate", "lab", "alpha")
        eventually(lambda: phase("Running", "alpha"))
        eventually(lambda: state_of()["pending_cleanup"] == 0)
        assert ssh("cat roundtrip").stdout == b"after-move"
        # Corrupt a staged snapshot. Destination must not start; abort fences it before resuming the source.
        stop("beta")
        cli("migrate", "lab", "beta")
        eventually(lambda: phase("Restore"))
        (blob,) = list((state / "hub").glob("snapshot-lab-*.tar"))
        with blob.open("r+b") as f:
            f.write(b"broken")
        start("beta")
        eventually(
            lambda: b"snapshot verification failed" in (root / "beta.log").read_bytes()
        )
        assert phase("Restore", "alpha")
        cli("abort", "lab")
        eventually(lambda: phase("Running", "alpha"))
        eventually(lambda: state_of()["pending_cleanup"] == 0)
        assert ssh("cat roundtrip").stdout == b"after-move"
        assert not list((state / "hub").glob("snapshot-*.tar"))
        print(
            "Return migration and verified rollback after a damaged snapshot passed.",
            flush=True,
        )
        cli("disable", "alpha")
        eventually(
            lambda: (
                not next(
                    n
                    for n in json.loads(cli("status"))["nodes"]
                    if n["name"] == "alpha"
                )["online"]
            )
        )
        try:
            ssh("true")
        except subprocess.SubprocessError:
            pass
        else:
            raise AssertionError("disabled node still accepted SSH")
        cli("enable", "alpha")
        eventually(lambda: ssh("true"), 35)
    except BaseException:
        for log in root.glob("*.log"):
            print(log.name, log.read_text(errors="replace")[-2400:], flush=True)
        raise
    finally:
        for id in list(processes):
            stop(id)
        for kind in ("container", "volume"):
            listed = run(
                "docker",
                kind,
                "ls",
                "-q",
                *(["-a"] if kind == "container" else []),
                "--filter",
                "label=com.atermius.workspace",
            ).stdout.split()
            for item in listed:
                uid = item.decode()
                label = run(
                    "docker",
                    kind,
                    "inspect",
                    "--format",
                    "{{ index "
                    + (".Config.Labels" if kind == "container" else ".Labels")
                    + ' "com.atermius.workspace" }}',
                    uid,
                    check=False,
                )
                if label.stdout.decode().strip().startswith(realm + "/"):
                    run(
                        "docker",
                        kind,
                        "rm",
                        *(["-f"] if kind == "container" else []),
                        uid,
                        check=False,
                    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", type=Path, required=True)
    p.add_argument("--image", required=True)
    p.add_argument("--work-dir", type=Path)
    p.add_argument(
        "--server-binary",
        type=Path,
        help="also test the browser Relay inside an isolated network namespace",
    )
    args = p.parse_args()
    with tempfile.TemporaryDirectory(dir=args.work_dir) as d:
        test(args.binary.resolve(), args.image, Path(d), args.server_binary)

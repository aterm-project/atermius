#!/usr/bin/env python3
"""Prepare the hub identity and private one-command node enrollment bundles."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit
import uuid


def run(*args, capture=False):
    return subprocess.run(
        list(map(str, args)), check=True, stdout=subprocess.PIPE if capture else None
    ).stdout


def issue(directory, ca, subject, purpose, san):
    key, csr, cert = (
        directory / f"{subject}.{suffix}" for suffix in ("key", "csr", "crt")
    )
    run(
        "openssl",
        "req",
        "-new",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:P-256",
        "-nodes",
        "-keyout",
        key,
        "-out",
        csr,
        "-subj",
        "/CN=" + subject,
    )
    ext = directory / "leaf.ext"
    ext.write_text(
        f"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage={purpose}\nsubjectAltName={san}\n"
    )
    run(
        "openssl",
        "x509",
        "-req",
        "-in",
        csr,
        "-CA",
        ca / "ca.crt",
        "-CAkey",
        ca / "ca.key",
        "-set_serial",
        str(uuid.uuid4().int),
        "-days",
        "365",
        "-sha256",
        "-extfile",
        ext,
        "-out",
        cert,
    )
    csr.unlink()
    ext.unlink()


def init(args):
    root = args.root.resolve()
    host = args.hostname
    try:
        san = "IP:" + str(ipaddress.ip_address(host))
    except ValueError:
        if not re.fullmatch(r"[a-zA-Z0-9.-]{1,253}", host):
            raise ValueError("invalid hub hostname")
        san = "DNS:" + host
    # Publish a complete identity atomically. Re-running never replaces an existing CA.
    root.parent.mkdir(parents=True, exist_ok=True)
    if root.exists():
        raise ValueError(f"already exists: {root}")
    with tempfile.TemporaryDirectory(dir=root.parent) as temp:
        path = Path(temp) / "instance"
        ca, hub = path / "authority", path / "hub"
        ca.mkdir(parents=True)
        hub.mkdir()
        (path / "nodes").mkdir()
        run(
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-nodes",
            "-keyout",
            ca / "ca.key",
            "-out",
            ca / "ca.crt",
            "-days",
            "3650",
            "-subj",
            "/CN=Atermius workspace CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
        )
        issue(hub, ca, "hub", "serverAuth", san)
        shutil.copyfile(ca / "ca.crt", hub / "ca.crt")
        (path / "realm").write_text(str(uuid.uuid4()))
        (hub / "state.lock").touch()
        if args.hub_uid is not None or args.hub_gid is not None:
            for entry in [*hub.iterdir(), hub]:
                os.chown(
                    entry,
                    args.hub_uid if args.hub_uid is not None else -1,
                    args.hub_gid if args.hub_gid is not None else -1,
                )
        path.rename(root)
    print(f"Hub state: {root}/hub. Keep {root}/authority offline from the hub service.")


def enroll(args):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", args.node):
        raise ValueError("invalid node name")
    endpoint = urlsplit(args.server)
    if (
        endpoint.scheme != "https"
        or not endpoint.hostname
        or endpoint.username
        or endpoint.password
        or endpoint.path not in ("", "/")
        or endpoint.query
        or endpoint.fragment
    ):
        raise ValueError("use the https://host:port of the workspace hub")
    if bool(args.cluster) != bool(args.keys) or bool(args.cluster) != bool(args.port):
        raise ValueError("--cluster, --keys and --port go together")
    if not args.image and not args.host_ssh_port:
        raise ValueError("supply a workspace image or opt in to the local SSH service")
    if args.cluster and not args.image:
        raise ValueError("automatic workspace creation requires --image")
    image = ""
    if args.image:
        image = (
            run(
                "docker",
                "image",
                "inspect",
                "--format",
                "{{.Id}}",
                args.image,
                capture=True,
            )
            .decode()
            .strip()
        )
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", image):
            raise ValueError("could not resolve workspace image")
    root = args.root.resolve()
    directory = root / "nodes" / args.node
    if not directory.exists():
        with tempfile.TemporaryDirectory(dir=root / "nodes") as temp:
            fresh = Path(temp) / "identity"
            fresh.mkdir()
            issue(
                fresh,
                root / "authority",
                "node",
                "clientAuth",
                "URI:urn:atermius:node:" + args.node,
            )
            fresh.rename(directory)
    der = run(
        "openssl",
        "x509",
        "-outform",
        "DER",
        "-in",
        directory / "node.crt",
        capture=True,
    )
    binary = args.binary.resolve()
    if not binary.is_file():
        raise ValueError("supply the built Linux agent binary")
    registration = [
        binary,
        "register",
        root / "hub",
        args.node,
        hashlib.sha256(der).hexdigest(),
        image or "-",
        args.network,
        str(bool(args.host_ssh_port)).lower(),
    ]
    if args.cluster:
        registration.extend([args.cluster, args.port, args.keys])
    config = dict(
        node=args.node,
        endpoint=args.server.rstrip("/"),
        realm=(root / "realm").read_text().strip(),
        image=image,
        network=args.network,
        host_ssh_port=args.host_ssh_port,
    )
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        tmp = Path(temp)
        (tmp / "agent.json").write_text(json.dumps(config))
        entries = {
            "agent.json": tmp / "agent.json",
            "ca.crt": root / "authority/ca.crt",
            "node.key": directory / "node.key",
            "node.crt": directory / "node.crt",
            "atermius-agent": binary,
        }
        if image:
            run("docker", "image", "save", "-o", tmp / "workspace-image.tar", image)
            entries["workspace-image.tar"] = tmp / "workspace-image.tar"
        with tarfile.open(tmp / "bundle.tar", "w") as tar:
            for name, file in entries.items():
                tar.add(file, arcname=name, recursive=False)
        run(*registration)
        os.replace(tmp / "bundle.tar", output)
    print(f"Private enrollment bundle ready: {output}")


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init")
    i.add_argument("root", type=Path)
    i.add_argument("--hostname", required=True)
    i.add_argument("--hub-uid", type=int)
    i.add_argument("--hub-gid", type=int)
    e = sub.add_parser("enroll")
    e.add_argument("root", type=Path)
    e.add_argument("--binary", type=Path, required=True)
    e.add_argument("--node", required=True)
    e.add_argument("--server", required=True)
    e.add_argument("--output", type=Path, required=True)
    e.add_argument("--image")
    e.add_argument(
        "--network",
        default="none",
        help="operator-approved egress bridge on every eligible node",
    )
    e.add_argument("--cluster")
    e.add_argument("--port", type=int)
    e.add_argument("--keys", type=Path)
    e.add_argument("--host-ssh-port", type=int, choices=range(1, 65536), metavar="PORT")
    args = p.parse_args()
    (init if args.cmd == "init" else enroll)(args)


if __name__ == "__main__":
    main()

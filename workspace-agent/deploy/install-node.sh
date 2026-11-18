#!/bin/bash
# Run on a Debian Linux systemd host with a bundle obtained from your administrator.
set -euo pipefail
umask 077
[[ $(id -u) == 0 && $# == 1 && -f "$1" ]] || { echo 'Usage: sudo ./install-node.sh PRIVATE-BUNDLE.tar' >&2; exit 2; }
bundle=$(realpath "$1")
exec 9>/run/lock/atermius-agent-install.lock
flock -x 9
command -v systemctl >/dev/null
if ! command -v python3 >/dev/null; then apt-get update && apt-get install -y python3; fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
python3 - "$bundle" "$stage" <<'PY'
import pathlib,tarfile,shutil,sys,json
out=pathlib.Path(sys.argv[2])
required={'atermius-agent','node.key','node.crt','ca.crt','agent.json'}
seen=set()
with tarfile.open(sys.argv[1],'r:') as t:
 for item in t:
  if item.name not in required|{'workspace-image.tar'} or item.name in seen or not item.isfile() or item.size<=0:
   raise SystemExit('Invalid bundle member')
  with t.extractfile(item) as src, (out/item.name).open('xb') as dest: shutil.copyfileobj(src,dest)
  seen.add(item.name)
if not required<=seen or bool(json.loads((out/'agent.json').read_text())['image'])!=('workspace-image.tar' in seen): raise SystemExit('Incomplete node bundle')
PY
cfg=/etc/atermius-agent
# Reinstalling on a host must never silently give its existing volumes another identity.
if [[ -e $cfg/current/agent.json ]]; then
    python3 - "$cfg/current/agent.json" "$stage/agent.json" <<'PY'
import json,sys
old,new=(json.load(open(p)) for p in sys.argv[1:])
if any(old[k]!=new[k] for k in ('node','realm')): raise SystemExit('Another node is already installed on this host')
PY
fi
chmod 0755 "$stage/atermius-agent"
"$stage/atermius-agent" --help >/dev/null # check OS/architecture before changing services
group=
if [[ -f "$stage/workspace-image.tar" ]]; then
    if ! command -v docker >/dev/null || [[ $(systemctl show --property=LoadState --value docker.service) == not-found ]]; then
        apt-get update && apt-get install -y docker.io
    fi
    unset DOCKER_CONTEXT
    export DOCKER_HOST=unix:///var/run/docker.sock
    systemctl enable --now docker
    image=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["image"])' "$stage/agent.json")
    if ! docker image inspect "$image" >/dev/null 2>&1; then docker load -i "$stage/workspace-image.tar"; fi
    [[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]]
    group='SupplementaryGroups=docker'
fi
id -u atermius-agent >/dev/null 2>&1 || useradd --system --user-group --home /var/lib/atermius-agent --shell /usr/sbin/nologin atermius-agent
install -d -m 0750 -o root -g atermius-agent "$cfg"
release=$(mktemp -d "$cfg/node.XXXXXXXX")
chown root:atermius-agent "$release"
chmod 0750 "$release"
for f in agent.json node.key node.crt ca.crt; do install -m 0640 -o root -g atermius-agent "$stage/$f" "$release/$f"; done
install -m 0755 "$stage/atermius-agent" "$release/atermius-agent"
previous=$(readlink "$cfg/current" || true)
cat > "$stage/unit" <<EOF
[Unit]
Description=Atermius outbound workspace node
After=network-online.target docker.service
Wants=network-online.target
[Service]
User=atermius-agent
Group=atermius-agent
$group
StateDirectory=atermius-agent
StateDirectoryMode=0700
UMask=0077
ExecStart=/etc/atermius-agent/current/atermius-agent run /etc/atermius-agent/current /var/lib/atermius-agent
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
[Install]
WantedBy=multi-user.target
EOF
install -m 0644 "$stage/unit" /etc/systemd/system/atermius-agent.service
# Create the replacement link on the same filesystem to switch identity and binary together.
ln -s "$(basename "$release")" "$cfg/.current.$$"
mv -Tf "$cfg/.current.$$" "$cfg/current"
systemctl daemon-reload
systemctl enable atermius-agent.service
systemctl restart atermius-agent.service
# An active process may still be retrying DNS/TLS. Confirm a heartbeat from the new PID.
for ((attempt=0; attempt<60; attempt++)); do
    pid=$(systemctl show --property MainPID --value atermius-agent.service)
    if [[ "$pid" != 0 && -f /var/lib/atermius-agent/connected &&
          $(cat /var/lib/atermius-agent/connected) == "$pid" ]]; then
        echo 'Node authenticated. The hub status command shows workspace provisioning and migration progress.'
        exit 0
    fi
    sleep 1
done
echo 'Service installed and retrying; hub authentication has not been confirmed. See journalctl -u atermius-agent.' >&2
if [[ -n "$previous" ]]; then echo "Previous local installation is retained under $cfg/$previous." >&2; fi
exit 1

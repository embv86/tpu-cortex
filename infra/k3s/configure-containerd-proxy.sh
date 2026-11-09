#!/usr/bin/env bash
# Explicit opt-in for a local HTTP proxy; affects image downloads, not pod traffic.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
proxy_url=${1:?Usage: configure-containerd-proxy.sh PROXY_URL}
# Avoid systemd specifier expansion and quoting ambiguities. No credentials here.
[[ "$proxy_url" =~ ^https?://[a-zA-Z0-9.:-]+/?$ ]] || { echo 'Expected a plain HTTP proxy URL without credentials.' >&2; exit 1; }
install -d -m 755 /etc/systemd/system/k3s.service.d
config=$(mktemp)
trap 'rm -f -- "$config"' EXIT
printf '[Service]\nEnvironment="CONTAINERD_HTTP_PROXY=%s"\nEnvironment="CONTAINERD_HTTPS_PROXY=%s"\nEnvironment="CONTAINERD_NO_PROXY=127.0.0.1,localhost,::1,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local"\n' \
  "$proxy_url" "$proxy_url" > "$config"
install -m 600 "$config" /etc/systemd/system/k3s.service.d/cortex-proxy.conf
systemctl daemon-reload
systemctl restart k3s
systemctl is-active k3s

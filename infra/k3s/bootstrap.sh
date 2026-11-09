#!/usr/bin/env bash
# A regular user can use sudo; WSL provisioning can run as root with CORTEX_USER.
set -euo pipefail
elevate=(sudo)
as_user=()
target_user=$(id -un)
target_home="$HOME"
if [[ $(id -u) == 0 ]]; then
  target_user=${CORTEX_USER:?Set CORTEX_USER to an existing non-root Linux user}
  [[ $(id -u "$target_user") != 0 ]] || { echo 'CORTEX_USER must not be root' >&2; exit 1; }
  target_home=$(getent passwd "$target_user" | cut -d: -f6)
  elevate=()
  as_user=(runuser -u "$target_user" --)
fi
if [[ $(ps -p 1 -o comm=) != systemd ]]; then
  echo 'systemd must be PID 1. See infra/k3s/README.md.' >&2
  exit 1
fi
command -v curl >/dev/null || { echo 'Install curl first: sudo apt-get install curl' >&2; exit 1; }
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if (( ${#elevate[@]} )); then sudo -v; fi
if ! command -v k3s >/dev/null; then
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  curl --fail --silent --show-error --location https://get.k3s.io -o "$installer"
  # Pin an exact version with K3S_VERSION; stable is used on the first install otherwise.
  "${elevate[@]}" env INSTALL_K3S_CHANNEL=stable INSTALL_K3S_VERSION="${K3S_VERSION:-}" \
    INSTALL_K3S_EXEC='server --node-name cortex-local --write-kubeconfig-mode 600' \
    sh "$installer"
fi
"${elevate[@]}" systemctl enable --now k3s
for attempt in $(seq 1 90); do
  if "${elevate[@]}" k3s kubectl get --raw=/readyz >/dev/null 2>&1; then break; fi
  sleep 2
done
"${elevate[@]}" k3s kubectl get --raw=/readyz
# Refuse to configure an existing K3s installation belonging to another project.
"${elevate[@]}" k3s kubectl get node cortex-local >/dev/null
"${as_user[@]}" mkdir -p "$target_home/.kube"
"${as_user[@]}" chmod 700 "$target_home/.kube"
config="$target_home/.kube/cortex-local.yaml"
umask 077
"${elevate[@]}" cat /etc/rancher/k3s/k3s.yaml > "$config"
if [[ $(id -u) == 0 ]]; then chown "$target_user:$(id -gn "$target_user")" "$config"; fi
chmod 600 "$config"
# Make plain kubectl work in a fresh user profile without touching existing config.
if [[ ! -e "$target_home/.kube/config" && ! -L "$target_home/.kube/config" ]]; then
  "${as_user[@]}" ln -s cortex-local.yaml "$target_home/.kube/config"
fi
# Bundled k3s kubectl defaults to the root-only server config unless this is set.
for shell_config in "$target_home/.profile" "$target_home/.bashrc"; do
  "${as_user[@]}" touch "$shell_config"
  if ! grep -Fqx 'export KUBECONFIG="$HOME/.kube/cortex-local.yaml"' "$shell_config"; then
    "${as_user[@]}" sed -i '1i export KUBECONFIG="$HOME/.kube/cortex-local.yaml"' "$shell_config"
  fi
done
export KUBECONFIG="$config"
"${as_user[@]}" env KUBECONFIG="$config" kubectl config rename-context default cortex-local >/dev/null
"${as_user[@]}" env KUBECONFIG="$config" kubectl config set-context cortex-local --namespace=cortex-apps >/dev/null
"${as_user[@]}" env KUBECONFIG="$config" kubectl wait --for=condition=Ready node/cortex-local --timeout=180s
"${as_user[@]}" env KUBECONFIG="$config" kubectl apply -f "$repo_dir/infra/k3s/manifests/namespaces.yaml"
# K3s reconciles packaged HelmChartConfig resources from this directory.
"${elevate[@]}" install -m 644 "$repo_dir/infra/k3s/manifests/traefik-config.yaml" \
  /var/lib/rancher/k3s/server/manifests/cortex-traefik-config.yaml
printf '\nK3s version (record for repeat installations):\n'
k3s --version
printf '\nUse: export KUBECONFIG="$HOME/.kube/cortex-local.yaml"\n'
"${as_user[@]}" env KUBECONFIG="$config" bash "$repo_dir/infra/k3s/verify.sh"

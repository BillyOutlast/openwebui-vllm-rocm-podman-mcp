#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QUADLETS_DIR="${SCRIPT_DIR}/quadlets"
TARGET_DIR="${HOME}/.config/containers/systemd"

configure_ollama_dri_devices() {
  local ollama_quadlet="${TARGET_DIR}/ollama-rocm.container"
  local -a dri_nodes
  local replacement=""
  local node

  if [[ ! -f "${ollama_quadlet}" ]]; then
    return
  fi

  shopt -s nullglob
  dri_nodes=(/dev/dri/renderD* /dev/dri/card*)
  shopt -u nullglob

  if (( ${#dri_nodes[@]} == 0 )); then
    return
  fi

  for node in "${dri_nodes[@]}"; do
    replacement+="PodmanArgs=--device=${node}"
    replacement+=$'\n'
  done

  awk -v replacement="${replacement}" '
    $0 == "PodmanArgs=--device=/dev/dri" {
      printf "%s", replacement
      next
    }
    { print }
  ' "${ollama_quadlet}" > "${ollama_quadlet}.tmp"

  mv "${ollama_quadlet}.tmp" "${ollama_quadlet}"
  echo "Configured ollama-rocm.container with explicit /dev/dri nodes:"
  for node in "${dri_nodes[@]}"; do
    echo "  - ${node}"
  done
}

ensure_user_bus() {
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  fi

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "Cannot reach systemd user bus."
    echo "Try one of these on the remote host, then rerun ./install.sh:"
    echo "  1) loginctl enable-linger ${USER}"
    echo "  2) Start a real user login session (ssh/login shell), then run again"
    echo "  3) export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
    echo "     export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus"
    exit 1
  fi
}

ensure_user_bus

preflight_rootless_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman is not installed or not in PATH."
    exit 1
  fi

  if ! podman unshare true >/dev/null 2>&1; then
    local current_user
    current_user="$(id -un)"
    local userns_max userns_clone newuidmap_mode newgidmap_mode

    userns_max="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo unknown)"
    userns_clone="$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo unknown)"
    newuidmap_mode="$(stat -c '%a %U:%G %A' /usr/bin/newuidmap 2>/dev/null || echo missing)"
    newgidmap_mode="$(stat -c '%a %U:%G %A' /usr/bin/newgidmap 2>/dev/null || echo missing)"

    echo "Rootless Podman namespace setup is not working."
    echo "Detected failure pattern: newuidmap/newgidmap (exit status 1)."
    echo
    echo "Checks:"
    if grep -q "^${current_user}:" /etc/subuid 2>/dev/null; then
      echo "  - /etc/subuid entry for ${current_user}: found"
    else
      echo "  - /etc/subuid entry for ${current_user}: MISSING"
    fi
    if grep -q "^${current_user}:" /etc/subgid 2>/dev/null; then
      echo "  - /etc/subgid entry for ${current_user}: found"
    else
      echo "  - /etc/subgid entry for ${current_user}: MISSING"
    fi
    echo "  - /proc/sys/user/max_user_namespaces: ${userns_max}"
    echo "  - /proc/sys/kernel/unprivileged_userns_clone: ${userns_clone}"
    echo "  - /usr/bin/newuidmap perms: ${newuidmap_mode}"
    echo "  - /usr/bin/newgidmap perms: ${newgidmap_mode}"
    echo
    echo "Ask an admin to run (Debian/Ubuntu):"
    echo "  sudo apt-get update && sudo apt-get install -y uidmap"
    echo "  grep '^${current_user}:' /etc/subuid || echo '${current_user}:100000:65536' | sudo tee -a /etc/subuid"
    echo "  grep '^${current_user}:' /etc/subgid || echo '${current_user}:100000:65536' | sudo tee -a /etc/subgid"
    echo "  sudo chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap"
    echo "  echo 'user.max_user_namespaces=28633' | sudo tee /etc/sysctl.d/99-rootless.conf"
    echo "  echo 'kernel.unprivileged_userns_clone=1' | sudo tee -a /etc/sysctl.d/99-rootless.conf"
    echo "  sudo sysctl --system"
    echo
    echo "If this still fails in your environment (e.g., restricted container host), use rootful install instead:"
    echo "  sudo bash ./install-rootful.sh"
    echo
    echo "Then fully log out and log back in, and rerun ./install.sh"
    exit 1
  fi
}

preflight_rootless_podman

mkdir -p "${TARGET_DIR}"

cp "${QUADLETS_DIR}"/*.network "${TARGET_DIR}/"
cp "${QUADLETS_DIR}"/*.container "${TARGET_DIR}/"
configure_ollama_dri_devices

systemctl --user daemon-reload
systemctl --user start --no-block ai-shared-network.service
systemctl --user enable podman.socket
systemctl --user start --no-block podman.socket
systemctl --user enable ollama-rocm.service
systemctl --user enable open-webui.service
systemctl --user enable podman-mcp-server.service

OLLAMA_READY=true
if [[ ! -e /dev/kfd ]]; then
  echo "Skipping ollama-rocm.service: /dev/kfd is missing on this host."
  OLLAMA_READY=false
fi
if [[ ! -d /dev/dri ]]; then
  echo "Skipping ollama-rocm.service: /dev/dri is missing on this host."
  OLLAMA_READY=false
elif ! compgen -G "/dev/dri/renderD*" >/dev/null && ! compgen -G "/dev/dri/card*" >/dev/null; then
  echo "Skipping ollama-rocm.service: /dev/dri has no render/card nodes on this host."
  OLLAMA_READY=false
fi

if [[ "${OLLAMA_READY}" == "true" ]]; then
  systemctl --user start --no-block ollama-rocm.service
else
  echo "ollama-rocm.service not started. Fix GPU device mapping and rerun ./install.sh."
fi

systemctl --user start --no-block open-webui.service
systemctl --user start --no-block podman-mcp-server.service

echo
echo "Installed and started services:"
echo "  - ai-shared-network.service"
echo "  - podman.socket"
if [[ "${OLLAMA_READY}" == "true" ]]; then
  echo "  - ollama-rocm.service"
else
  echo "  - ollama-rocm.service (skipped: missing /dev/kfd, /dev/dri, or /dev/dri nodes)"
fi
echo "  - open-webui.service"
echo "  - podman-mcp-server.service"
echo "(started in non-blocking mode; first model/image pull can take a while)"
echo
echo "Endpoints:"
echo "  - Open WebUI:        http://localhost:3000"
echo "  - Ollama API:        http://localhost:11434"
echo "  - Podman MCP server: http://localhost:8080/mcp"
echo
echo "Check progress:"
echo "  systemctl --user status ollama-rocm.service --no-pager"
echo "  journalctl --user -u ollama-rocm.service -f"

#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "install-rootful.sh must be run as root."
  echo "Run: sudo bash install-rootful.sh"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QUADLETS_DIR="${SCRIPT_DIR}/quadlets"
TARGET_DIR="/etc/containers/systemd"

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
    replacement+="PodmanArgs=--device=${node}\\n"
  done

  awk -v replacement="${replacement}" '
    $0 == "PodmanArgs=--device=/dev/dri" {
      printf "%b", replacement
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

mkdir -p "${TARGET_DIR}"

cp "${QUADLETS_DIR}"/*.network "${TARGET_DIR}/"
cp "${QUADLETS_DIR}"/*.container "${TARGET_DIR}/"
configure_ollama_dri_devices

systemctl daemon-reload

systemctl enable podman.socket >/dev/null 2>&1 || true
systemctl start podman.socket

if ! systemctl start ai-shared-network.service; then
  echo "ai-shared-network.service failed; trying direct Podman network create/reuse..."
  if podman network exists ai-shared; then
    echo "Podman network 'ai-shared' already exists; continuing."
    systemctl reset-failed ai-shared-network.service >/dev/null 2>&1 || true
  elif podman network create ai-shared >/dev/null; then
    echo "Created Podman network 'ai-shared' directly; continuing."
    systemctl reset-failed ai-shared-network.service >/dev/null 2>&1 || true
  else
    echo "Failed to start network unit and failed to create Podman network 'ai-shared'."
    echo "Inspect with:"
    echo "  systemctl status ai-shared-network.service --no-pager"
    echo "  journalctl -xeu ai-shared-network.service --no-pager"
    exit 1
  fi
fi

systemctl reset-failed ollama-rocm.service open-webui.service podman-mcp-server.service >/dev/null 2>&1 || true

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
  systemctl start --no-block ollama-rocm.service
else
  echo "ollama-rocm.service not started. Fix GPU device mapping and rerun install-rootful.sh."
fi

systemctl start --no-block open-webui.service
systemctl start --no-block podman-mcp-server.service

echo
echo "Installed and started rootful services:"
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
echo "  systemctl status ollama-rocm.service --no-pager"
echo "  journalctl -u ollama-rocm.service -f"

#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${HOME}/.config/containers/systemd"
REMOVE_DATA="${REMOVE_DATA:-false}"

ensure_user_bus() {
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  fi

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "Cannot reach systemd user bus."
    echo "Try: export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
    echo "     export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus"
    exit 1
  fi
}

ensure_user_bus

services=(
  ai-shared-network.service
  ollama-rocm.service
  open-webui.service
  podman-mcp-server.service
)

for svc in "${services[@]}"; do
  systemctl --user disable --now "${svc}" 2>/dev/null || true
done

rm -f "${TARGET_DIR}/ai-shared.network"
rm -f "${TARGET_DIR}/ollama-rocm.container"
rm -f "${TARGET_DIR}/open-webui.container"
rm -f "${TARGET_DIR}/podman-mcp-server.container"

systemctl --user daemon-reload

if [[ "${REMOVE_DATA}" == "true" ]]; then
  rm -rf "${HOME}/.local/share/open-webui"
  echo "Removed Open WebUI persistent data at ${HOME}/.local/share/open-webui"
fi

echo "Uninstalled Quadlet units and stopped services."
echo "Kept persistent data by default (Open WebUI data and Ollama volume)."
echo "Set REMOVE_DATA=true to also remove Open WebUI data."

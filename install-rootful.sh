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
ROOT_STACK_DIR="/root/.config/containers/systemd"
STACK_ENV="${ROOT_STACK_DIR}/stack.env"

mkdir -p "${TARGET_DIR}"
mkdir -p "${ROOT_STACK_DIR}"

cp "${QUADLETS_DIR}"/*.network "${TARGET_DIR}/"
cp "${QUADLETS_DIR}"/*.container "${TARGET_DIR}/"

if [[ ! -f "${STACK_ENV}" ]]; then
  cp "${QUADLETS_DIR}/stack.env.example" "${STACK_ENV}"
  echo "Created ${STACK_ENV}. Set HF_TOKEN before first start."
fi

systemctl daemon-reload

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

systemctl reset-failed vllm-rocm.service open-webui.service podman-mcp-server.service >/dev/null 2>&1 || true

VLLM_READY=true

if [[ ! -e /dev/kfd ]]; then
  echo "Skipping vllm-rocm.service: /dev/kfd is missing on this host."
  VLLM_READY=false
fi

if ! compgen -G "/dev/dri/renderD*" >/dev/null; then
  echo "Skipping vllm-rocm.service: no /dev/dri/renderD* nodes found on this host."
  VLLM_READY=false
fi

if [[ -f "${STACK_ENV}" ]] && ! grep -q '^HF_TOKEN=hf_' "${STACK_ENV}"; then
  echo "Warning: HF_TOKEN is not set in ${STACK_ENV} (private models may fail to pull)."
fi

if [[ "${VLLM_READY}" == "true" ]]; then
  systemctl start --no-block vllm-rocm.service
else
  echo "vllm-rocm.service not started. Fix GPU device mapping and rerun install-rootful.sh."
fi

systemctl start --no-block open-webui.service
systemctl start --no-block podman-mcp-server.service

echo
echo "Installed and started rootful services:"
echo "  - ai-shared-network.service"
if [[ "${VLLM_READY}" == "true" ]]; then
  echo "  - vllm-rocm.service"
else
  echo "  - vllm-rocm.service (skipped: missing /dev/kfd or /dev/dri)"
fi
echo "  - open-webui.service"
echo "  - podman-mcp-server.service"
echo "(started in non-blocking mode; first model/image pull can take a while)"
echo
echo "Endpoints:"
echo "  - Open WebUI:        http://localhost:3000"
echo "  - vLLM OpenAI API:   http://localhost:8000/v1"
echo "  - Podman MCP server: http://localhost:8080/mcp"
echo
echo "Check progress:"
echo "  systemctl status vllm-rocm.service --no-pager"
echo "  journalctl -u vllm-rocm.service -f"

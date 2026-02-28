#!/usr/bin/env bash
set -euo pipefail

ok() { echo "[OK]  $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[FAIL] $*"; }

FAILED=0

ensure_user_bus_env() {
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  fi
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi
}

check_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd} found"
  else
    fail "${cmd} not found in PATH"
    FAILED=1
  fi
}

echo "Running preflight checks for openwebui-ollama-rocm-podman-mcp"
echo

check_cmd podman
check_cmd systemctl

ensure_user_bus_env

if systemctl --user show-environment >/dev/null 2>&1; then
  ok "systemd user bus reachable"
else
  fail "systemd user bus unreachable"
  echo "      export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
  echo "      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus"
  echo "      sudo loginctl enable-linger $USER"
  FAILED=1
fi

if podman unshare true >/dev/null 2>&1; then
  ok "rootless Podman namespace works (newuidmap/newgidmap OK)"
else
  USERNS_MAX="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo unknown)"
  USERNS_CLONE="$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo unknown)"
  NEWUIDMAP_PERMS="$(stat -c '%a %U:%G %A' /usr/bin/newuidmap 2>/dev/null || echo missing)"
  NEWGIDMAP_PERMS="$(stat -c '%a %U:%G %A' /usr/bin/newgidmap 2>/dev/null || echo missing)"

  fail "rootless Podman namespace check failed"
  echo "      /proc/sys/user/max_user_namespaces=${USERNS_MAX}"
  echo "      /proc/sys/kernel/unprivileged_userns_clone=${USERNS_CLONE}"
  echo "      /usr/bin/newuidmap perms: ${NEWUIDMAP_PERMS}"
  echo "      /usr/bin/newgidmap perms: ${NEWGIDMAP_PERMS}"
  echo "      sudo apt-get update && sudo apt-get install -y uidmap"
  echo "      grep \"^$USER:\" /etc/subuid || echo \"$USER:100000:65536\" | sudo tee -a /etc/subuid"
  echo "      grep \"^$USER:\" /etc/subgid || echo \"$USER:100000:65536\" | sudo tee -a /etc/subgid"
  echo "      sudo chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap"
  echo "      echo 'user.max_user_namespaces=28633' | sudo tee /etc/sysctl.d/99-rootless.conf"
  echo "      echo 'kernel.unprivileged_userns_clone=1' | sudo tee -a /etc/sysctl.d/99-rootless.conf"
  echo "      sudo sysctl --system"
  echo "      log out and log back in"
  FAILED=1
fi

if [[ -e /dev/kfd ]]; then
  ok "/dev/kfd present"
else
  warn "/dev/kfd missing (ROCm container will not start)"
fi

if [[ -d /dev/dri ]]; then
  ok "/dev/dri present"
else
  warn "/dev/dri missing (ROCm container will not start)"
fi

if [[ -d "./quadlets" ]]; then
  ok "./quadlets directory present"
else
  fail "./quadlets directory missing (run from project root)"
  FAILED=1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  echo
  ok "Preflight passed. You can run ./install.sh"
  exit 0
fi

echo
fail "Preflight failed. Resolve errors above, then rerun ./preflight.sh"
exit 1

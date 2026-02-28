# Quadlets: vLLM ROCm + Open WebUI + Podman MCP Server

The `quadlets/` directory contains rootless Podman Quadlets with a shared network:

- `ai-shared.network`
- `vllm-rocm.container`
- `open-webui.container`
- `podman-mcp-server.container`

## Quick scripts (recommended)

On the remote Linux host:

```bash
chmod +x preflight.sh
./preflight.sh

chmod +x install.sh uninstall.sh
./install.sh
```

If rootless setup keeps failing with `newuidmap/newgidmap` errors despite correct settings,
use the rootful fallback:

```bash
chmod +x install-rootful.sh
sudo bash ./install-rootful.sh
```

To remove the stack:

```bash
./uninstall.sh
```

Optional full data cleanup (Open WebUI data directory):

```bash
REMOVE_DATA=true ./uninstall.sh
```

## 1) Install files to user Quadlet directory

```powershell
mkdir "$HOME/.config/containers/systemd" -Force
copy .\quadlets\*.network "$HOME/.config/containers/systemd\"
copy .\quadlets\*.container "$HOME/.config/containers/systemd\"
copy .\quadlets\stack.env.example "$HOME/.config/containers/systemd\stack.env"
```

Then edit `~/.config/containers/systemd/stack.env` and set `HF_TOKEN`.

## 2) Reload and start services

```powershell
systemctl --user daemon-reload
systemctl --user start --no-block ai-shared-network.service
systemctl --user enable vllm-rocm.service
systemctl --user enable open-webui.service
systemctl --user enable podman-mcp-server.service
systemctl --user start --no-block vllm-rocm.service
systemctl --user start --no-block open-webui.service
systemctl --user start --no-block podman-mcp-server.service
```

First startup can take a long time while images/models are pulled. Monitor with:

```bash
systemctl --user status vllm-rocm.service --no-pager
journalctl --user -u vllm-rocm.service -f
```

## 3) Endpoints

- Open WebUI: http://localhost:3000
- vLLM OpenAI API: http://localhost:8000/v1
- Podman MCP HTTP: http://localhost:8080/mcp

## vLLM server profile

`quadlets/vllm-rocm.container` is configured to serve:

- Model: `Qwen/Qwen3.5-35B-A3B-FP8`
- `--tensor-parallel 4`
- `-dp 8 --enable-expert-parallel`
- `--mm-encoder-tp-mode data --mm-processor-cache-type shm`
- `--reasoning-parser qwen3 --enable-prefix-caching`
- Tool calling enabled: `--enable-auto-tool-choice --tool-call-parser qwen3_coder`
- ROCm env: `MIOPEN_USER_DB_PATH`, `MIOPEN_FIND_MODE=FAST`, `VLLM_ROCM_USE_AITER=1`, `SAFETENSORS_FAST_GPU=1`

The unit also persists MIOpen cache at `~/.cache/miopen` and mounts it into the container.

After changing `quadlets/vllm-rocm.container`:

```bash
systemctl --user daemon-reload
systemctl --user restart vllm-rocm.service
journalctl --user -u vllm-rocm.service -n 100 --no-pager
```

## Troubleshooting: user systemd bus

If you see:

`Failed to connect to user scope bus via local transport: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined`

run:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
```

Then retry:

```bash
./install.sh
```

For persistent remote-user services, enable lingering once:

```bash
sudo loginctl enable-linger $USER
```

If you see errors like:

`Error: cannot set up namespace using "/usr/bin/newuidmap": exit status 1`

this is a rootless Podman host setup issue (`uidmap` or `/etc/subuid`/`/etc/subgid`).
Ask an admin to run:

```bash
sudo apt-get update && sudo apt-get install -y uidmap
grep "^$USER:" /etc/subuid || echo "$USER:100000:65536" | sudo tee -a /etc/subuid
grep "^$USER:" /etc/subgid || echo "$USER:100000:65536" | sudo tee -a /etc/subgid
sudo chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap
```

If it still fails, also verify/enable user namespaces:

```bash
cat /proc/sys/user/max_user_namespaces
cat /proc/sys/kernel/unprivileged_userns_clone
stat -c '%a %U:%G %A' /usr/bin/newuidmap /usr/bin/newgidmap

echo 'user.max_user_namespaces=28633' | sudo tee /etc/sysctl.d/99-rootless.conf
echo 'kernel.unprivileged_userns_clone=1' | sudo tee -a /etc/sysctl.d/99-rootless.conf
sudo sysctl --system
```

Then fully log out and log back in before running `./install.sh` again.

If the environment still blocks rootless namespaces, use:

```bash
sudo bash ./install-rootful.sh
```

## Notes

- `podman-mcp-server` is launched via `npx` inside a Node container because the upstream project is distributed as binary/npm package.
- The vLLM unit includes the ROCm flags from your `docker run` example.
- If this host is not Linux with ROCm devices (`/dev/kfd`, `/dev/dri`), `vllm-rocm` will fail to start.

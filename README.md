# Quadlets: Ollama ROCm + Open WebUI + Podman MCP Server

The `quadlets/` directory contains rootless Podman Quadlets with a shared network:

- `ai-shared.network`
- `ollama-rocm.container`
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

Note: with Quadlet-generated system units, `enable` may fail as "transient or generated".
The rootful installer uses `start` only for those units.

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
```

## 2) Reload and start services

```powershell
systemctl --user daemon-reload
systemctl --user start --no-block ai-shared-network.service
systemctl --user enable ollama-rocm.service
systemctl --user enable open-webui.service
systemctl --user enable podman-mcp-server.service
systemctl --user start --no-block ollama-rocm.service
systemctl --user start --no-block open-webui.service
systemctl --user start --no-block podman-mcp-server.service
```

First startup can take a long time while images/models are pulled. Monitor with:

```bash
systemctl --user status ollama-rocm.service --no-pager
journalctl --user -u ollama-rocm.service -f
```

## 3) Endpoints

- Open WebUI: http://localhost:3000
- Ollama API: http://localhost:11434
- Podman MCP HTTP: http://localhost:8080/mcp

## Ollama server profile

`quadlets/ollama-rocm.container` is configured equivalent to:

- `docker run -d --device /dev/kfd --device /dev/dri -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama:rocm`
- Image: `docker.io/ollama/ollama:rocm` (with `Pull=always`)
- Devices: `/dev/kfd` and `/dev/dri`
- Volume: `ollama:/root/.ollama`
- Port: `11434:11434`

After changing `quadlets/ollama-rocm.container`:

```bash
systemctl --user daemon-reload
systemctl --user restart ollama-rocm.service
journalctl --user -u ollama-rocm.service -n 100 --no-pager
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

If logs show device mapping errors for `/dev/dri`, verify your runtime and GPU device nodes.
The installers skip starting `ollama-rocm.service` when `/dev/kfd` or `/dev/dri` is missing.

Verify GPU device nodes:

```bash
ls -l /dev/kfd
ls -l /dev/dri
```

To force-refresh the Ollama image manually:

```bash
sudo podman pull docker.io/ollama/ollama:rocm
sudo systemctl daemon-reload
sudo systemctl reset-failed ollama-rocm.service
sudo systemctl restart ollama-rocm.service
```

## Notes

- `podman-mcp-server` is launched via `npx` inside a Node container because the upstream project is distributed as binary/npm package.
- The Ollama unit mirrors your ROCm `docker run` flags.
- If this host is not Linux with ROCm devices (`/dev/kfd`, `/dev/dri`), `ollama` will fail to start.

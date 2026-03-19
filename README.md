# DGX Toolbox

Battle-tested scripts for spinning up ML/AI tools on the **NVIDIA DGX Spark**, designed for both local use and remote access via [NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync).

## Prerequisites

- NVIDIA DGX Spark (aarch64)
- Docker with NVIDIA Container Toolkit (`--gpus all` support)
- NGC container registry access (`nvcr.io`)
- For remote use: [NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) configured on your client machine

## Quick Start

```bash
# Clone to your DGX
git clone <repo-url> ~/dgx-toolbox

# One-time system setup (Python, Miniconda, pyenv)
bash ~/dgx-toolbox/dgx-global-base-setup.sh
source ~/.bashrc
```

## Scripts

### System Setup

| Script | Purpose |
|--------|---------|
| `dgx-global-base-setup.sh` | Idempotent system init — installs build tools, Miniconda (aarch64), and pyenv |
| `code-server-creds.sh` | Prints running code-server URL and password (port 8080) |

### GPU Containers

| Script | Purpose | Port |
|--------|---------|------|
| `ngc-pytorch.sh` | Interactive PyTorch shell with GPU access | — |
| `ngc-jupyter.sh` | Jupyter Lab on NGC PyTorch container | 8888 |
| `ngc-quickstart.sh` | In-container guide (available ML packages & workflows) | — |

Both `ngc-pytorch.sh` and `ngc-jupyter.sh` use the `nvcr.io/nvidia/pytorch:26.02-py3` image and will auto-install packages from `~/requirements-gpu.txt` if present.

### Unsloth Studio

| Script | Purpose | Port |
|--------|---------|------|
| `unsloth-studio.sh` | Full launcher — streams logs, auto-opens browser when ready | 8000 |
| `unsloth-studio-sync.sh` | NVIDIA Sync variant — returns immediately, runs in background | 8000 |

Fine-tuning data is persisted in `~/unsloth-data`. Use `unsloth-studio-sync.sh` when launching remotely via NVIDIA Sync (no TTY required). First launch takes up to 30 minutes while dependencies install.

```bash
# Check progress after launching the sync variant
docker logs -f unsloth-studio
```

### Workflow Automation

| Script | Purpose | Port |
|--------|---------|------|
| `start-n8n.sh` | n8n automation platform with persistent config | 5678 |

Data is persisted in `~/.n8n`.

## Port Reference

| Port | Service |
|------|---------|
| 5678 | n8n |
| 8000 | Unsloth Studio |
| 8080 | code-server |
| 8888 | Jupyter Lab |

## Remote Access via NVIDIA Sync

[NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) lets you run commands on your DGX Spark from your laptop and forward ports for browser-based tools.

### Setup

1. Install and configure NVIDIA Sync on your client machine per the [official docs](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync).

2. Clone this repo on the DGX:
   ```bash
   nvidia-sync exec -- git clone <repo-url> ~/dgx-toolbox
   ```

3. Run the base setup:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/dgx-global-base-setup.sh
   ```

### Launching Tools Remotely

For **background services** (n8n, Unsloth Studio), launch with `nvidia-sync exec` and then forward the port:

```bash
# Launch Unsloth Studio (sync-optimized, returns immediately)
nvidia-sync exec -- bash ~/dgx-toolbox/unsloth-studio-sync.sh

# Forward port to access in your local browser
nvidia-sync forward 8000
# Then open http://localhost:8000
```

```bash
# Launch n8n
nvidia-sync exec -- bash ~/dgx-toolbox/start-n8n.sh &

# Forward port
nvidia-sync forward 5678
# Then open http://localhost:5678
```

For **interactive containers** (PyTorch shell), use an SSH session or `nvidia-sync exec -it`:

```bash
nvidia-sync exec -it -- bash ~/dgx-toolbox/ngc-pytorch.sh
```

For **Jupyter Lab**:

```bash
nvidia-sync exec -- bash ~/dgx-toolbox/ngc-jupyter.sh &

nvidia-sync forward 8888
# Then open http://localhost:8888
```

### Port Forwarding Summary

```bash
nvidia-sync forward 8000   # Unsloth Studio
nvidia-sync forward 5678   # n8n
nvidia-sync forward 8888   # Jupyter Lab
nvidia-sync forward 8080   # code-server
```

## Suggested Aliases

Add these to your `~/.bashrc` or `~/.zshrc` on the **DGX Spark**:

```bash
# --- DGX Toolbox aliases ---
alias dgx-setup='bash ~/dgx-toolbox/dgx-global-base-setup.sh'
alias pytorch='bash ~/dgx-toolbox/ngc-pytorch.sh'
alias jupyter='bash ~/dgx-toolbox/ngc-jupyter.sh'
alias unsloth='bash ~/dgx-toolbox/unsloth-studio.sh'
alias unsloth-stop='docker stop unsloth-studio && docker rm unsloth-studio'
alias n8n='bash ~/dgx-toolbox/start-n8n.sh'
alias n8n-stop='docker stop n8n'
```

For your **client machine** (remote via NVIDIA Sync):

```bash
# --- Remote DGX aliases ---
alias dgx-unsloth='nvidia-sync exec -- bash ~/dgx-toolbox/unsloth-studio-sync.sh && nvidia-sync forward 8000'
alias dgx-n8n='nvidia-sync exec -- bash ~/dgx-toolbox/start-n8n.sh && nvidia-sync forward 5678'
alias dgx-jupyter='nvidia-sync exec -- bash ~/dgx-toolbox/ngc-jupyter.sh & nvidia-sync forward 8888'
alias dgx-pytorch='nvidia-sync exec -it -- bash ~/dgx-toolbox/ngc-pytorch.sh'
```

## GPU Requirements File

Both NGC PyTorch scripts auto-install from `~/requirements-gpu.txt` at container start. Create it with your preferred packages:

```bash
cat > ~/requirements-gpu.txt << 'EOF'
unsloth
trl
peft
bitsandbytes
datasets
EOF
```

## License

MIT

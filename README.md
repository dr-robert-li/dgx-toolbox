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

# Build the eval toolbox image (one-time)
bash ~/dgx-toolbox/eval-toolbox-build.sh
```

## Scripts

### System Setup

| Script | Purpose |
|--------|---------|
| `dgx-global-base-setup.sh` | Idempotent system init — installs build tools, Miniconda (aarch64), and pyenv |

### GPU Containers

| Script | Purpose | Port |
|--------|---------|------|
| `ngc-pytorch.sh` | Interactive PyTorch shell with GPU access | — |
| `ngc-jupyter.sh` | Jupyter Lab on NGC PyTorch container | 8888 |
| `ngc-quickstart.sh` | In-container guide (available ML packages & workflows) | — |

Both `ngc-pytorch.sh` and `ngc-jupyter.sh` use the `nvcr.io/nvidia/pytorch:26.02-py3` image and will auto-install packages from `~/requirements-gpu.txt` if present.

### Eval Toolbox

A general-purpose evaluation container built on the NGC PyTorch base with metrics, LLM eval, CV eval, and Triton client libraries pre-installed. Does **not** reinstall CUDA/PyTorch — only layers Python-level eval packages on top.

| Script | Purpose | Port |
|--------|---------|------|
| `eval-toolbox-build.sh` | Build the eval-toolbox Docker image (one-time) | — |
| `eval-toolbox.sh` | Interactive eval shell with GPU access | — |
| `eval-toolbox-jupyter.sh` | Jupyter Lab with eval stack | 8889 |

**Included libraries:** `lm-eval`, `ragas`, `evaluate`, `datasets`, `torchmetrics`, `pycocotools`, `albumentations`, `scikit-learn`, `pandas`, `scipy`, `wandb`, `mlflow`, `tritonclient[all]`, `typer`, `rich`

Data directories are mounted from the host:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/eval/datasets` | `/datasets` | Evaluation datasets |
| `~/eval/models` | `/models` | Model checkpoints |
| `~/eval/runs` | `/eval_runs` | Run logs and results |
| `~/.cache/huggingface` | `/root/.cache/huggingface` | HF model/dataset cache |

```bash
# Build once
eval-build

# Interactive shell
eval-toolbox

# Jupyter
eval-jupyter
```

### Triton TRT-LLM Server

Runs NVIDIA Triton Inference Server with the TensorRT-LLM backend as a sidecar. The eval toolbox container connects to it via `tritonclient` over HTTP/gRPC.

| Script | Purpose | Ports |
|--------|---------|-------|
| `triton-trtllm.sh` | Full launcher — streams logs | 8010 (HTTP), 8011 (gRPC), 8012 (metrics) |
| `triton-trtllm-sync.sh` | NVIDIA Sync variant — returns immediately | 8010, 8011, 8012 |

Ports are offset from default (8000-8002) to avoid conflict with Unsloth Studio.

Host directories:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/triton/engines` | `/engines` | TensorRT-LLM compiled engines |
| `~/triton/model_repo` | `/triton_model_repo` | Triton model repository |

**Workflow:**

1. Start Triton: `triton` (or `triton-trtllm-sync.sh` for remote)
2. Build TRT-LLM engines inside the container and place in `~/triton/engines`
3. Populate `~/triton/model_repo` with Triton model configs
4. Restart the container — Triton auto-serves from the model repo
5. From the eval toolbox, query via `tritonclient` or HTTP:

```python
# Inside eval-toolbox container
import tritonclient.http as httpclient
client = httpclient.InferenceServerClient("localhost:8010")
client.is_server_live()
```

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
| 8010 | Triton TRT-LLM (HTTP) |
| 8011 | Triton TRT-LLM (gRPC) |
| 8012 | Triton TRT-LLM (metrics) |
| 8080 | code-server |
| 8888 | Jupyter Lab (NGC) |
| 8889 | Jupyter Lab (Eval Toolbox) |

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

4. Build the eval toolbox image:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/eval-toolbox-build.sh
   ```

### Launching Tools Remotely

For **background services** (n8n, Unsloth Studio, Triton), launch with `nvidia-sync exec` and then forward the port:

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

```bash
# Launch Triton TRT-LLM
nvidia-sync exec -- bash ~/dgx-toolbox/triton-trtllm-sync.sh

# Forward HTTP port
nvidia-sync forward 8010
```

For **interactive containers** (PyTorch shell, eval toolbox), use an SSH session or `nvidia-sync exec -it`:

```bash
nvidia-sync exec -it -- bash ~/dgx-toolbox/ngc-pytorch.sh
nvidia-sync exec -it -- bash ~/dgx-toolbox/eval-toolbox.sh
```

For **Jupyter Lab**:

```bash
# NGC Jupyter
nvidia-sync exec -- bash ~/dgx-toolbox/ngc-jupyter.sh &
nvidia-sync forward 8888

# Eval Toolbox Jupyter
nvidia-sync exec -- bash ~/dgx-toolbox/eval-toolbox-jupyter.sh &
nvidia-sync forward 8889
```

### NVIDIA Sync Custom App Configuration

You can register these tools as custom apps in NVIDIA Sync so they appear in the Sync UI and auto-forward ports. Add entries to your Sync configuration on the **client machine**:

```yaml
# ~/.nvidia-sync/apps.yaml (example — adjust paths per Sync docs)
apps:
  - name: "Unsloth Studio"
    command: "bash ~/dgx-toolbox/unsloth-studio-sync.sh"
    ports: [8000]
    icon: "beaker"

  - name: "n8n"
    command: "bash ~/dgx-toolbox/start-n8n.sh"
    ports: [5678]
    icon: "workflow"

  - name: "Eval Jupyter"
    command: "bash ~/dgx-toolbox/eval-toolbox-jupyter.sh"
    ports: [8889]
    icon: "notebook"

  - name: "NGC Jupyter"
    command: "bash ~/dgx-toolbox/ngc-jupyter.sh"
    ports: [8888]
    icon: "notebook"

  - name: "Triton TRT-LLM"
    command: "bash ~/dgx-toolbox/triton-trtllm-sync.sh"
    ports: [8010, 8011, 8012]
    icon: "server"
```

Refer to the [NVIDIA Sync custom apps documentation](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) for the exact configuration format and supported fields.

### Port Forwarding Summary

```bash
nvidia-sync forward 8000   # Unsloth Studio
nvidia-sync forward 5678   # n8n
nvidia-sync forward 8010   # Triton TRT-LLM (HTTP)
nvidia-sync forward 8011   # Triton TRT-LLM (gRPC)
nvidia-sync forward 8888   # Jupyter Lab (NGC)
nvidia-sync forward 8889   # Jupyter Lab (Eval Toolbox)
nvidia-sync forward 8080   # code-server
```

## Suggested Aliases

Add these to your `~/.bash_aliases` on the **DGX Spark**:

```bash
# --- DGX Toolbox aliases ---
alias dgx-setup='bash ~/dgx-toolbox/dgx-global-base-setup.sh'
alias pytorch='bash ~/dgx-toolbox/ngc-pytorch.sh'
alias jupyter='bash ~/dgx-toolbox/ngc-jupyter.sh'
alias unsloth='bash ~/dgx-toolbox/unsloth-studio.sh'
alias unsloth-stop='docker stop unsloth-studio && docker rm unsloth-studio'
alias n8n='bash ~/dgx-toolbox/start-n8n.sh'
alias n8n-stop='docker stop n8n'
alias eval-build='bash ~/dgx-toolbox/eval-toolbox-build.sh'
alias eval-toolbox='bash ~/dgx-toolbox/eval-toolbox.sh'
alias eval-jupyter='bash ~/dgx-toolbox/eval-toolbox-jupyter.sh'
alias triton='bash ~/dgx-toolbox/triton-trtllm.sh'
alias triton-stop='docker stop triton-trtllm'
```

For your **client machine** (remote via NVIDIA Sync):

```bash
# --- Remote DGX aliases ---
alias dgx-unsloth='nvidia-sync exec -- bash ~/dgx-toolbox/unsloth-studio-sync.sh && nvidia-sync forward 8000'
alias dgx-n8n='nvidia-sync exec -- bash ~/dgx-toolbox/start-n8n.sh && nvidia-sync forward 5678'
alias dgx-jupyter='nvidia-sync exec -- bash ~/dgx-toolbox/ngc-jupyter.sh & nvidia-sync forward 8888'
alias dgx-eval-jupyter='nvidia-sync exec -- bash ~/dgx-toolbox/eval-toolbox-jupyter.sh & nvidia-sync forward 8889'
alias dgx-triton='nvidia-sync exec -- bash ~/dgx-toolbox/triton-trtllm-sync.sh && nvidia-sync forward 8010'
alias dgx-pytorch='nvidia-sync exec -it -- bash ~/dgx-toolbox/ngc-pytorch.sh'
alias dgx-eval='nvidia-sync exec -it -- bash ~/dgx-toolbox/eval-toolbox.sh'
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

# Karpathy autoresearch — DGX Spark Launcher

Andrej Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) is an autonomous AI research agent that runs a tight loop: read `program.md` instructions → modify `train.py` → train a GPT for 5–10 minutes → evaluate validation bits-per-byte → commit improvements or reset → repeat. It is designed to run continuously as a research assistant, proposing and testing modifications to the training recipe without human intervention.

This launcher wraps autoresearch for the DGX Spark — an ARM64 workstation with 128 Blackwell CUDA cores (not a data center H100). It handles cloning, dependency setup, data source selection, and automatic parameter scaling.

---

## DGX Spark Tuning

The default autoresearch parameters target H100 GPUs with 16,896 CUDA cores. The table below shows what gets adjusted for the Spark.

| Parameter | Default (H100) | Spark Override | Reason |
|-----------|---------------|----------------|--------|
| `DEPTH` | ~12 | 4 | Fewer transformer layers fit in 128-core GPU memory |
| `TOTAL_BATCH_SIZE` | ~32+ | 4 | Avoid OOM on limited GPU memory |
| `DEVICE_BATCH_SIZE` | ~4+ | 1 | Micro-batch size per gradient step |
| `MAX_SEQ_LEN` | ~1024 | 256 | Less memory per sample |
| `GRAD_ACCUM` | varies | 8 | Simulate larger effective batch via accumulation |
| `TRAIN_MINUTES` | 5 | 10 | Slower GPU needs more wall-clock time per experiment |
| `EVAL_TOKENS` | large | 100,000 | Faster eval cycles on limited compute |

Overrides are applied via `sed` to `train.py` and `prepare.py` after each clone/pull. The operation is idempotent — safe to run multiple times.

---

## Data Source Options

### 1. Default (built-in)
Uses the dataset bundled with autoresearch (`prepare.py` default).
```bash
autoresearch
# Select option 1
```

### 2. Local directory
Copies `.txt` and `.parquet` files from a path on your machine into `data/`, then runs `prepare.py`.
```bash
autoresearch
# Select option 2 → enter: /home/user/my-corpus
```

### 3. Hugging Face dataset
Downloads a dataset from the HuggingFace Hub using `huggingface-cli`.
```bash
# Interactive
autoresearch
# Select option 3 → enter: karpathy/climbmix-400b-shuffle

# Headless
AUTORESEARCH_DATA_SOURCE=huggingface \
AUTORESEARCH_DATA_PATH=karpathy/climbmix-400b-shuffle \
  ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh
```

### 4. GitHub repo
Clones a GitHub repository and copies data files from it.
```bash
# Interactive
autoresearch
# Select option 4 → enter: https://github.com/user/dataset-repo

# Headless
AUTORESEARCH_DATA_SOURCE=github \
AUTORESEARCH_DATA_PATH=https://github.com/user/dataset-repo \
  ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh
```

### 5. Kaggle dataset
Downloads a Kaggle dataset. Requires the `kaggle` CLI and `~/.kaggle/kaggle.json` credentials.
```bash
# Interactive
autoresearch
# Select option 5 → enter: username/dataset-name

# Headless
AUTORESEARCH_DATA_SOURCE=kaggle \
AUTORESEARCH_DATA_PATH=username/dataset-name \
  ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh
```

Install kaggle CLI: `pip install kaggle`
Get API token: https://www.kaggle.com/settings → API → Create New Token

---

## Interactive Usage

```bash
# Via alias (after sourcing .bash_aliases)
autoresearch

# Or directly
~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch.sh
```

The launcher will:
1. Clone or pull the latest `autoresearch` master into `~/autoresearch/`
2. Install/update `uv` if needed, then run `uv sync`
3. Show a menu to select your data source
4. Run `prepare.py` to tokenize the corpus
5. Apply DGX Spark tuning overrides to `train.py`
6. Print the location of `program.md` and instructions for pointing your agent
7. Optionally run a single test experiment to validate the setup

After the launcher finishes, start the agent loop:
```bash
# With Claude CLI
claude --file ~/autoresearch/program.md

# Or any agent that can read a file and run shell commands
```

---

## Headless / Sync Usage

Use `launch-autoresearch-sync.sh` for NVIDIA Sync sessions or scripted workflows. All options are configured via environment variables — no interactive prompts.

```bash
# Minimal (built-in dataset, DGX Spark tuning applied)
~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh

# HuggingFace dataset, run a test after setup
AUTORESEARCH_DATA_SOURCE=huggingface \
AUTORESEARCH_DATA_PATH=karpathy/climbmix-400b-shuffle \
AUTORESEARCH_RUN_TEST=1 \
  ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh

# Skip GPU tuning (use autoresearch defaults)
AUTORESEARCH_SKIP_TUNE=1 \
  ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh
```

| Variable | Values | Description |
|----------|--------|-------------|
| `AUTORESEARCH_DATA_SOURCE` | `default`, `local`, `huggingface`, `github`, `kaggle` | Which data source to use |
| `AUTORESEARCH_DATA_PATH` | path / name / URL | Required for all non-default sources |
| `AUTORESEARCH_SKIP_TUNE` | `1` | Skip DGX Spark parameter overrides |
| `AUTORESEARCH_RUN_TEST` | `1` | Run one `uv run train.py` test experiment after setup |

---

## Viewing Results

Autoresearch commits results to `~/autoresearch/` as the agent loop runs. To explore metrics and plots:

```bash
ngc-jupyter   # Opens Jupyter Lab on the NGC PyTorch image (:8888)
```

Then open `~/autoresearch/analysis.ipynb` to review training curves and validation BPB across experiments.

---

## Customizing Tuning

Edit `spark-config.sh` to adjust any parameter:

```bash
nano ~/dgx-toolbox/karpathy-autoresearch/spark-config.sh
```

Or skip tuning entirely and use autoresearch defaults:

```bash
AUTORESEARCH_SKIP_TUNE=1 autoresearch
```

To stop a running experiment:
```bash
autoresearch-stop
```

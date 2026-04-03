FROM nvcr.io/nvidia/pytorch:26.02-py3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# Common system deps shared by eval and data toolboxes
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    libgl1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Remove keras_nlp/keras backend conflict before installing transformers
# (NGC PyTorch 26.02 ships a keras_nlp stub that conflicts with transformers 4.56+)
RUN pip uninstall -y keras-nlp keras keras-core 2>/dev/null || true

# Common Python packages used by both eval and data toolboxes
RUN pip install --upgrade pip && \
    pip install --no-cache-dir \
      "datasets" \
      "pandas" \
      "pyarrow" \
      "scikit-learn" \
      "scipy" \
      "openai" \
      "huggingface_hub" \
      "typer[all]" \
      "rich" \
      "tqdm" \
      \
      # ML training stack (inherited by eval-toolbox, data-toolbox, unsloth-headless)
      "transformers" \
      "accelerate" \
      "peft" \
      "trl" \
      "sentencepiece" \
      "hf_transfer" \
      "pyyaml" \
      "mlflow"

ENTRYPOINT ["/bin/bash"]

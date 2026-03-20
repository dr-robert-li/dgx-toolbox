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
      "tqdm"

ENTRYPOINT ["/bin/bash"]

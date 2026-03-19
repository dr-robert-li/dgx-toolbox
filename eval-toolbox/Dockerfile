FROM nvcr.io/nvidia/pytorch:26.02-py3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# System deps for pycocotools / OpenCV / general build
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    libgl1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Eval stack — do NOT touch CUDA/PyTorch (provided by base image)
RUN pip install --upgrade pip && \
    pip install --no-cache-dir \
      "datasets" \
      "evaluate" \
      "scikit-learn" \
      "pandas" \
      "scipy" \
      "torchmetrics" \
      "pycocotools" \
      "albumentations" \
      "wandb" \
      "mlflow" \
      "typer[all]" \
      "rich" \
      "lm-eval" \
      "ragas" \
      "tritonclient[all]"

ENTRYPOINT ["/bin/bash"]

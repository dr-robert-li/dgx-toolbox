FROM nvcr.io/nvidia/pytorch:26.02-py3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# System deps for PDF extraction, text processing, compression
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    libgl1 \
    poppler-utils \
    tesseract-ocr \
    pigz \
    parallel \
    pv \
    csvkit \
    && rm -rf /var/lib/apt/lists/*

# Install DuckDB CLI
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then DUCKDB_ARCH="aarch64"; else DUCKDB_ARCH="amd64"; fi && \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v1.2.2/duckdb_cli-linux-${DUCKDB_ARCH}.zip" -o /tmp/duckdb.zip && \
    unzip /tmp/duckdb.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/duckdb && \
    rm /tmp/duckdb.zip

WORKDIR /workspace

# Data processing & dataframes
RUN pip install --upgrade pip && \
    pip install --no-cache-dir \
      "pandas" \
      "polars" \
      "pyarrow" \
      "duckdb" \
      "datasets" \
      "huggingface_hub"

# Curation & deduplication
RUN pip install --no-cache-dir \
      "datatrove[io,processing,cli,s3]" \
      "datasketch" \
      "mmh3" \
      "xxhash" \
      "ftfy" \
      "trafilatura"

# Synthetic data generation
RUN pip install --no-cache-dir \
      "distilabel" \
      "Faker"

# Data quality & cleaning
RUN pip install --no-cache-dir \
      "cleanlab"

# Text & document extraction
RUN pip install --no-cache-dir \
      "beautifulsoup4" \
      "lxml" \
      "readability-lxml" \
      "pdfplumber" \
      "python-docx" \
      "openpyxl"

# Labeling platform clients (servers run separately)
RUN pip install --no-cache-dir \
      "label-studio-sdk" \
      "argilla"

# Cloud storage I/O
RUN pip install --no-cache-dir \
      "boto3" \
      "azure-storage-blob" \
      "google-cloud-storage" \
      "smart-open[all]"

# Serialization & compression
RUN pip install --no-cache-dir \
      "orjson" \
      "msgspec" \
      "zstandard"

# LLM API clients (for distilabel synthetic generation via LiteLLM/vLLM/Ollama)
RUN pip install --no-cache-dir \
      "openai"

# CLI & utilities
RUN pip install --no-cache-dir \
      "typer[all]" \
      "rich" \
      "tqdm"

ENTRYPOINT ["/bin/bash"]

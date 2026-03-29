FROM base-toolbox:latest

# Eval-specific packages — do NOT touch CUDA/PyTorch (provided by base)
RUN pip install --no-cache-dir \
      "evaluate" \
      "torchmetrics" \
      "pycocotools" \
      "albumentations" \
      "mlflow" \
      "lm-eval" \
      "ragas" \
      "tritonclient[all]"

ENTRYPOINT ["/bin/bash"]

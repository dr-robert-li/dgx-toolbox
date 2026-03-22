#!/usr/bin/env bash
# Validate NeMo Guardrails + Presidio aarch64 compatibility on DGX Spark
# Run this in a fresh venv on the target hardware
set -euo pipefail

VENV_DIR="${1:-/tmp/harness-compat-test}"
echo "=== DGX Safety Harness aarch64 Compatibility Probe ==="
echo "Target venv: $VENV_DIR"
echo ""

# Step 1: Check architecture
ARCH=$(uname -m)
echo "[1/7] Architecture: $ARCH"
if [ "$ARCH" != "aarch64" ]; then
    echo "WARNING: Not running on aarch64 — results may not reflect DGX Spark"
fi

# Step 2: Check build tools
echo "[2/7] Checking build tools..."
for tool in gcc g++ python3; do
    if command -v "$tool" &>/dev/null; then
        echo "  OK: $tool ($("$tool" --version 2>&1 | head -1))"
    else
        echo "  MISSING: $tool — install with: sudo apt-get install -y gcc g++ python3-dev"
        exit 1
    fi
done

# Step 3: Create fresh venv
echo "[3/7] Creating fresh venv at $VENV_DIR..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q

# Step 4: Install NeMo Guardrails (includes Annoy build from source)
echo "[4/7] Installing nemoguardrails (Annoy will build from source on aarch64)..."
if pip install nemoguardrails 2>&1 | tee /tmp/nemo-install.log; then
    echo "  OK: nemoguardrails installed"
else
    echo "  FAIL: nemoguardrails installation failed"
    echo "  See /tmp/nemo-install.log for details"
    echo ""
    echo "Fallback: try conda install -c conda-forge python-annoy && pip install nemoguardrails --no-deps"
    exit 1
fi

# Step 5: Validate NeMo import and LLMRails instantiation
echo "[5/7] Validating NeMo Guardrails import..."
python3 -c "
from nemoguardrails import RailsConfig, LLMRails
print('  OK: nemoguardrails imports successfully')
print(f'  Version: {__import__(\"nemoguardrails\").__version__}')
" || { echo "  FAIL: NeMo Guardrails import failed"; exit 1; }

# Step 6: Install Presidio + spaCy
echo "[6/7] Installing presidio-analyzer + spaCy model..."
pip install "presidio-analyzer>=2.2" "presidio-anonymizer>=2.2" "spacy>=3.8.5" -q
python3 -m spacy download en_core_web_lg -q 2>&1 | tail -3
python3 -c "
from presidio_analyzer import AnalyzerEngine
engine = AnalyzerEngine()
results = engine.analyze(text='John Smith at john@test.com', language='en', entities=['PERSON','EMAIL_ADDRESS'])
print(f'  OK: Presidio detected {len(results)} entities')
for r in results:
    print(f'    - {r.entity_type}: score={r.score:.2f}')
" || { echo "  FAIL: Presidio analysis failed"; exit 1; }

# Step 7: Summary
echo ""
echo "[7/7] === RESULTS ==="
echo "  NeMo Guardrails: PASS"
echo "  Annoy (C++ build): PASS"
echo "  Presidio + spaCy NER: PASS"
echo "  Architecture: $ARCH"
echo ""
echo "All aarch64 compatibility checks passed. Safe to proceed with Phase 6."

deactivate

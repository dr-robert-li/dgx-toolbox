#!/usr/bin/env bash
set -euo pipefail

# screen-data.sh — Training data pre-screening through harness guardrails
#
# Usage: screen-data.sh <input_file> [output_dir]
#
#   input_file  : path to .jsonl, .txt, or .parquet file
#   output_dir  : directory for output files (default: same dir as input_file)
#
# Environment variables:
#   HARNESS_URL     : harness gateway URL (default: http://localhost:5000)
#   HARNESS_API_KEY : required — must be a non-bypass tenant key (e.g. dev-team)
#                     Do NOT use the ci-runner key (bypass=true skips guardrails)
#
# Output files:
#   <basename>-screened.<ext>  : records that passed guardrail check
#   <basename>-removed.log     : records that were flagged, with reason
#
# Exit codes:
#   0 — at least one clean record remains in screened output
#   1 — error condition (harness not reachable, bad input, all records flagged)

HARNESS_URL="${HARNESS_URL:-http://localhost:5000}"
HARNESS_API_KEY="${HARNESS_API_KEY:-}"

# ============================================================
# 1. Parse and validate arguments
# ============================================================
if [ $# -lt 1 ]; then
  echo "Usage: screen-data.sh <input_file> [output_dir]" >&2
  echo "" >&2
  echo "Environment:" >&2
  echo "  HARNESS_URL     harness gateway URL (default: http://localhost:5000)" >&2
  echo "  HARNESS_API_KEY required — non-bypass tenant key (e.g. dev-team)" >&2
  exit 1
fi

INPUT_FILE="$1"
OUTPUT_DIR="${2:-$(dirname "$INPUT_FILE")}"

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Input file not found: $INPUT_FILE" >&2
  exit 1
fi

if [ -z "$HARNESS_API_KEY" ]; then
  echo "ERROR: HARNESS_API_KEY is required." >&2
  echo "  Set it to a non-bypass tenant key (e.g. the dev-team key)." >&2
  echo "  Do NOT use the ci-runner key — it has bypass=true and skips guardrails." >&2
  exit 1
fi

# ============================================================
# 2. Detect file type
# ============================================================
BASENAME=$(basename "$INPUT_FILE")
EXT="${BASENAME##*.}"
NAME="${BASENAME%.*}"

case "$EXT" in
  txt|jsonl)
    : # supported natively
    ;;
  parquet)
    # Check pandas availability
    if ! python3 -c "import pandas" 2>/dev/null; then
      echo "ERROR: .parquet files require pandas. Install with: pip install pandas pyarrow" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Unsupported file type '.${EXT}'. Supported: .txt, .jsonl, .parquet" >&2
    exit 1
    ;;
esac

# ============================================================
# 3. Health check: harness must be reachable
# ============================================================
if ! curl -sf -X POST "${HARNESS_URL}/probe" \
   -H "Authorization: Bearer ${HARNESS_API_KEY:-sk-devteam-test}" \
   --max-time 5 >/dev/null 2>&1; then
  echo "ERROR: Harness not reachable at ${HARNESS_URL}. Start harness first." >&2
  echo "  To start harness: harness" >&2
  exit 1
fi

# ============================================================
# 4. Set up output files
# ============================================================
mkdir -p "$OUTPUT_DIR"
SCREENED_FILE="${OUTPUT_DIR}/${NAME}-screened.${EXT}"
REMOVED_LOG="${OUTPUT_DIR}/${NAME}-removed.log"

# Clear or create output files
: > "$SCREENED_FILE"
: > "$REMOVED_LOG"

echo "Screening: $INPUT_FILE"
echo "Output:    $SCREENED_FILE"
echo "Removed:   $REMOVED_LOG"
echo ""

# ============================================================
# 5. Initialize counters
# ============================================================
TOTAL=0
CLEAN=0
FLAGGED=0

# ============================================================
# 6. Helper: screen a single text record
# Returns 0 if clean (HTTP 200), 1 if flagged or error.
# Writes clean record to SCREENED_FILE, flagged to REMOVED_LOG.
# ============================================================
_screen_record() {
  local record="$1"
  local line_num="$2"

  # Escape record content for JSON using Python (safe for all characters)
  local escaped
  escaped=$(printf '%s' "$record" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null) || {
    echo "WARN: Could not JSON-escape record at line $line_num — skipping" >&2
    return 1
  }

  local response_body
  local http_code
  response_body=$(mktemp)

  http_code=$(curl -sf \
    -o "$response_body" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${HARNESS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"screen\",\"messages\":[{\"role\":\"user\",\"content\":${escaped}}]}" \
    "${HARNESS_URL}/v1/chat/completions" 2>/dev/null) || http_code="000"

  if [ "$http_code" = "200" ]; then
    # Clean record — write to screened output
    printf '%s\n' "$record" >> "$SCREENED_FILE"
    rm -f "$response_body"
    return 0
  elif [ "$http_code" = "400" ] || [ "$http_code" = "403" ] || [ "$http_code" = "422" ]; then
    # Flagged record — write to removal log with reason
    local reason
    reason=$(cat "$response_body" 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    msg = d.get('detail') or d.get('message') or d.get('error','flagged')
    print(str(msg)[:200])
except Exception:
    print('HTTP $http_code — flagged by guardrails')
" 2>/dev/null || echo "HTTP $http_code — flagged by guardrails")
    printf '[line %d] %s\nREASON: %s\n\n' "$line_num" "${record:0:120}" "$reason" >> "$REMOVED_LOG"
    rm -f "$response_body"
    return 1
  else
    # Other error — log and skip
    echo "WARN: Unexpected HTTP $http_code for record at line $line_num — skipping" >&2
    printf '[line %d] HTTP %s — skipped (unexpected status)\n\n' "$line_num" "$http_code" >> "$REMOVED_LOG"
    rm -f "$response_body"
    return 1
  fi
}

# ============================================================
# 7. Read and screen records based on file type
# ============================================================
LINE_NUM=0

if [ "$EXT" = "txt" ]; then
  # Each non-empty line is one record
  while IFS= read -r line || [ -n "$line" ]; do
    LINE_NUM=$((LINE_NUM + 1))
    # Skip empty lines
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    if _screen_record "$line" "$LINE_NUM"; then
      CLEAN=$((CLEAN + 1))
    else
      FLAGGED=$((FLAGGED + 1))
    fi
  done < "$INPUT_FILE"

elif [ "$EXT" = "jsonl" ]; then
  # Each line is JSON; extract text/prompt/content field
  while IFS= read -r line || [ -n "$line" ]; do
    LINE_NUM=$((LINE_NUM + 1))
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    # Extract text content from JSON
    record=$(printf '%s' "$line" | python3 -c "
import json,sys
try:
    d = json.loads(sys.stdin.read())
    # Look for common text fields
    for key in ('text', 'prompt', 'content', 'input', 'question'):
        if key in d:
            print(d[key])
            sys.exit(0)
    # If it's a messages array, get first user content
    if 'messages' in d:
        for m in d['messages']:
            if m.get('role') == 'user':
                print(m.get('content', ''))
                sys.exit(0)
    # Fall back to full line
    print(sys.stdin.read() if False else str(d))
except Exception:
    print('')
" 2>/dev/null || echo "")
    if [ -z "$record" ]; then
      echo "WARN: Could not extract text from JSONL line $LINE_NUM — skipping" >&2
      continue
    fi
    if _screen_record "$record" "$LINE_NUM"; then
      CLEAN=$((CLEAN + 1))
    else
      FLAGGED=$((FLAGGED + 1))
    fi
  done < "$INPUT_FILE"

elif [ "$EXT" = "parquet" ]; then
  # Use pandas to extract first column as text records
  PARQUET_TMP=$(mktemp)
  python3 -c "
import pandas
df = pandas.read_parquet('${INPUT_FILE}')
for row in df.iloc[:,0]:
    print(str(row))
" 2>/dev/null > "$PARQUET_TMP" || {
    echo "ERROR: Failed to read parquet file: $INPUT_FILE" >&2
    rm -f "$PARQUET_TMP"
    exit 1
  }
  while IFS= read -r record || [ -n "$record" ]; do
    LINE_NUM=$((LINE_NUM + 1))
    [ -z "$record" ] && continue
    TOTAL=$((TOTAL + 1))
    if _screen_record "$record" "$LINE_NUM"; then
      CLEAN=$((CLEAN + 1))
    else
      FLAGGED=$((FLAGGED + 1))
    fi
  done < "$PARQUET_TMP"
  rm -f "$PARQUET_TMP"
fi

# ============================================================
# 8. Print summary
# ============================================================
echo ""
echo "Screened: $TOTAL total, $CLEAN clean, $FLAGGED removed. See ${REMOVED_LOG}"

# ============================================================
# 9. Exit based on results
# ============================================================
if [ "$TOTAL" -eq 0 ]; then
  echo "WARN: No records found in input file." >&2
  exit 1
fi

if [ "$CLEAN" -eq 0 ]; then
  echo "ERROR: All $TOTAL records were flagged by guardrails. Nothing written to screened output." >&2
  exit 1
fi

exit 0

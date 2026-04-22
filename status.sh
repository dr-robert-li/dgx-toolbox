#!/usr/bin/env bash
# Show status of all DGX Toolbox services
source "$(dirname "$0")/lib.sh"

IP=$(get_ip)

check_service() {
  local name="$1"
  local port="$2"
  local status

  if is_running "$name"; then
    status="RUNNING"
  elif container_exists "$name"; then
    status="STOPPED"
  else
    status="—"
  fi
  printf "  %-20s %-10s %s\n" "$name" "$status" "${port:+:$port}"
}

check_systemd() {
  local name="$1"
  local port="$2"
  local status

  if systemctl is-active --quiet "$name" 2>/dev/null; then
    status="RUNNING"
  else
    status="STOPPED"
  fi
  printf "  %-20s %-10s %s\n" "$name" "$status" ":$port"
}

echo ""
echo "========================================"
echo " DGX Toolbox Status"
echo " Host: ${IP}"
echo "========================================"
echo ""

echo "INFERENCE"
check_systemd "ollama" "11434"
check_service "open-webui" "12000"
if command -v sparkrun >/dev/null 2>&1; then
  proxy_line=$(sparkrun proxy status 2>/dev/null | head -1 || true)
  workload_line=$(sparkrun status 2>/dev/null | head -1 || true)
  printf "  %-20s %s\n" "sparkrun proxy" "${proxy_line:-unknown} :4000"
  printf "  %-20s %s\n" "sparkrun workload" "${workload_line:-none}"
else
  printf "  %-20s %s\n" "sparkrun" "NOT INSTALLED (see setup/dgx-global-base-setup.sh)"
fi
check_service "triton-trtllm" "8010"

echo ""
echo "FINE-TUNING"
check_service "unsloth-studio" "8000"
check_service "unsloth-headless" ""

echo ""
echo "DATA ENGINEERING"
check_service "label-studio" "8081"
check_service "argilla" "6900"

echo ""
echo "WORKFLOW"
check_service "n8n" "5678"

echo ""
echo "TOOLBOX IMAGES"
for img in base-toolbox eval-toolbox data-toolbox; do
  if docker image inspect "${img}:latest" &>/dev/null; then
    size=$(docker image inspect "${img}:latest" --format '{{.Size}}' | awk '{printf "%.1fGB", $1/1073741824}')
    printf "  %-20s %s\n" "$img" "$size"
  else
    printf "  %-20s %s\n" "$img" "NOT BUILT"
  fi
done

echo ""
echo "DISK USAGE"
printf "  %-20s %s\n" "Docker images" "$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)"
printf "  %-20s %s\n" "Docker volumes" "$(docker system df --format '{{.Size}}' 2>/dev/null | tail -1)"
for dir in ~/data ~/eval ~/triton ~/unsloth-data ~/.n8n ~/label-studio-data ~/.cache/huggingface; do
  if [ -d "$dir" ]; then
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    printf "  %-20s %s\n" "$(basename "$dir")" "$size"
  fi
done

echo ""
echo "GPU TELEMETRY"
if python3 -c "from telemetry.sampler import GPUSampler" 2>/dev/null; then
  # Package importable — try to sample (may fail at runtime)
  python3 - <<'PYEOF' || echo "  sampling failed"
try:
    from telemetry.sampler import GPUSampler
    s = GPUSampler()
    d = s.sample()
    if d.get("mock"):
        print("  Mode:         mock (no GPU detected)")
    print(f"  Watts:        {d['watts']!s:>8}")
    print(f"  Temperature:  {d['temperature_c']!s:>8}")
    print(f"  Utilization:  {d['gpu_util_pct']!s:>8}")
    if d['mem_available_gb'] is not None:
        print(f"  MemAvailable: {d['mem_available_gb']:.1f} GB")
    else:
        print("  MemAvailable:     N/A")
except Exception as e:
    import sys
    print(f"  sampling failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
else
  echo "  sampler not installed"
fi

echo ""

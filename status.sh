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
check_service "litellm" "4000"
check_service "vllm" "8020"
check_service "triton-trtllm" "8010"

echo ""
echo "FINE-TUNING"
check_service "unsloth-studio" "8000"

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

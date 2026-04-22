#!/usr/bin/env bash

# Shared helpers for DGX Toolbox sparkrun wrapper scripts.

_dgx_mode_env_path() {
  printf '%s\n' "${DGX_TOOLBOX_CONFIG_DIR:-$HOME/.config/dgx-toolbox}/mode.env"
}

_dgx_read_mode_var() {
  local _key="$1"
  local _direct="${!_key:-}"
  if [ -n "$_direct" ]; then
    printf '%s\n' "$_direct"
    return 0
  fi

  local _mode_env
  _mode_env="$(_dgx_mode_env_path)"
  if [ -f "$_mode_env" ]; then
    # shellcheck disable=SC1090
    . "$_mode_env"
    printf '%s\n' "${!_key:-}"
  fi
}

_dgx_host_args() {
  local _dgx_mode
  _dgx_mode="$(_dgx_read_mode_var DGX_MODE)"
  [ "$_dgx_mode" = "single" ] || return 0

  local _arg
  for _arg in "$@"; do
    case "$_arg" in
      --hosts|--hosts=*|-H|--hosts-file|--hosts-file=*|--cluster|--cluster=*|--solo)
        return 0
        ;;
    esac
  done

  printf -- '--hosts\nlocalhost\n'
}

_dgx_collect_host_args() {
  local _line
  local -n _target_ref="$1"
  shift
  while IFS= read -r _line; do
    [ -n "$_line" ] && _target_ref+=("$_line")
  done < <(_dgx_host_args "$@")
}

_dgx_vllm_autoregister_watchdog() {
  local _attempts=${DGX_WATCHDOG_ATTEMPTS:-240}
  local _sleep=${DGX_WATCHDOG_SLEEP:-5}
  local _host_args=()
  _dgx_collect_host_args _host_args

  while [ "$_attempts" -gt 0 ]; do
    sleep "$_sleep"
    _attempts=$(( _attempts - 1 ))

    if ! sparkrun proxy status --json 2>/dev/null | grep -q '"running":[[:space:]]*true'; then
      continue
    fi

    local _out
    _out=$(sparkrun proxy models "${_host_args[@]}" --refresh 2>&1) || continue
    if echo "$_out" | grep -qE 'Synced proxy models:.* added'; then
      echo "[vllm] Registered new workload with LiteLLM proxy (:4000)" >&2
      _dgx_fix_litellm_models >/dev/null 2>&1 || true
      return 0
    fi
  done

  return 1
}

_dgx_fix_litellm_models() {
  python3 <<'EOF_PY'
import json, urllib.request, os

# Try to resolve master key and port from sparkrun state
master_key = "sk-sparkrun"
port = 4000
state_path = os.path.expanduser("~/.cache/sparkrun/proxy/state.yaml")
if os.path.exists(state_path):
    try:
        import yaml
        with open(state_path) as f:
            state = yaml.safe_load(f)
            master_key = state.get("master_key", master_key)
            port = state.get("port", port)
    except: pass

def api_req(method, path, payload=None):
    url = f"http://localhost:{port}{path}"
    headers = {"Content-Type": "application/json"}
    if master_key: headers["Authorization"] = f"Bearer {master_key}"
    data = json.dumps(payload).encode() if payload else None
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except: return None

models_data = api_req("GET", "/model/info")
if models_data and "data" in models_data:
    for m in models_data["data"]:
        name = m.get("model_name")
        params = m.get("litellm_params", m.get("model_info", {}).get("litellm_params", {}))
        if not name or not params: continue
        
        model_id = params.get("model", "")
        changed = False
        # Ensure openai/ prefix (forces chat endpoint routing)
        if not model_id.startswith("openai/"):
            params["model"] = f"openai/{model_id.split('/')[-1]}"
            changed = True
        # Ensure drop_params: True (prevents vLLM rejection of OpenAI-specific extras)
        if params.get("drop_params") != True:
            params["drop_params"] = True
            changed = True
            
        if changed:
            api_req("POST", "/model/new", {"model_name": name, "litellm_params": params})
EOF_PY
}

_dgx_vllm_should_autoregister() {
  local _dgx_autoreg
  _dgx_autoreg="$(_dgx_read_mode_var DGX_PROXY_AUTOREGISTER)"
  if [ -z "$_dgx_autoreg" ]; then
    _dgx_autoreg=1
  fi
  [ "$_dgx_autoreg" = "1" ]
}

_dgx_vllm_resolve_recipe() {
  local _recipe="$1"
  # Determine repo root relative to this sourced script (scripts/_dgx_sparkrun_wrappers.sh)
  local _repo_root
  _repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local _local="$_repo_root/recipes/${_recipe}.yaml"

  if [ -f "$_recipe" ]; then
    printf '%s\n' "$_recipe"
  elif [ -f "$_local" ]; then
    printf '%s\n' "$_local"
  else
    printf '%s\n' "$_recipe"
  fi
}

_dgx_exec_sparkrun() {
  if [ "$(type -t sparkrun 2>/dev/null)" = "function" ]; then
    sparkrun "$@"
  else
    exec sparkrun "$@"
  fi
}

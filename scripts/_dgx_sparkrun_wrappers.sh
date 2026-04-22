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
  local _attempts=240
  local _host_args=()
  _dgx_collect_host_args _host_args

  while [ "$_attempts" -gt 0 ]; do
    sleep 5
    _attempts=$(( _attempts - 1 ))

    if ! sparkrun proxy status --json 2>/dev/null | grep -q '"running":[[:space:]]*true'; then
      continue
    fi

    local _out
    _out=$(sparkrun proxy models "${_host_args[@]}" --refresh 2>&1) || continue
    if echo "$_out" | grep -qE 'Synced proxy models:.* added'; then
      echo "[vllm] Registered new workload with LiteLLM proxy (:4000)" >&2
      return 0
    fi
  done

  return 1
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
  local _local="$HOME/dgx-toolbox/recipes/${_recipe}.yaml"

  if [ -f "$_recipe" ]; then
    printf '%s\n' "$_recipe"
  elif [ -f "$_local" ]; then
    printf '%s\n' "$_local"
  else
    printf '%s\n' "$_recipe"
  fi
}

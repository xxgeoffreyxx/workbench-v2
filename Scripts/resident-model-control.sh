#!/bin/bash
# resident-model-control.sh — start/stop/restart/status for the resident MLX models
# behind the Thunderbolt router (:8110). Wired to the REAL launchd jobs + omlx ports
# (verified 2026-06-27; replaces the stale pre-omlx mlx_lm.server wiring).
#
#   Canonical model   host    ssh           launchd label                    port
#   deepseek-coder    m1max   m1max@        com.hosaka.helga-ornith          8101
#
# 2026-09-24: Ornith (Helga) is the only resident router model; the Qwen30/Qwen3-4B/
# DeepSeek-V2 jobs are retired. Router alias: hosaka-helga->deepseek-coder.
# New models/Macs: add a line to resolve() (node m1|m2, extend remotes_for/bases_for for a new Mac).
set -euo pipefail

MODEL="${1:-}"
ACTION="${2:-}"

M1_REMOTE="${M1MAX_SSH_HOST:-m1max@169.254.36.71}"
M2_REMOTE="${M2PRO_SSH_HOST:-m2pro@169.254.59.133}"
M1_REMOTE_FALLBACK="${M1MAX_SSH_FALLBACK_HOST:-m1max@m1max.local}"
M2_REMOTE_FALLBACK="${M2PRO_SSH_FALLBACK_HOST:-m2pro@m2pro.local}"

M1_BASES=(
  "${THUNDERBOLT_M1MAX_BASE:-http://169.254.36.71}"
  "${M1MAX_MDNS_BASE:-http://m1max.local}"
  "${M1MAX_WIFI_BASE:-http://192.168.86.27}"
)
M2_BASES=(
  "${THUNDERBOLT_M2PRO_BASE:-http://169.254.59.133}"
  "${M2PRO_MDNS_BASE:-http://m2pro.local}"
  "${M2PRO_WIFI_BASE:-http://192.168.1.208}"
)

usage() {
  cat >&2 <<'EOF'
Usage:
  resident-model-control.sh <model> <start|stop|restart|status>

Models (canonical or alias):
  deepseek-coder  (hosaka-helga, ornith)  Ornith on m1max:8101
EOF
}

# model/alias -> "node launchd-label port"
resolve() {
  case "$1" in
    deepseek-coder|hosaka-helga|ornith)     echo "m1 com.hosaka.helga-ornith 8101" ;;
    *)                                      echo "" ;;
  esac
}

remotes_for() { if [ "$1" = m1 ]; then echo "$M1_REMOTE $M1_REMOTE_FALLBACK"; else echo "$M2_REMOTE $M2_REMOTE_FALLBACK"; fi; }
bases_for()   { if [ "$1" = m1 ]; then printf '%s\n' "${M1_BASES[@]}"; else printf '%s\n' "${M2_BASES[@]}"; fi; }

remote_any() {
  local command="$1"; shift
  local host last_status=0
  for host in "$@"; do
    [[ -z "$host" ]] && continue
    if ssh -o BatchMode=yes -o ConnectTimeout=6 "$host" "$command"; then return 0; fi
    last_status=$?
  done
  return "$last_status"
}

do_status() {
  local node="$1" port="$2" url response attempted=()
  while read -r url; do
    [[ -z "$url" ]] && continue
    attempted+=("$url:$port")
    if response="$(curl -fsS --max-time 6 "$url:$port/v1/models" 2>/dev/null)"; then
      printf 'ready via %s:%s\n%s\n' "$url" "$port" "$response"
      return 0
    fi
  done < <(bases_for "$node")
  printf 'unreachable via: %s\n' "${attempted[*]}" >&2
  return 1
}

do_start() {
  local node="$1" label="$2"
  remote_any "launchctl kickstart -k gui/\$(id -u)/$label >/dev/null 2>&1 || launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$label.plist" $(remotes_for "$node")
}

do_stop() {
  local node="$1" label="$2"
  remote_any "launchctl bootout gui/\$(id -u)/$label >/dev/null 2>&1 || true" $(remotes_for "$node")
}

[[ -z "$MODEL" ]] && { usage; exit 1; }
read -r NODE LABEL PORT <<< "$(resolve "$MODEL")"
[[ -z "${NODE:-}" ]] && { echo "Unknown model: $MODEL" >&2; usage; exit 1; }

case "$ACTION" in
  status)  do_status "$NODE" "$PORT" ;;
  start)   do_start "$NODE" "$LABEL"; sleep 1; do_status "$NODE" "$PORT" || true ;;
  stop)    do_stop "$NODE" "$LABEL" ;;
  restart) do_stop "$NODE" "$LABEL"; sleep 1; do_start "$NODE" "$LABEL"; sleep 1; do_status "$NODE" "$PORT" || true ;;
  *)       usage; exit 1 ;;
esac

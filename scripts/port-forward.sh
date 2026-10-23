#!/usr/bin/env bash
# =============================================================================
# port-forward.sh - background kubectl port-forwards for the observability UIs
# =============================================================================
#
# PURPOSE
#   bash equivalent of port-forward.ps1. Opens the UIs this project uses on
#   fixed local ports:
#
#       Grafana       http://localhost:3000   svc/kube-prometheus-stack-grafana      (ns monitoring)
#       Prometheus    http://localhost:9090   svc/kube-prometheus-stack-prometheus   (ns monitoring)
#       Alertmanager  http://localhost:9093   svc/kube-prometheus-stack-alertmanager (ns monitoring)
#       orders-api    http://localhost:8080   svc/orders-api                         (ns demo, --include-app)
#
#   Each forward is a detached background process; its PID is recorded in
#   .portforward-pids at the repo root so --stop terminates exactly the
#   processes this script started, and nothing else.
#
# USAGE
#   ./scripts/port-forward.sh
#   ./scripts/port-forward.sh --include-app
#   ./scripts/port-forward.sh --stop
#   ./scripts/port-forward.sh --status
#
# PARAMETERS
#       --include-app   also forward orders-api on 8080 (needed by
#                       trigger-incident.sh when not using the k6 Job path)
#       --stop          kill every port-forward recorded in .portforward-pids
#       --status        list the recorded forwards and whether they are alive
#   -h, --help          print usage and exit 0
#
# PREREQUISITES
#   ./scripts/install-stack.sh (and ./scripts/deploy-app.sh for --include-app).
#
# WHAT IT CHANGES
#   Starts local background processes and writes <repo>/.portforward-pids.
#   Nothing inside the cluster is modified.
#
# HOW TO UNDO IT
#   ./scripts/port-forward.sh --stop
#
# Ahmed Fakhfakh - DevOps / SRE
# =============================================================================

set -uo pipefail
# NOTE: deliberately NOT `set -e` here - a single failed port-forward (port
# already in use, Service missing) should be reported and skipped, not abort
# the whole script before the other forwards get a chance to start.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# -----------------------------------------------------------------------------
MONITORING_NS="monitoring"
APP_NS="demo"
KPS_RELEASE="kube-prometheus-stack"
APP_NAME="orders-api"

GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="observability"

DASH_UID_APP_RED="obs-app-red"
DASH_UID_SLO_BUDGET="obs-slo-budget"
DASH_UID_CLUSTER="obs-k8s-cluster"
DASH_UID_LOGS="obs-logs-explorer"

PID_FILE="${REPO_ROOT}/.portforward-pids"

INCLUDE_APP=0
DO_STOP=0
DO_STATUS=0

if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""
else
  C_RESET="\033[0m"; C_CYAN="\033[36m"; C_GREEN="\033[32m"
  C_YELLOW="\033[33m"; C_RED="\033[31m"; C_GREY="\033[90m"; C_WHITE="\033[97m"
fi

step() { printf "\n${C_CYAN}==> %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}    [ OK ] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}    [WARN] %s${C_RESET}\n" "$*"; }
err()  { printf "${C_RED}    [FAIL] %s${C_RESET}\n" "$*"; }
info() { printf "${C_GREY}    %s${C_RESET}\n" "$*"; }

usage() {
  cat <<EOF
port-forward.sh - background port-forwards for Grafana, Prometheus, Alertmanager

USAGE
    ./scripts/port-forward.sh [--include-app] [--stop] [--status] [-h|--help]

OPTIONS
        --include-app   also forward ${APP_NAME} on 8080
        --stop          kill every forward recorded in .portforward-pids
        --status        show the recorded forwards and whether they are alive
    -h, --help          print this help and exit

PORTS
    3000 Grafana   9090 Prometheus   9093 Alertmanager   8080 ${APP_NAME}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-app) INCLUDE_APP=1; shift ;;
    --stop)        DO_STOP=1; shift ;;
    --status)      DO_STATUS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# PID file helpers - "port<TAB>pid<TAB>label" per line, machine-parseable and
# readable in a plain editor.
# -----------------------------------------------------------------------------
pid_alive() { kill -0 "$1" 2>/dev/null; }

# -----------------------------------------------------------------------------
# --status
# -----------------------------------------------------------------------------
if [[ "${DO_STATUS}" -eq 1 ]]; then
  step "Recorded port-forwards"
  if [[ ! -f "${PID_FILE}" ]]; then
    info "no .portforward-pids file - nothing has been started from this repo"
    exit 0
  fi
  printf " %-6s %-8s %-16s %s\n" "PORT" "PID" "TARGET" "STATE"
  while IFS=$'\t' read -r port pid label; do
    [[ -z "${port}" ]] && continue
    if pid_alive "${pid}"; then state="running"; else state="dead"; fi
    printf " %-6s %-8s %-16s %s\n" "${port}" "${pid}" "${label}" "${state}"
  done < "${PID_FILE}"
  exit 0
fi

# -----------------------------------------------------------------------------
# --stop
# -----------------------------------------------------------------------------
if [[ "${DO_STOP}" -eq 1 ]]; then
  step "Stopping port-forwards recorded in .portforward-pids"
  if [[ ! -f "${PID_FILE}" ]]; then
    info "nothing to stop (no .portforward-pids file)"
    exit 0
  fi
  while IFS=$'\t' read -r port pid label; do
    [[ -z "${port}" ]] && continue
    if pid_alive "${pid}"; then
      if kill "${pid}" 2>/dev/null; then
        ok "stopped ${label} on port ${port} (pid ${pid})"
      else
        warn "could not stop pid ${pid}"
      fi
    else
      info "${label} (pid ${pid}) was already gone"
    fi
  done < "${PID_FILE}"
  rm -f "${PID_FILE}"
  ok "removed .portforward-pids"
  printf "\n"
  exit 0
fi

# -----------------------------------------------------------------------------
# Start mode
# -----------------------------------------------------------------------------
printf "\n${C_WHITE}k8s-observability-stack - port-forward${C_RESET}\n"
printf "${C_GREY}repo root : %s${C_RESET}\n" "${REPO_ROOT}"

step "Checking prerequisites"

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl not found on PATH"
  exit 1
fi
ok "kubectl found"

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster - run ./scripts/cluster-up.sh first"
  exit 1
fi
ok "cluster reachable"

# Idempotent restart: kill anything still alive from a previous run first so
# the ports are free, rather than failing with "address already in use".
if [[ -f "${PID_FILE}" ]]; then
  LIVE=0
  while IFS=$'\t' read -r port pid label; do
    [[ -z "${port}" ]] && continue
    if pid_alive "${pid}"; then
      kill "${pid}" 2>/dev/null || true
      LIVE=$(( LIVE + 1 ))
    fi
  done < "${PID_FILE}"
  if [[ "${LIVE}" -gt 0 ]]; then
    warn "${LIVE} port-forward(s) from a previous run were still alive - stopped them"
    sleep 0.5
  fi
  rm -f "${PID_FILE}"
fi

port_free() {
  # Prefer a non-destructive TCP probe so this works whether or not `ss`/`lsof`
  # exist. A successful connect means something is already listening.
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

step "Starting port-forwards"

declare -a LABELS=()
declare -a URLS=()
declare -a SERVICES=()
declare -a NAMESPACES=()
: > "${PID_FILE}"

start_forward() {
  local label="$1" namespace="$2" service="$3" local_port="$4" remote_port="$5" url="$6"

  if ! kubectl -n "${namespace}" get "${service}" >/dev/null 2>&1; then
    warn "${service} not found in namespace ${namespace} - skipping ${label}"
    if [[ "${label}" == "${APP_NAME}" ]]; then
      info "run ./scripts/deploy-app.sh first"
    else
      info "run ./scripts/install-stack.sh first"
    fi
    return
  fi

  if ! port_free "${local_port}"; then
    warn "local port ${local_port} is already in use - skipping ${label}"
    info "if that is an old forward from this repo: ./scripts/port-forward.sh --stop"
    return
  fi

  kubectl -n "${namespace}" port-forward "${service}" "${local_port}:${remote_port}" --address=127.0.0.1 \
    >/dev/null 2>&1 &
  local pid=$!
  disown "${pid}" 2>/dev/null || true

  printf "%s\t%s\t%s\n" "${local_port}" "${pid}" "${label}" >> "${PID_FILE}"
  LABELS+=("${label}"); URLS+=("${url}"); SERVICES+=("${service} (ns ${namespace})"); NAMESPACES+=("${namespace}")
  ok "${label} -> ${url} (pid ${pid})"
}

start_forward "grafana"      "${MONITORING_NS}" "svc/${KPS_RELEASE}-grafana"      3000 80   "http://localhost:3000"
start_forward "prometheus"   "${MONITORING_NS}" "svc/${KPS_RELEASE}-prometheus"   9090 9090 "http://localhost:9090"
start_forward "alertmanager" "${MONITORING_NS}" "svc/${KPS_RELEASE}-alertmanager" 9093 9093 "http://localhost:9093"

if [[ "${INCLUDE_APP}" -eq 1 ]]; then
  start_forward "${APP_NAME}" "${APP_NS}" "svc/${APP_NAME}" 8080 8080 "http://localhost:8080"
fi

if [[ ! -s "${PID_FILE}" ]]; then
  err "no port-forwards could be started"
  exit 1
fi

# kubectl needs a moment to establish each tunnel before the first request
# succeeds.
sleep 3

# Drop any forward that died immediately (usually a port race lost after the
# free-port check above).
TMP_PID_FILE="$(mktemp)"
while IFS=$'\t' read -r port pid label; do
  [[ -z "${port}" ]] && continue
  if pid_alive "${pid}"; then
    printf "%s\t%s\t%s\n" "${port}" "${pid}" "${label}" >> "${TMP_PID_FILE}"
  else
    warn "the ${label} forward exited immediately - port ${port} may have been taken"
  fi
done < "${PID_FILE}"
mv "${TMP_PID_FILE}" "${PID_FILE}"
info "PIDs recorded in .portforward-pids"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} PORT-FORWARDS ACTIVE${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf " %-14s %-28s %s\n" "UI" "URL" "KUBERNETES SERVICE"
printf " -------------- ---------------------------- -----------------------------\n"
for i in "${!LABELS[@]}"; do
  printf " %-14s %-28s %s\n" "${LABELS[$i]}" "${URLS[$i]}" "${SERVICES[$i]}"
done

printf "\n GRAFANA LOGIN\n"
printf "   user     : %s\n" "${GRAFANA_ADMIN_USER}"
printf "   password : %s\n" "${GRAFANA_ADMIN_PASS}"
printf "   (stored in Secret 'grafana-admin-credentials' in namespace '%s')\n" "${MONITORING_NS}"

printf "\n DASHBOARD DEEP LINKS\n"
printf " %-34s %s\n" "Orders API - RED Metrics"        "http://localhost:3000/d/${DASH_UID_APP_RED}"
printf " %-34s %s\n" "Orders API - SLO & Error Budget" "http://localhost:3000/d/${DASH_UID_SLO_BUDGET}"
printf " %-34s %s\n" "Kubernetes - Cluster Health"     "http://localhost:3000/d/${DASH_UID_CLUSTER}"
printf " %-34s %s\n" "Orders API - Logs Explorer"      "http://localhost:3000/d/${DASH_UID_LOGS}"

printf "\n USEFUL PROMETHEUS / ALERTMANAGER PAGES\n"
printf "   targets  : http://localhost:9090/targets\n"
printf "   alerts   : http://localhost:9090/alerts\n"
printf "   rules    : http://localhost:9090/rules\n"
printf "   silences : http://localhost:9093/#/silences\n"

printf "\n These forwards survive this shell. Stop them with:\n"
printf "   ./scripts/port-forward.sh --stop\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

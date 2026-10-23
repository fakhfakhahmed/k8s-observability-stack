#!/usr/bin/env bash
# =============================================================================
# trigger-incident.sh - the LinkedIn demo: prove the alerting pipeline works
# =============================================================================
#
# PURPOSE
#   Runs load/k6/failure-scenario.js as a Kubernetes Job against orders-api.
#   That script, on its own, arms the app's chaos endpoints (35% forced 5xx,
#   25% of requests delayed 900ms), holds a steady broken state, generates
#   enough traffic for Prometheus to notice, then (best-effort) disarms chaos
#   again on exit. This script is the operator-friendly wrapper around that:
#   it checks prerequisites, regenerates the k6 ConfigMap from the REAL
#   source scripts (never a stale copy), prints the exact incident timeline
#   with live clock times, and tells you precisely what to screenshot and
#   when - because an alert nobody watched fire is not a demonstration of
#   anything.
#
#   A RED/FAILED k6 summary at the end is the CORRECT, EXPECTED result - see
#   load/k6/failure-scenario.js's header comment. This script's own exit code
#   reflects whether the DEMO ran successfully, not whether orders-api stayed
#   healthy (it is not supposed to).
#
# USAGE
#   ./scripts/trigger-incident.sh
#   ./scripts/trigger-incident.sh --duration 20m
#   ./scripts/trigger-incident.sh --error-pct 50 --latency-ms 1200 --latency-pct 40
#   ./scripts/trigger-incident.sh --no-follow
#
# PARAMETERS
#       --duration <k6 duration>   how long to hold the broken steady state
#                                   (default 10m; use 20m to also reach the
#                                   3x/1x ticket rungs, 45m for the latency page)
#       --vus <n>                  concurrent virtual users (default 10)
#       --error-pct <n>            % of requests forced to 5xx (default 35)
#       --latency-ms <n>           injected delay in ms (default 900)
#       --latency-pct <n>          % of requests delayed (default 25)
#       --no-follow                apply the Job and exit immediately instead
#                                   of streaming its logs (useful in CI)
#   -h, --help                     print usage and exit 0
#
# PREREQUISITES
#   orders-api deployed with CHAOS_ENABLED=true (the default in
#   app/k8s/deployment.yaml - ./scripts/deploy-app.sh already sets it).
#
# WHAT IT CHANGES
#   Regenerates ConfigMap 'k6-scripts' and creates Job 'k6-load-test' in
#   namespace 'demo'. Deletes any previous k6-load-test Job first (Jobs are
#   immutable once created). orders-api itself is deliberately broken for the
#   duration of the run via its own chaos endpoints - this is the point.
#
# HOW TO UNDO IT
#   ./scripts/heal.sh                 (disarms chaos; teardown() usually
#                                       already did this, but do not trust it)
#
# Ahmed Fakhfakh - DevOps / SRE
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NS="demo"
APP_NAME="orders-api"
K6_DIR="${REPO_ROOT}/load/k6"
JOB_NAME="k6-load-test"
CONFIGMAP_NAME="k6-scripts"

DURATION="10m"
VUS=10
ERROR_PCT=35
LATENCY_MS=900
LATENCY_PCT=25
FOLLOW=1

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
trigger-incident.sh - burn the error budget on purpose and watch the alerting fire

USAGE
    ./scripts/trigger-incident.sh [--duration <dur>] [--vus <n>]
        [--error-pct <n>] [--latency-ms <n>] [--latency-pct <n>] [--no-follow]

OPTIONS
        --duration <dur>   hold time, e.g. 10m / 20m / 45m (default ${DURATION})
        --vus <n>          concurrent virtual users (default ${VUS})
        --error-pct <n>    % of requests forced to 5xx (default ${ERROR_PCT})
        --latency-ms <n>   injected delay, ms (default ${LATENCY_MS})
        --latency-pct <n>  % of requests delayed (default ${LATENCY_PCT})
        --no-follow        apply the Job and exit, do not stream logs
    -h, --help             print this help and exit

RUNG TIMING GUIDE (default 35%/900ms/25%)
    ~5 min   ErrorBudgetBurn availability 14.4x (page)
    ~8 min   ErrorBudgetBurn availability 6x    (page)
    ~14 min  ErrorBudgetBurn availability 3x and 1x (ticket)
    ~37 min  ErrorBudgetBurn latency 14.4x (page) - needs --duration 45m
EOF
}

require_value() { if [[ -z "${2:-}" ]]; then err "option $1 requires a value"; exit 2; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)    require_value "$1" "${2:-}"; DURATION="$2"; shift 2 ;;
    --vus)         require_value "$1" "${2:-}"; VUS="$2"; shift 2 ;;
    --error-pct)   require_value "$1" "${2:-}"; ERROR_PCT="$2"; shift 2 ;;
    --latency-ms)  require_value "$1" "${2:-}"; LATENCY_MS="$2"; shift 2 ;;
    --latency-pct) require_value "$1" "${2:-}"; LATENCY_PCT="$2"; shift 2 ;;
    --no-follow)   FOLLOW=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

printf "\n${C_WHITE}k8s-observability-stack - trigger-incident${C_RESET}\n"
printf "${C_GREY}repo root : %s${C_RESET}\n" "${REPO_ROOT}"
printf "${C_GREY}profile   : %s VUs, %s hold, %s%% errors, %s%% @ %sms latency${C_RESET}\n" \
  "${VUS}" "${DURATION}" "${ERROR_PCT}" "${LATENCY_PCT}" "${LATENCY_MS}"

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
step "Checking prerequisites"

for tool in kubectl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "${tool} not found on PATH"
    exit 1
  fi
done
ok "kubectl found"

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster - run ./scripts/cluster-up.sh first"
  exit 1
fi
ok "cluster reachable"

if ! kubectl -n "${APP_NS}" get deployment "${APP_NAME}" >/dev/null 2>&1; then
  err "deployment/${APP_NAME} not found in namespace '${APP_NS}'"
  info "run ./scripts/deploy-app.sh first"
  exit 1
fi
ok "deployment/${APP_NAME} found"

CHAOS_FLAG="$(kubectl -n "${APP_NS}" get deployment "${APP_NAME}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHAOS_ENABLED")].value}' 2>/dev/null || true)"
if [[ "${CHAOS_FLAG}" != "true" ]]; then
  warn "CHAOS_ENABLED is not 'true' on deployment/${APP_NAME} (found: '${CHAOS_FLAG:-unset}')"
  info "the chaos endpoints will 404 and the k6 setup() will abort"
  info "fix with: kubectl -n ${APP_NS} set env deployment/${APP_NAME} CHAOS_ENABLED=true"
  info "          kubectl -n ${APP_NS} rollout status deployment/${APP_NAME}"
  exit 1
fi
ok "CHAOS_ENABLED=true confirmed"

for f in steady.js spike.js failure-scenario.js; do
  if [[ ! -f "${K6_DIR}/${f}" ]]; then
    err "missing ${K6_DIR}/${f}"
    exit 1
  fi
done
ok "k6 scripts present"

# -----------------------------------------------------------------------------
# Regenerate the ConfigMap from the REAL source files (never the trimmed copy
# baked into load/k8s/k6-job.yaml for reference), so edits to load/k6/*.js are
# always what actually runs.
# -----------------------------------------------------------------------------
step "Regenerating ConfigMap '${CONFIGMAP_NAME}' from load/k6/"

kubectl create configmap "${CONFIGMAP_NAME}" \
  --namespace "${APP_NS}" \
  --from-file="${K6_DIR}/steady.js" \
  --from-file="${K6_DIR}/spike.js" \
  --from-file="${K6_DIR}/failure-scenario.js" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "ConfigMap '${CONFIGMAP_NAME}' applied"

# -----------------------------------------------------------------------------
# Clear any previous run - a completed/failed Job's spec is immutable.
# -----------------------------------------------------------------------------
step "Clearing any previous ${JOB_NAME} Job"
kubectl -n "${APP_NS}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1
ok "namespace clear for a new run"

# -----------------------------------------------------------------------------
# Apply the incident Job
# -----------------------------------------------------------------------------
step "Starting the failure scenario (Job/${JOB_NAME})"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${APP_NS}
  labels:
    app.kubernetes.io/name: k6
    app.kubernetes.io/part-of: k8s-observability-stack
    app.kubernetes.io/component: trigger-incident
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    metadata:
      labels:
        app.kubernetes.io/name: k6
        app.kubernetes.io/part-of: k8s-observability-stack
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          args: ["run", "/scripts/failure-scenario.js"]
          env:
            - name: BASE_URL
              value: "http://${APP_NAME}.${APP_NS}.svc.cluster.local:8080"
            - name: DURATION
              value: "${DURATION}"
            - name: VUS
              value: "${VUS}"
            - name: ERROR_PCT
              value: "${ERROR_PCT}"
            - name: LATENCY_MS
              value: "${LATENCY_MS}"
            - name: LATENCY_PCT
              value: "${LATENCY_PCT}"
            - name: TESTID
              value: "trigger-incident"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 500m, memory: 256Mi }
      volumes:
        - name: scripts
          configMap:
            name: ${CONFIGMAP_NAME}
EOF
ok "job/${JOB_NAME} created"

# -----------------------------------------------------------------------------
# Watch / screenshot guidance - printed BEFORE the logs so it's visible even
# if the terminal scrolls fast once k6 starts streaming request output.
# -----------------------------------------------------------------------------
printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_WHITE} INCIDENT RUNNING - WATCH / SCREENSHOT, IN THIS ORDER${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "  1. http://localhost:3000/d/obs-app-red        RED dashboard: error %%, p99, in-flight climbing\n"
printf "  2. http://localhost:3000/d/obs-slo-budget      SLO dashboard: burn-rate ladder crossing 14.4x\n"
printf "  3. http://localhost:9090/alerts                Prometheus: PENDING then FIRING\n"
printf "  4. http://localhost:9093                       Alertmanager: grouped, routed, runbook_url visible\n"
printf "  5. Tempo (via Grafana): a trace with the injected chaos span and its correlated log line\n"
printf "  6. http://localhost:3000/d/obs-logs-explorer    Logs: error-level lines for orders-api\n"
printf "\n  (If a UI above is not open yet: ./scripts/port-forward.sh)\n"
printf "\n  Approximate timing at the defaults (35%% errors / 900ms / 25%%):\n"
printf "    ~5 min   ErrorBudgetBurn availability 14.4x fires (page)\n"
printf "    ~8 min   ErrorBudgetBurn availability 6x fires (page)\n"
printf "    ~14 min  ErrorBudgetBurn availability 3x and 1x fire (ticket)\n"
printf "    ~37 min  ErrorBudgetBurn latency 14.4x fires (page) - needs --duration 45m\n"
printf "\n  A RED/FAILED k6 summary at the end is the CORRECT result - see\n"
printf "  load/k6/failure-scenario.js's header comment for why.\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"

if [[ "${FOLLOW}" -eq 0 ]]; then
  info "not following logs (--no-follow) - stream them yourself with:"
  info "    kubectl logs -f job/${JOB_NAME} -n ${APP_NS}"
  printf "\n"
  exit 0
fi

step "Streaming job/${JOB_NAME} logs (Ctrl-C to detach - the Job keeps running)"
printf "\n"

# Wait for the pod to exist before trying to follow its logs - the scheduler
# needs a moment, and `kubectl logs -f` on a not-yet-created pod just errors.
for _ in $(seq 1 30); do
  if kubectl -n "${APP_NS}" get pods -l "job-name=${JOB_NAME}" \
       -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

kubectl logs -f "job/${JOB_NAME}" -n "${APP_NS}" || true

printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} INCIDENT RUN FINISHED${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf " teardown() inside failure-scenario.js should have already called /chaos/reset.\n"
printf " DO NOT TRUST IT - confirm (or force it) with:\n"
printf "   ./scripts/heal.sh\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

#!/usr/bin/env bash
# =============================================================================
# heal.sh - the escape hatch: disarm chaos on every orders-api pod
# =============================================================================
#
# PURPOSE
#   scripts/trigger-incident.sh's own teardown is best-effort (see
#   load/k6/failure-scenario.js's header comment on exactly why a k6 Job's
#   teardown() can fail to run: SIGKILL, activeDeadlineSeconds, node loss,
#   or you closing your laptop mid-demo). This script is the AUTHORITATIVE,
#   idempotent "stop the bleeding" command - run it any time you are not sure
#   whether chaos is still armed.
#
#   Chaos state lives IN-MEMORY, per pod (see app/main.go's chaosState comment)
#   - there is no single place to reset it. This script therefore iterates
#     every orders-api pod individually and calls its own /chaos/reset,
#     rather than hitting the Service once (which would only reach ONE
#     replica, at random, behind the ClusterIP load balancer).
#
# USAGE
#   ./scripts/heal.sh
#   ./scripts/heal.sh --restart     # also rollout-restart the Deployment
#                                     (guarantees a clean slate even if a pod's
#                                     /chaos/reset call itself fails)
#
# WHAT IT CHANGES
#   Calls /chaos/reset inside every orders-api pod. With --restart, also
#   triggers a rolling restart of deployment/orders-api in namespace 'demo'.
#   Also deletes a completed/failed k6-load-test Job so trigger-incident.sh
#   can be re-run without a manual `kubectl delete job` first.
#
# Ahmed Fakhfakh - DevOps / SRE
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NS="demo"
APP_NAME="orders-api"
APP_PORT=8080

DO_RESTART=0

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
heal.sh - disarm chaos on every ${APP_NAME} pod (the trigger-incident escape hatch)

USAGE
    ./scripts/heal.sh [--restart] [-h|--help]

OPTIONS
    --restart   also rollout-restart deployment/${APP_NAME} for a guaranteed
                clean slate, even if a pod's own /chaos/reset call fails
    -h, --help  print this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart) DO_RESTART=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

printf "\n${C_WHITE}k8s-observability-stack - heal${C_RESET}\n"
printf "${C_GREY}repo root : %s${C_RESET}\n" "${REPO_ROOT}"

step "Checking prerequisites"

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl not found on PATH"
  exit 1
fi
ok "kubectl found"

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster"
  exit 1
fi
ok "cluster reachable"

# -----------------------------------------------------------------------------
# Reset chaos on every pod individually
# -----------------------------------------------------------------------------
step "Resetting chaos on every ${APP_NAME} pod in '${APP_NS}'"

mapfile -t PODS < <(kubectl -n "${APP_NS}" get pods -l "app.kubernetes.io/name=${APP_NAME}" \
  --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

if [[ "${#PODS[@]}" -eq 0 ]]; then
  warn "no Running ${APP_NAME} pods found in namespace '${APP_NS}'"
  info "nothing to heal - is the app deployed? ./scripts/deploy-app.sh"
else
  RESET_OK=0
  RESET_FAIL=0
  for pod in "${PODS[@]}"; do
    RESULT="$(kubectl -n "${APP_NS}" exec "${pod}" -- sh -c \
      "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT}/chaos/reset 2>/dev/null \
       || wget -q -O /dev/null --timeout=5 --server-response http://127.0.0.1:${APP_PORT}/chaos/reset 2>&1 | grep -o '[0-9]\{3\}' | tail -1" \
      2>/dev/null || true)"

    if [[ "${RESULT}" == "200" ]] || [[ "${RESULT}" =~ ^2 ]]; then
      ok "${pod}: chaos reset (HTTP ${RESULT})"
      RESET_OK=$(( RESET_OK + 1 ))
    else
      warn "${pod}: chaos reset failed or inconclusive (result: '${RESULT:-no response}')"
      RESET_FAIL=$(( RESET_FAIL + 1 ))
    fi
  done

  if [[ "${RESET_FAIL}" -gt 0 ]] && [[ "${DO_RESTART}" -eq 0 ]]; then
    warn "${RESET_FAIL} pod(s) could not be confirmed healed"
    info "re-run with --restart for a guaranteed clean slate:"
    info "    ./scripts/heal.sh --restart"
  fi
fi

# -----------------------------------------------------------------------------
# Optional: rollout restart (chaos state is in-memory, so a fresh pod has none)
# -----------------------------------------------------------------------------
if [[ "${DO_RESTART}" -eq 1 ]]; then
  step "Rolling restart of deployment/${APP_NAME}"
  if kubectl -n "${APP_NS}" rollout restart "deployment/${APP_NAME}" >/dev/null 2>&1; then
    kubectl -n "${APP_NS}" rollout status "deployment/${APP_NAME}" --timeout=120s >/dev/null 2>&1 \
      && ok "deployment/${APP_NAME} restarted and ready" \
      || warn "rollout restart started but did not confirm ready within 120s"
  else
    err "rollout restart failed - deployment/${APP_NAME} may not exist"
  fi
fi

# -----------------------------------------------------------------------------
# Clean up a finished k6 Job so trigger-incident.sh can be re-run without a
# manual `kubectl delete job` first - Jobs are immutable once created.
# -----------------------------------------------------------------------------
step "Clearing any finished k6-load-test Job"

if kubectl -n "${APP_NS}" get job k6-load-test >/dev/null 2>&1; then
  kubectl -n "${APP_NS}" delete job k6-load-test --ignore-not-found >/dev/null 2>&1
  ok "removed job/k6-load-test"
else
  info "no k6-load-test Job present - nothing to remove"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} HEAL COMPLETE${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf " Verify on the dashboards (allow ~1 short-window period for alerts to clear):\n"
printf "   obs-app-red    error rate back near 0%%, p99 back under 300ms\n"
printf "   obs-slo-budget burn-rate ladder back under 1x\n"
printf "   Alertmanager   ErrorBudgetBurn / HighErrorRate resolved (not just silenced)\n"
printf "\n If an alert stays firing much longer than its short window after this,\n"
printf " something else is wrong - see docs/troubleshooting.md, not just this script.\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - tear down everything this repo installed
# =============================================================================
#
# PURPOSE
#   The reverse of install-stack.sh + deploy-app.sh, in reverse dependency
#   order:
#       1. Stop any local port-forwards (port-forward.sh --stop)
#       2. Delete the k6 Job/ConfigMap, if present
#       3. Delete the orders-api app (namespace 'demo' - Deployment, Service,
#          ServiceMonitor, PDB all go with it)
#       4. helm uninstall tempo, promtail, loki, kube-prometheus-stack
#       5. Delete the Grafana admin Secret and the 'monitoring' namespace
#       6. (--delete-crds only) delete the Prometheus Operator CRDs, which are
#          cluster-scoped and NOT removed by helm uninstall or namespace
#          deletion - they would otherwise survive and silently affect the
#          next install
#
#   Deleting the NAMESPACE rather than enumerating every object inside it is
#   deliberate: Helm's own uninstall removes what it tracks, but PVCs,
#   dynamically-provisioned PVs and any ConfigMap this project's scripts
#   created by hand (grafana-datasources, grafana-dashboard-*, k6-scripts) are
#   NOT Helm-owned and would otherwise be orphaned.
#
# USAGE
#   ./scripts/uninstall.sh
#   ./scripts/uninstall.sh --delete-crds
#   ./scripts/uninstall.sh --keep-namespaces
#   ./scripts/uninstall.sh --yes
#
# PARAMETERS
#       --delete-crds       also remove the Prometheus Operator CRDs
#                            (cluster-wide effect - see the warning below)
#       --keep-namespaces   uninstall the Helm releases and the app but leave
#                            the 'monitoring' and 'demo' namespaces in place
#   -y, --yes               skip the confirmation prompt
#   -h, --help               print usage and exit 0
#
# WHAT IT CHANGES
#   Removes every Helm release, Kubernetes object and (with --delete-crds)
#   CRD this project created. Does NOT touch minikube itself - run
#   `minikube delete` separately for a full teardown.
#
# HOW TO UNDO IT
#   ./scripts/install-stack.sh && ./scripts/deploy-app.sh
#
# Ahmed Fakhfakh - DevOps / SRE
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MONITORING_NS="monitoring"
APP_NS="demo"

KPS_RELEASE="kube-prometheus-stack"
LOKI_RELEASE="loki"
PROMTAIL_RELEASE="promtail"
TEMPO_RELEASE="tempo"

DELETE_CRDS=0
KEEP_NAMESPACES=0
ASSUME_YES=0

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
uninstall.sh - remove everything this repo installed

USAGE
    ./scripts/uninstall.sh [--delete-crds] [--keep-namespaces] [-y|--yes] [-h|--help]

OPTIONS
        --delete-crds       also delete the Prometheus Operator CRDs (cluster-wide)
        --keep-namespaces   leave '${MONITORING_NS}' and '${APP_NS}' in place
    -y, --yes               skip the confirmation prompt
    -h, --help              print this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-crds)     DELETE_CRDS=1; shift ;;
    --keep-namespaces) KEEP_NAMESPACES=1; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

printf "\n${C_WHITE}k8s-observability-stack - uninstall${C_RESET}\n"
printf "${C_GREY}repo root : %s${C_RESET}\n" "${REPO_ROOT}"

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl not found on PATH"
  exit 1
fi

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  warn "kubectl cannot reach a cluster - nothing to uninstall, or the cluster is already gone"
  exit 0
fi

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  printf "\nThis will delete:\n"
  printf "  - Helm releases: %s, %s, %s, %s\n" "${KPS_RELEASE}" "${LOKI_RELEASE}" "${PROMTAIL_RELEASE}" "${TEMPO_RELEASE}"
  printf "  - the orders-api app (namespace '%s')\n" "${APP_NS}"
  if [[ "${KEEP_NAMESPACES}" -eq 0 ]]; then
    printf "  - namespaces '%s' and '%s' (and everything left inside them)\n" "${MONITORING_NS}" "${APP_NS}"
  fi
  if [[ "${DELETE_CRDS}" -eq 1 ]]; then
    printf "  - the Prometheus Operator CRDs (cluster-wide - affects ANY other Prometheus install on this cluster)\n"
  fi
  read -r -p $'\nContinue? [y/N] ' REPLY
  if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    info "aborted - nothing was changed"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# 1. Stop local port-forwards first - they hold a kubectl process open against
# Services that are about to disappear, which otherwise just spews connection
# errors into the terminal for the rest of this run.
# -----------------------------------------------------------------------------
step "Stopping local port-forwards"
if [[ -x "${REPO_ROOT}/scripts/port-forward.sh" ]]; then
  "${REPO_ROOT}/scripts/port-forward.sh" --stop || true
else
  warn "scripts/port-forward.sh not found or not executable - skipping"
fi

# -----------------------------------------------------------------------------
# 2. k6 Job/ConfigMap
# -----------------------------------------------------------------------------
step "Removing the k6 load-test Job and ConfigMap"
kubectl -n "${APP_NS}" delete job k6-load-test --ignore-not-found >/dev/null 2>&1
kubectl -n "${APP_NS}" delete configmap k6-scripts --ignore-not-found >/dev/null 2>&1
ok "k6 resources removed (if present)"

# -----------------------------------------------------------------------------
# 3. orders-api app
# -----------------------------------------------------------------------------
step "Removing orders-api"
if kubectl get namespace "${APP_NS}" >/dev/null 2>&1; then
  kubectl delete -f "${REPO_ROOT}/app/k8s/servicemonitor.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f "${REPO_ROOT}/app/k8s/deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f "${REPO_ROOT}/app/k8s/service.yaml" --ignore-not-found >/dev/null 2>&1 || true
  ok "orders-api objects removed"
else
  info "namespace '${APP_NS}' does not exist - nothing to remove"
fi

# -----------------------------------------------------------------------------
# 4. Helm releases, in reverse install order
# -----------------------------------------------------------------------------
step "Uninstalling Helm releases from '${MONITORING_NS}'"

if command -v helm >/dev/null 2>&1; then
  for release in "${TEMPO_RELEASE}" "${PROMTAIL_RELEASE}" "${LOKI_RELEASE}" "${KPS_RELEASE}"; do
    if helm status "${release}" -n "${MONITORING_NS}" >/dev/null 2>&1; then
      helm uninstall "${release}" -n "${MONITORING_NS}" >/dev/null 2>&1 \
        && ok "uninstalled ${release}" \
        || warn "failed to uninstall ${release} - it may already be gone"
    else
      info "release '${release}' not found - skipping"
    fi
  done
else
  warn "helm not found on PATH - skipping Helm release uninstall (namespace deletion below still removes the workloads)"
fi

# -----------------------------------------------------------------------------
# 5. Namespaces (unless --keep-namespaces)
# -----------------------------------------------------------------------------
if [[ "${KEEP_NAMESPACES}" -eq 1 ]]; then
  step "Leaving namespaces in place (--keep-namespaces)"
  info "'${MONITORING_NS}' and '${APP_NS}' were left as-is; any remaining PVCs/ConfigMaps/Secrets live on in them"
else
  step "Deleting namespaces '${MONITORING_NS}' and '${APP_NS}'"
  kubectl delete namespace "${MONITORING_NS}" --ignore-not-found --timeout=120s >/dev/null 2>&1 \
    && ok "namespace '${MONITORING_NS}' deleted" \
    || warn "namespace '${MONITORING_NS}' deletion did not confirm within 120s - check: kubectl get namespace"
  kubectl delete namespace "${APP_NS}" --ignore-not-found --timeout=120s >/dev/null 2>&1 \
    && ok "namespace '${APP_NS}' deleted" \
    || warn "namespace '${APP_NS}' deletion did not confirm within 120s - check: kubectl get namespace"
fi

# -----------------------------------------------------------------------------
# 6. CRDs - cluster-scoped, survive both helm uninstall and namespace deletion.
# Only removed on explicit request because they could be shared with another
# Prometheus Operator install on the same cluster.
# -----------------------------------------------------------------------------
if [[ "${DELETE_CRDS}" -eq 1 ]]; then
  step "Deleting Prometheus Operator CRDs (cluster-wide)"
  CRDS=$(kubectl get crd -o name 2>/dev/null | grep 'monitoring.coreos.com' || true)
  if [[ -z "${CRDS}" ]]; then
    info "no monitoring.coreos.com CRDs found - already clean"
  else
    echo "${CRDS}" | xargs -r kubectl delete >/dev/null 2>&1 \
      && ok "Prometheus Operator CRDs deleted" \
      || warn "some CRDs may not have deleted - check: kubectl get crd | grep monitoring.coreos.com"
  fi
else
  step "Leaving CRDs in place"
  info "re-run with --delete-crds to remove monitoring.coreos.com CRDs cluster-wide"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} UNINSTALL COMPLETE${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf " The minikube cluster itself is untouched. For a full reset:\n"
printf "   minikube delete\n"
printf " To reinstall:\n"
printf "   ./scripts/cluster-up.sh && ./scripts/install-stack.sh && ./scripts/deploy-app.sh\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

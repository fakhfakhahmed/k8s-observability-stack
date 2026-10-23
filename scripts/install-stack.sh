#!/usr/bin/env bash
# =============================================================================
# install-stack.sh - install the full observability stack (metrics/logs/traces)
# =============================================================================
#
# PURPOSE
#   Installs, in dependency order, everything that lives in the 'monitoring'
#   namespace:
#
#       a. Helm repos 'prometheus-community' and 'grafana', then 'helm repo update'
#       b. Secret 'grafana-admin-credentials' (admin / observability)
#       c. kube-prometheus-stack  -f stack/prometheus/values.yaml
#       d. loki                   -f stack/loki/values.yaml
#       e. promtail               -f stack/loki/promtail-values.yaml
#       f. tempo                  -f stack/tempo/values.yaml
#       g. PrometheusRule objects from stack/prometheus/rules/
#       h. Grafana datasource + dashboard ConfigMaps (sidecar discovery)
#       i. kubectl rollout status for every workload
#       j. summary + next command
#
#   Every step is idempotent. Re-running the script is the supported way to
#   pick up edits to the values files or the dashboard JSON.
#
# USAGE
#   ./scripts/install-stack.sh
#   ./scripts/install-stack.sh --metrics-only
#   ./scripts/install-stack.sh --logs-only
#   ./scripts/install-stack.sh --traces-only
#   ./scripts/install-stack.sh --skip-dashboards
#   ./scripts/install-stack.sh --timeout 20
#
# PARAMETERS
#       --metrics-only      install only kube-prometheus-stack (+ rules, dashboards)
#       --logs-only         install only Loki + Promtail
#       --traces-only       install only Tempo
#       --skip-dashboards   skip the Grafana datasource/dashboard ConfigMaps
#   -t, --timeout <min>     Helm and rollout timeout in minutes (default 15)
#   -h, --help              print usage and exit 0
#
#   The three *-only flags are mutually exclusive. With none given, everything
#   is installed.
#
# PREREQUISITES
#   A running cluster (./scripts/cluster-up.sh) and helm on PATH.
#
# WHAT IT CHANGES
#   Creates four Helm releases, one Secret, several ConfigMaps and a set of
#   PrometheusRule custom resources in 'monitoring'. Also installs the
#   Prometheus Operator CRDs cluster-wide.
#
# HOW TO UNDO IT
#   ./scripts/uninstall.sh          (add --delete-crds to remove the CRDs too)
#
# Ahmed Fakhfakh - DevOps / SRE
# =============================================================================

set -euo pipefail
trap 'rc=$?; printf "\n[FATAL] %s failed at line %s (exit %s)\n" "${BASH_SOURCE[0]}" "${LINENO}" "${rc}" >&2; exit "${rc}"' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# -----------------------------------------------------------------------------
MONITORING_NS="monitoring"
APP_NS="demo"

KPS_RELEASE="kube-prometheus-stack"
LOKI_RELEASE="loki"
PROMTAIL_RELEASE="promtail"
TEMPO_RELEASE="tempo"

PROM_REPO_NAME="prometheus-community"
PROM_REPO_URL="https://prometheus-community.github.io/helm-charts"
GRAFANA_REPO_NAME="grafana"
GRAFANA_REPO_URL="https://grafana.github.io/helm-charts"

# -----------------------------------------------------------------------------
# Chart versions are PINNED DELIBERATELY.
#
# Why: an unpinned `helm upgrade --install` silently picks up whatever is newest
# in the repo index at the moment you run it, which makes the repo
# irreproducible - a reviewer cloning this in six months would get different
# dashboards, different CRD schemas and possibly broken values keys. Pinning
# means the screenshots in docs/screenshots/ always match what the scripts
# produce.
#
# How to check for newer versions (safe, read-only):
#     helm repo update
#     helm search repo prometheus-community/kube-prometheus-stack --versions | head
#     helm search repo grafana/loki     --versions | head
#     helm search repo grafana/promtail --versions | head
#     helm search repo grafana/tempo    --versions | head
#
# How to bump: change the constant below, re-run this script, and re-check the
# values files - major chart bumps frequently rename values keys.
# -----------------------------------------------------------------------------
KPS_VERSION="65.1.1"
LOKI_VERSION="6.16.0"
PROMTAIL_VERSION="6.16.6"
TEMPO_VERSION="1.10.3"

# Grafana admin credentials. Stored in a Secret so the values file can
# reference it via grafana.admin.existingSecret rather than hard-coding a
# password into a file that ends up on GitHub.
GRAFANA_SECRET_NAME="grafana-admin-credentials"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="observability"

# Paths, all relative to the repo root.
PROMETHEUS_VALUES="${REPO_ROOT}/stack/prometheus/values.yaml"
LOKI_VALUES="${REPO_ROOT}/stack/loki/values.yaml"
PROMTAIL_VALUES="${REPO_ROOT}/stack/loki/promtail-values.yaml"
TEMPO_VALUES="${REPO_ROOT}/stack/tempo/values.yaml"
RULES_DIR="${REPO_ROOT}/stack/prometheus/rules"
DATASOURCES_FILE="${REPO_ROOT}/stack/grafana/datasources/datasources.yaml"
DASHBOARDS_DIR="${REPO_ROOT}/stack/grafana/dashboards/json"

DO_METRICS=1
DO_LOGS=1
DO_TRACES=1
SKIP_DASHBOARDS=0
TIMEOUT_MINUTES=15
ONLY_COUNT=0

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
install-stack.sh - install Prometheus, Loki, Promtail and Tempo into '${MONITORING_NS}'

USAGE
    ./scripts/install-stack.sh [--metrics-only|--logs-only|--traces-only]
                               [--skip-dashboards] [-t|--timeout <min>] [-h|--help]

OPTIONS
        --metrics-only      only kube-prometheus-stack (plus rules and dashboards)
        --logs-only         only Loki + Promtail
        --traces-only       only Tempo
        --skip-dashboards   skip the Grafana datasource/dashboard ConfigMaps
    -t, --timeout <min>     Helm and rollout timeout, minutes (default ${TIMEOUT_MINUTES})
    -h, --help              print this help and exit

PINNED CHART VERSIONS
    kube-prometheus-stack  ${KPS_VERSION}
    loki                   ${LOKI_VERSION}
    promtail               ${PROMTAIL_VERSION}
    tempo                  ${TEMPO_VERSION}
EOF
}

require_value() {
  if [[ -z "${2:-}" ]]; then err "option $1 requires a value"; exit 2; fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metrics-only)    DO_LOGS=0; DO_TRACES=0; ONLY_COUNT=$(( ONLY_COUNT + 1 )); shift ;;
    --logs-only)       DO_METRICS=0; DO_TRACES=0; ONLY_COUNT=$(( ONLY_COUNT + 1 )); shift ;;
    --traces-only)     DO_METRICS=0; DO_LOGS=0; ONLY_COUNT=$(( ONLY_COUNT + 1 )); shift ;;
    --skip-dashboards) SKIP_DASHBOARDS=1; shift ;;
    -t|--timeout)      require_value "$1" "${2:-}"; TIMEOUT_MINUTES="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ "${ONLY_COUNT}" -gt 1 ]]; then
  err "--metrics-only, --logs-only and --traces-only are mutually exclusive"
  exit 2
fi

HELM_TIMEOUT="${TIMEOUT_MINUTES}m"
ROLLOUT_SECONDS=$(( TIMEOUT_MINUTES * 60 ))

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
assert_file() {
  local path="$1" purpose="$2"
  if [[ ! -f "${path}" ]]; then
    err "required file not found: ${path}"
    info "needed for: ${purpose}"
    exit 1
  fi
}

# Wait for a workload to finish rolling out. The workload is looked up first so
# that a chart renaming a resource between versions produces a clear warning
# rather than a hard failure halfway through the install.
wait_rollout() {
  local kind="$1" name="$2" ns="${3:-${MONITORING_NS}}"

  if ! kubectl get "${kind}" "${name}" -n "${ns}" >/dev/null 2>&1; then
    warn "${kind}/${name} not found in '${ns}' - skipping rollout wait"
    return 0
  fi

  info "waiting for ${kind}/${name} ..."
  if ! kubectl rollout status "${kind}/${name}" -n "${ns}" --timeout="${ROLLOUT_SECONDS}s" >/dev/null; then
    err "${kind}/${name} did not become ready within ${ROLLOUT_SECONDS}s"
    info "inspect with: kubectl -n ${ns} describe ${kind} ${name}"
    info "and:          kubectl -n ${ns} get pods"
    exit 1
  fi
  ok "${kind}/${name} ready"
}

printf "\n${C_WHITE}k8s-observability-stack - install-stack${C_RESET}\n"
printf "${C_GREY}repo root : %s${C_RESET}\n" "${REPO_ROOT}"
printf "${C_GREY}namespace : %s${C_RESET}\n" "${MONITORING_NS}"
printf "${C_GREY}layers    : metrics=%s logs=%s traces=%s skip-dashboards=%s${C_RESET}\n" \
  "${DO_METRICS}" "${DO_LOGS}" "${DO_TRACES}" "${SKIP_DASHBOARDS}"

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
step "Checking prerequisites"

for tool in helm kubectl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "${tool} not found on PATH"
    [[ "${tool}" == "helm" ]] && info "install with: brew install helm | winget install Helm.Helm"
    exit 1
  fi
  ok "${tool} found"
done

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster"
  info "run ./scripts/cluster-up.sh first"
  exit 1
fi
ok "cluster reachable"

# The namespace must exist before the Secret is created; --create-namespace on
# the Helm call would be too late for step (b).
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "namespace '${MONITORING_NS}' present"

# -----------------------------------------------------------------------------
# (a) Helm repositories
# -----------------------------------------------------------------------------
step "Adding Helm repositories"

# `helm repo add --force-update` is the idempotent form: it rewrites the entry
# instead of failing with "repository name already exists".
helm repo add "${PROM_REPO_NAME}" "${PROM_REPO_URL}" --force-update >/dev/null
ok "${PROM_REPO_NAME} -> ${PROM_REPO_URL}"

helm repo add "${GRAFANA_REPO_NAME}" "${GRAFANA_REPO_URL}" --force-update >/dev/null
ok "${GRAFANA_REPO_NAME} -> ${GRAFANA_REPO_URL}"

helm repo update "${PROM_REPO_NAME}" "${GRAFANA_REPO_NAME}" >/dev/null
ok "repo indexes refreshed"

# -----------------------------------------------------------------------------
# (b) Grafana admin Secret
#
# The create/--dry-run=client/apply pipeline is the idempotent way to manage a
# Secret imperatively: `kubectl create secret` alone fails on the second run,
# and `kubectl apply` alone cannot build the Secret from literals.
# -----------------------------------------------------------------------------
step "Creating the Grafana admin Secret '${GRAFANA_SECRET_NAME}'"

kubectl create secret generic "${GRAFANA_SECRET_NAME}" \
  --namespace "${MONITORING_NS}" \
  --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
  --from-literal=admin-password="${GRAFANA_ADMIN_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Secret '${GRAFANA_SECRET_NAME}' present (user '${GRAFANA_ADMIN_USER}')"

# -----------------------------------------------------------------------------
# (c) kube-prometheus-stack
# -----------------------------------------------------------------------------
if [[ "${DO_METRICS}" -eq 1 ]]; then
  step "Installing ${KPS_RELEASE} (chart version ${KPS_VERSION})"
  assert_file "${PROMETHEUS_VALUES}" "kube-prometheus-stack values"

  info "this pulls Prometheus, Alertmanager, Grafana, node-exporter and kube-state-metrics"
  info "first install typically takes 3-8 minutes"

  if ! helm upgrade --install "${KPS_RELEASE}" "${PROM_REPO_NAME}/kube-prometheus-stack" \
      --version "${KPS_VERSION}" \
      --namespace "${MONITORING_NS}" \
      --create-namespace \
      -f "${PROMETHEUS_VALUES}" \
      --wait \
      --timeout "${HELM_TIMEOUT}"; then
    err "helm upgrade --install ${KPS_RELEASE} failed"
    info "inspect with: kubectl -n ${MONITORING_NS} get pods"
    info "and:          helm -n ${MONITORING_NS} status ${KPS_RELEASE}"
    exit 1
  fi
  ok "${KPS_RELEASE} installed"
else
  info "skipping ${KPS_RELEASE} (metrics layer disabled)"
fi

# -----------------------------------------------------------------------------
# (d) Loki
# -----------------------------------------------------------------------------
if [[ "${DO_LOGS}" -eq 1 ]]; then
  step "Installing ${LOKI_RELEASE} (chart version ${LOKI_VERSION})"
  assert_file "${LOKI_VALUES}" "Loki values"

  if ! helm upgrade --install "${LOKI_RELEASE}" "${GRAFANA_REPO_NAME}/loki" \
      --version "${LOKI_VERSION}" \
      --namespace "${MONITORING_NS}" \
      --create-namespace \
      -f "${LOKI_VALUES}" \
      --wait \
      --timeout "${HELM_TIMEOUT}"; then
    err "helm upgrade --install ${LOKI_RELEASE} failed"
    info "a common cause is a PVC stuck Pending - check: kubectl -n ${MONITORING_NS} get pvc"
    exit 1
  fi
  ok "${LOKI_RELEASE} installed (push/query at http://loki.${MONITORING_NS}.svc.cluster.local:3100)"

  # ---------------------------------------------------------------------------
  # (e) Promtail - the log shipper. It must come after Loki so its push target
  # already resolves; otherwise its first few batches land in a retry loop.
  # ---------------------------------------------------------------------------
  step "Installing ${PROMTAIL_RELEASE} (chart version ${PROMTAIL_VERSION})"
  assert_file "${PROMTAIL_VALUES}" "Promtail values"

  if ! helm upgrade --install "${PROMTAIL_RELEASE}" "${GRAFANA_REPO_NAME}/promtail" \
      --version "${PROMTAIL_VERSION}" \
      --namespace "${MONITORING_NS}" \
      --create-namespace \
      -f "${PROMTAIL_VALUES}" \
      --wait \
      --timeout "${HELM_TIMEOUT}"; then
    err "helm upgrade --install ${PROMTAIL_RELEASE} failed"
    exit 1
  fi
  ok "${PROMTAIL_RELEASE} installed (DaemonSet tailing /var/log/pods)"
else
  info "skipping ${LOKI_RELEASE} and ${PROMTAIL_RELEASE} (logs layer disabled)"
fi

# -----------------------------------------------------------------------------
# (f) Tempo
# -----------------------------------------------------------------------------
if [[ "${DO_TRACES}" -eq 1 ]]; then
  step "Installing ${TEMPO_RELEASE} (chart version ${TEMPO_VERSION})"
  assert_file "${TEMPO_VALUES}" "Tempo values"

  if ! helm upgrade --install "${TEMPO_RELEASE}" "${GRAFANA_REPO_NAME}/tempo" \
      --version "${TEMPO_VERSION}" \
      --namespace "${MONITORING_NS}" \
      --create-namespace \
      -f "${TEMPO_VALUES}" \
      --wait \
      --timeout "${HELM_TIMEOUT}"; then
    err "helm upgrade --install ${TEMPO_RELEASE} failed"
    exit 1
  fi
  ok "${TEMPO_RELEASE} installed (OTLP gRPC at tempo.${MONITORING_NS}.svc.cluster.local:4317)"
else
  info "skipping ${TEMPO_RELEASE} (traces layer disabled)"
fi

# -----------------------------------------------------------------------------
# (g) PrometheusRule objects
#
# These are plain CRs, so `kubectl apply` is already idempotent. They are
# applied after kube-prometheus-stack because the PrometheusRule CRD only
# exists once the Prometheus Operator has been installed.
# -----------------------------------------------------------------------------
if [[ "${DO_METRICS}" -eq 1 ]]; then
  step "Applying PrometheusRule objects from stack/prometheus/rules/"

  if [[ ! -d "${RULES_DIR}" ]]; then
    warn "rules directory not found: ${RULES_DIR} - skipping"
  else
    RULE_COUNT=0
    while IFS= read -r rf; do
      [[ -z "${rf}" ]] && continue
      if ! kubectl apply -n "${MONITORING_NS}" -f "${rf}" >/dev/null; then
        err "kubectl apply -f $(basename "${rf}") failed"
        info "if this says 'no matches for kind PrometheusRule', install the metrics layer first"
        exit 1
      fi
      ok "applied $(basename "${rf}")"
      RULE_COUNT=$(( RULE_COUNT + 1 ))
    done < <(find "${RULES_DIR}" -maxdepth 1 -type f -name '*.yaml' | sort)

    if [[ "${RULE_COUNT}" -eq 0 ]]; then
      warn "no .yaml files under ${RULES_DIR}"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# (h) Grafana datasources and dashboards
#
# The Grafana chart runs two sidecar containers that watch ConfigMaps in the
# namespace and drop their contents into Grafana's provisioning directories:
#     label grafana_datasource=1  ->  /etc/grafana/provisioning/datasources
#     label grafana_dashboard=1   ->  /etc/grafana/provisioning/dashboards
# That is why the label matters far more than the ConfigMap name.
# -----------------------------------------------------------------------------
if [[ "${SKIP_DASHBOARDS}" -eq 1 ]]; then
  info "skipping Grafana datasource/dashboard ConfigMaps (--skip-dashboards)"
else
  step "Creating the Grafana datasource ConfigMap"

  if [[ ! -f "${DATASOURCES_FILE}" ]]; then
    warn "datasource file not found: ${DATASOURCES_FILE} - skipping"
  else
    # `kubectl label --local` edits the YAML in flight without touching the
    # cluster, so the final apply ships both data and label in one object.
    kubectl create configmap grafana-datasources \
      --namespace "${MONITORING_NS}" \
      --from-file="datasources.yaml=${DATASOURCES_FILE}" \
      --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_datasource=1 -o yaml \
      | kubectl apply -f - >/dev/null
    ok "ConfigMap 'grafana-datasources' applied (uids: prometheus, loki, tempo)"
  fi

  step "Creating one ConfigMap per Grafana dashboard"

  if [[ ! -d "${DASHBOARDS_DIR}" ]]; then
    warn "dashboard directory not found: ${DASHBOARDS_DIR} - skipping"
  else
    DASH_COUNT=0
    while IFS= read -r jf; do
      [[ -z "${jf}" ]] && continue
      BASE="$(basename "${jf}")"                       # app-red-metrics.json
      STEM="${BASE%.json}"                             # app-red-metrics
      CM_NAME="grafana-dashboard-$(printf '%s' "${STEM}" | tr '[:upper:]' '[:lower:]')"

      kubectl create configmap "${CM_NAME}" \
        --namespace "${MONITORING_NS}" \
        --from-file="${BASE}=${jf}" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - grafana_dashboard=1 -o yaml \
        | kubectl apply -f - >/dev/null

      ok "${CM_NAME}  <- ${BASE}"
      DASH_COUNT=$(( DASH_COUNT + 1 ))
    done < <(find "${DASHBOARDS_DIR}" -maxdepth 1 -type f -name '*.json' | sort)

    if [[ "${DASH_COUNT}" -eq 0 ]]; then
      warn "no .json files under ${DASHBOARDS_DIR}"
    else
      info "the Grafana sidecar picks these up within ~30 seconds; no restart needed"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# (i) Rollout waits
#
# `helm --wait` already blocks, but it only waits on the resources Helm itself
# owns and it reports a single opaque timeout. An explicit per-workload rollout
# wait pinpoints exactly which component is unhealthy.
# -----------------------------------------------------------------------------
step "Waiting for workloads to become ready"

if [[ "${DO_METRICS}" -eq 1 ]]; then
  wait_rollout deployment  "${KPS_RELEASE}-grafana"
  wait_rollout deployment  "${KPS_RELEASE}-kube-state-metrics"
  wait_rollout deployment  "${KPS_RELEASE}-operator"
  wait_rollout daemonset   "${KPS_RELEASE}-prometheus-node-exporter"
  wait_rollout statefulset "prometheus-${KPS_RELEASE}-prometheus"
  wait_rollout statefulset "alertmanager-${KPS_RELEASE}-alertmanager"
fi
if [[ "${DO_LOGS}" -eq 1 ]]; then
  # The Loki chart in SingleBinary deployment mode produces statefulset/loki.
  wait_rollout statefulset "${LOKI_RELEASE}"
  wait_rollout daemonset   "${PROMTAIL_RELEASE}"
fi
if [[ "${DO_TRACES}" -eq 1 ]]; then
  wait_rollout statefulset "${TEMPO_RELEASE}"
fi

# -----------------------------------------------------------------------------
# (j) Summary
# -----------------------------------------------------------------------------
step "Installed Helm releases in '${MONITORING_NS}'"
helm list --namespace "${MONITORING_NS}" || warn "helm list failed"

printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} OBSERVABILITY STACK INSTALLED${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_WHITE} %-24s %-10s %s${C_RESET}\n" "COMPONENT" "VERSION" "ROLE"
printf "${C_GREY} ------------------------ ---------- ---------------------------------------${C_RESET}\n"
[[ "${DO_METRICS}" -eq 1 ]] && printf " %-24s %-10s %s\n" "${KPS_RELEASE}"      "${KPS_VERSION}"      "metrics, alerting, Grafana"
[[ "${DO_LOGS}"    -eq 1 ]] && printf " %-24s %-10s %s\n" "${LOKI_RELEASE}"     "${LOKI_VERSION}"     "log storage and LogQL"
[[ "${DO_LOGS}"    -eq 1 ]] && printf " %-24s %-10s %s\n" "${PROMTAIL_RELEASE}" "${PROMTAIL_VERSION}" "log shipper (DaemonSet)"
[[ "${DO_TRACES}"  -eq 1 ]] && printf " %-24s %-10s %s\n" "${TEMPO_RELEASE}"    "${TEMPO_VERSION}"    "distributed traces (OTLP)"

printf "\n Grafana login : %s / %s\n" "${GRAFANA_ADMIN_USER}" "${GRAFANA_ADMIN_PASS}"
printf " Secret        : %s (ns %s)\n" "${GRAFANA_SECRET_NAME}" "${MONITORING_NS}"
printf "\n${C_WHITE} NEXT STEPS${C_RESET}\n"
printf "   1. ./scripts/deploy-app.sh        build and deploy orders-api into '%s'\n" "${APP_NS}"
printf "   2. ./scripts/port-forward.sh      open Grafana on http://localhost:3000\n"
printf "   3. ./scripts/trigger-incident.sh  run the SLO burn-rate demo\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

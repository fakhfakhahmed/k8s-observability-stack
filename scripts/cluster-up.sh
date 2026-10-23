#!/usr/bin/env bash
# =============================================================================
# cluster-up.sh - start (or verify) the local minikube cluster
# =============================================================================
#
# PURPOSE
#   Brings up a single-node minikube cluster sized for the full observability
#   stack, enables the addons the stack depends on, and pre-creates the two
#   namespaces used by the project:
#
#       monitoring  -> kube-prometheus-stack, Loki, Promtail, Tempo
#       demo        -> the orders-api demo application
#
#   Idempotent: if the profile is already Running the start is skipped, but the
#   sizing is still verified and the addons and namespaces are re-applied.
#
# USAGE
#   ./scripts/cluster-up.sh
#   ./scripts/cluster-up.sh --cpus 6 --memory 12288
#   ./scripts/cluster-up.sh --memory 6144          # low-RAM fallback
#   ./scripts/cluster-up.sh --driver hyperkit
#   ./scripts/cluster-up.sh --help
#
# PARAMETERS
#   -c, --cpus <int>       vCPUs for the cluster              (default 4)
#   -m, --memory <mb>      MB of RAM for the cluster          (default 8192)
#   -d, --disk-size <size> disk image size, minikube syntax   (default 40g)
#       --driver <name>    minikube driver                    (default docker)
#   -p, --profile <name>   minikube profile name              (default minikube)
#   -h, --help             print usage and exit 0
#
# PREREQUISITES
#   ./scripts/preflight.sh passing. With the default docker driver the Docker
#   daemon must be running.
#
# WHAT IT CHANGES
#   * Creates/starts the named minikube profile.
#   * Enables addons: metrics-server, default-storageclass, storage-provisioner.
#   * Creates namespaces 'monitoring' and 'demo'.
#   * Switches the current kubectl context to the profile.
#
# HOW TO UNDO IT
#   ./scripts/uninstall.sh --delete-cluster     (or: minikube delete -p minikube)
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

# Minimums the stack genuinely needs. Below these Prometheus and Loki will be
# OOMKilled or the kubelet will start evicting pods mid-demo.
MIN_CPUS=4
MIN_MEMORY_MB=8192

# Defaults, all overridable by flags.
CPUS=4
MEMORY=8192
DISK_SIZE="40g"
DRIVER="docker"
PROFILE="minikube"

# metrics-server backs `kubectl top` and the HPA panels on the cluster
# dashboard; storage-provisioner + default-storageclass back the PVCs that
# Prometheus, Alertmanager, Loki and Tempo all request.
ADDONS=("metrics-server" "default-storageclass" "storage-provisioner")

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
cluster-up.sh - start the local minikube cluster for k8s-observability-stack

USAGE
    ./scripts/cluster-up.sh [options]

OPTIONS
    -c, --cpus <int>        vCPUs for the cluster             (default ${CPUS}, minimum ${MIN_CPUS})
    -m, --memory <mb>       MB of RAM for the cluster         (default ${MEMORY}, minimum ${MIN_MEMORY_MB})
    -d, --disk-size <size>  disk image size (minikube syntax) (default ${DISK_SIZE})
        --driver <name>     minikube driver                   (default ${DRIVER})
    -p, --profile <name>    minikube profile name             (default ${PROFILE})
    -h, --help              print this help and exit

EXAMPLES
    ./scripts/cluster-up.sh
    ./scripts/cluster-up.sh --memory 6144
    ./scripts/cluster-up.sh --cpus 6 --memory 12288 --disk-size 60g
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing. Long flags are handled manually so the UX matches the
# PowerShell twin; a missing value for a flag is a hard error.
# -----------------------------------------------------------------------------
require_value() {
  if [[ -z "${2:-}" ]]; then
    err "option $1 requires a value"
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cpus)      require_value "$1" "${2:-}"; CPUS="$2";      shift 2 ;;
    -m|--memory)    require_value "$1" "${2:-}"; MEMORY="$2";    shift 2 ;;
    -d|--disk-size) require_value "$1" "${2:-}"; DISK_SIZE="$2"; shift 2 ;;
    --driver)       require_value "$1" "${2:-}"; DRIVER="$2";    shift 2 ;;
    -p|--profile)   require_value "$1" "${2:-}"; PROFILE="$2";   shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

printf "\n${C_WHITE}k8s-observability-stack - cluster-up${C_RESET}\n"
printf "${C_GREY}repo root: %s${C_RESET}\n" "${REPO_ROOT}"

# -----------------------------------------------------------------------------
# Sanity-check the requested sizing before asking minikube for anything.
# -----------------------------------------------------------------------------
step "Validating requested cluster size"

if [[ "${CPUS}" -lt "${MIN_CPUS}" ]]; then
  warn "requested ${CPUS} CPUs which is below the recommended ${MIN_CPUS}"
  info "Prometheus rule evaluation and the k6 load job will contend for CPU."
fi
if [[ "${MEMORY}" -lt "${MIN_MEMORY_MB}" ]]; then
  warn "requested ${MEMORY} MB which is below the recommended ${MIN_MEMORY_MB} MB"
  info "Expect shorter Loki/Tempo retention and possible OOMKills under load."
fi
info "profile=${PROFILE} cpus=${CPUS} memory=${MEMORY}MB disk=${DISK_SIZE} driver=${DRIVER}"

# -----------------------------------------------------------------------------
# Required tooling
# -----------------------------------------------------------------------------
step "Checking required tools"

for tool in minikube kubectl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "${tool} not found on PATH"
    info "run ./scripts/preflight.sh for installation hints"
    exit 1
  fi
  ok "${tool} found"
done

# With the docker driver minikube is useless without a live daemon, and the
# error minikube emits in that case is long and unhelpful. Catch it early.
if [[ "${DRIVER}" == "docker" ]]; then
  if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    err "the Docker daemon is not responding, but --driver docker was requested"
    info "Start Docker Desktop, wait for the tray icon to settle, then re-run this script."
    info "Alternatively pass a different driver, for example: --driver hyperkit"
    exit 1
  fi
  ok "Docker daemon reachable"
fi

# -----------------------------------------------------------------------------
# Is the profile already up? `minikube status` exits non-zero when the profile
# does not exist or is stopped - exactly the signal we want, so the exit code
# is inspected rather than asserted.
# -----------------------------------------------------------------------------
step "Checking whether profile '${PROFILE}' is already running"

HOST_STATUS="$(minikube -p "${PROFILE}" status --format '{{.Host}}' 2>/dev/null | head -n 1 || true)"

if [[ "${HOST_STATUS}" == "Running" ]]; then
  ok "profile '${PROFILE}' is already Running - skipping 'minikube start'"
  info "delete it first if you need to change cpus/memory: minikube delete -p ${PROFILE}"
else
  if [[ -n "${HOST_STATUS}" ]]; then
    info "profile '${PROFILE}' exists but reports status '${HOST_STATUS}' - starting it"
  else
    info "profile '${PROFILE}' does not exist yet - creating it"
  fi

  step "Starting minikube (this takes 2-5 minutes on a first run)"

  # `set -e` would abort before the friendly diagnostics below, so the failure
  # is captured explicitly.
  START_RC=0
  minikube start \
    --profile="${PROFILE}" \
    --cpus="${CPUS}" \
    --memory="${MEMORY}" \
    --disk-size="${DISK_SIZE}" \
    --driver="${DRIVER}" \
    --addons=metrics-server \
    --wait=all || START_RC=$?

  if [[ "${START_RC}" -ne 0 ]]; then
    err "minikube start failed (exit code ${START_RC})"
    printf "\n${C_YELLOW}    Most common causes and what to do:${C_RESET}\n"
    printf "${C_YELLOW}      1. Not enough RAM assigned to Docker Desktop.${C_RESET}\n"
    printf "${C_YELLOW}         Docker Desktop -> Settings -> Resources -> Memory must exceed %s MB.${C_RESET}\n" "${MEMORY}"
    printf "${C_YELLOW}      2. The host simply does not have %s MB spare. Retry smaller:${C_RESET}\n" "${MEMORY}"
    printf "${C_YELLOW}             ./scripts/cluster-up.sh --memory 6144${C_RESET}\n"
    printf "${C_YELLOW}         What degrades at 6144 MB:${C_RESET}\n"
    printf "${C_YELLOW}           - Prometheus retention must drop (edit stack/prometheus/values.yaml).${C_RESET}\n"
    printf "${C_YELLOW}           - Loki and Tempo may be OOMKilled while the k6 load job runs.${C_RESET}\n"
    printf "${C_YELLOW}           - The 14.4x burn-rate demo still works, but with fewer samples.${C_RESET}\n"
    printf "${C_YELLOW}      3. A stale profile from a previous run. Clean up and retry:${C_RESET}\n"
    printf "${C_YELLOW}             minikube delete -p %s${C_RESET}\n\n" "${PROFILE}"
    exit 1
  fi

  ok "minikube start completed"
fi

# -----------------------------------------------------------------------------
# Verify the effective sizing. When the profile pre-existed, --cpus/--memory
# were ignored by minikube, so report what is actually in place.
# -----------------------------------------------------------------------------
step "Verifying effective cluster resources"

if command -v jq >/dev/null 2>&1; then
  PROFILE_JSON="$(minikube profile list -o json 2>/dev/null || echo "")"
  if [[ -n "${PROFILE_JSON}" ]]; then
    EFF_CPUS="$(printf '%s' "${PROFILE_JSON}" | jq -r --arg n "${PROFILE}" '.valid[]? | select(.Name==$n) | .Config.CPUs'   2>/dev/null || true)"
    EFF_MEM="$(printf '%s' "${PROFILE_JSON}"  | jq -r --arg n "${PROFILE}" '.valid[]? | select(.Name==$n) | .Config.Memory' 2>/dev/null || true)"

    if [[ -n "${EFF_CPUS}" && "${EFF_CPUS}" != "null" ]]; then
      info "effective: cpus=${EFF_CPUS} memory=${EFF_MEM}MB"
      if [[ "${EFF_CPUS}" -lt "${MIN_CPUS}" ]] || [[ "${EFF_MEM}" -lt "${MIN_MEMORY_MB}" ]]; then
        warn "the running cluster is below the recommended ${MIN_CPUS} cpus / ${MIN_MEMORY_MB} MB"
        info "to resize you must recreate: minikube delete -p ${PROFILE} && ./scripts/cluster-up.sh"
      else
        ok "cluster meets the recommended minimum"
      fi
    else
      warn "profile '${PROFILE}' not present in 'minikube profile list' output"
    fi
  else
    warn "could not read 'minikube profile list -o json' - skipping sizing verification"
  fi
else
  info "jq not installed - skipping detailed sizing verification"
  # Fall back to the node's allocatable capacity, which is close enough to spot
  # a badly undersized cluster.
  kubectl get nodes -o jsonpath='{range .items[*]}    node {.metadata.name}: cpu={.status.capacity.cpu} memory={.status.capacity.memory}{"\n"}{end}' 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Addons. `minikube addons enable` is naturally idempotent - enabling an
# already-enabled addon is a no-op that still exits 0.
# -----------------------------------------------------------------------------
step "Enabling required addons"

for addon in "${ADDONS[@]}"; do
  if minikube -p "${PROFILE}" addons enable "${addon}" >/dev/null 2>&1; then
    ok "addon '${addon}' enabled"
  else
    # default-storageclass/storage-provisioner are enabled by default on most
    # drivers; a failure there is noisy but not fatal.
    warn "addon '${addon}' could not be enabled - continuing"
  fi
done

# -----------------------------------------------------------------------------
# kubectl context
# -----------------------------------------------------------------------------
step "Pointing kubectl at the '${PROFILE}' context"

if ! kubectl config use-context "${PROFILE}" >/dev/null 2>&1; then
  err "kubectl config use-context ${PROFILE} failed"
  info "try: minikube -p ${PROFILE} update-context"
  exit 1
fi
ok "current context is now '${PROFILE}'"

# -----------------------------------------------------------------------------
# Namespaces. `kubectl create ns --dry-run=client -o yaml | kubectl apply -f -`
# is the canonical idempotent create: it succeeds whether or not the namespace
# already exists, and never mutates anything that is already correct.
# -----------------------------------------------------------------------------
step "Creating namespaces"

for ns in "${MONITORING_NS}" "${APP_NS}"; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "namespace '${ns}' present"
done

# -----------------------------------------------------------------------------
# Final state
# -----------------------------------------------------------------------------
step "Cluster nodes"
kubectl get nodes -o wide

step "Namespaces"
kubectl get namespace "${MONITORING_NS}" "${APP_NS}"

printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} CLUSTER READY${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf " profile     : %s\n" "${PROFILE}"
printf " driver      : %s\n" "${DRIVER}"
printf " namespaces  : %s, %s\n" "${MONITORING_NS}" "${APP_NS}"
printf " addons      : %s\n" "${ADDONS[*]}"
printf "\n${C_WHITE} NEXT STEPS${C_RESET}\n"
printf "   1. ./scripts/install-stack.sh      install Prometheus, Loki, Promtail, Tempo\n"
printf "   2. ./scripts/deploy-app.sh         build and deploy orders-api\n"
printf "   3. ./scripts/port-forward.sh       open Grafana / Prometheus / Alertmanager\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

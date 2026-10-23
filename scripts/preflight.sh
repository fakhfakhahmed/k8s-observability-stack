#!/usr/bin/env bash
# =============================================================================
# preflight.sh - pre-flight environment check for the k8s-observability-stack
# =============================================================================
#
# PURPOSE
#   Verifies that this machine can actually run the full observability stack
#   (kube-prometheus-stack + Loki + Promtail + Tempo + the orders-api demo app)
#   BEFORE you spend 15 minutes watching Helm time out. It checks:
#
#     1. Required CLI tools on PATH  : kubectl, helm, minikube, docker
#     2. The Docker daemon is RUNNING (Docker Desktop is often stopped)
#     3. Host capacity               : >= 4 logical CPUs, >= 8 GB RAM
#     4. Free disk space             : >= 40 GB
#     5. Existing minikube profile   : reports cpus/memory and whether it suffices
#     6. kubectl reaches a cluster   : informational only, never fatal
#
# USAGE
#   ./scripts/preflight.sh
#   ./scripts/preflight.sh --quiet
#   ./scripts/preflight.sh --help
#
# PARAMETERS
#   -q, --quiet   Suppress per-check narration; print only the summary and failures.
#   -h, --help    Print usage and exit 0.
#
# PREREQUISITES
#   bash 4+ (Git Bash, WSL, Linux or macOS). Run `chmod +x scripts/*.sh` once.
#   Honours NO_COLOR: set NO_COLOR=1 to disable ANSI colour.
#
# WHAT IT CHANGES
#   NOTHING. Strictly read-only: no cluster is started, no chart installed,
#   no file written.
#
# HOW TO UNDO IT
#   Nothing to undo.
#
# EXIT CODES
#   0  all hard requirements satisfied (warnings may still be present)
#   1  at least one hard requirement failed
#   2  bad arguments
#
# Ahmed Fakhfakh - DevOps / SRE
# =============================================================================

set -euo pipefail

# Print the failing line number on any unhandled error.
trap 'rc=$?; printf "\n[FATAL] %s failed at line %s (exit %s)\n" "${BASH_SOURCE[0]}" "${LINENO}" "${rc}" >&2; exit "${rc}"' ERR

# -----------------------------------------------------------------------------
# Repo root is resolved from the script's own location so the script works no
# matter what directory the caller is sitting in.
# -----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# -----------------------------------------------------------------------------
MONITORING_NS="monitoring"
APP_NS="demo"
MINIKUBE_PROFILE="minikube"

MIN_CPUS=4
MIN_MEMORY_MB=8192
MIN_DISK_GB=40

QUIET=0

# -----------------------------------------------------------------------------
# Colour helpers. NO_COLOR (https://no-color.org) disables all escapes, as does
# a non-TTY stdout so piped/CI output stays clean.
# -----------------------------------------------------------------------------
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""
else
  C_RESET="\033[0m"; C_CYAN="\033[36m"; C_GREEN="\033[32m"
  C_YELLOW="\033[33m"; C_RED="\033[31m"; C_GREY="\033[90m"; C_WHITE="\033[97m"
fi

step() { [[ "${QUIET}" -eq 1 ]] && return 0; printf "\n${C_CYAN}==> %s${C_RESET}\n" "$*"; }
ok()   { [[ "${QUIET}" -eq 1 ]] && return 0; printf "${C_GREEN}    [ OK ] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}    [WARN] %s${C_RESET}\n" "$*"; }
err()  { printf "${C_RED}    [FAIL] %s${C_RESET}\n" "$*"; }
info() { [[ "${QUIET}" -eq 1 ]] && return 0; printf "${C_GREY}    %s${C_RESET}\n" "$*"; }

usage() {
  cat <<EOF
preflight.sh - verify this machine can run the k8s-observability-stack demo

USAGE
    ./scripts/preflight.sh [-q|--quiet] [-h|--help]

PARAMETERS
    -q, --quiet   Only print the summary table and failures.
    -h, --help    Print this help and exit.

CHECKS
    kubectl / helm / minikube / docker on PATH
    Docker daemon reachable
    >= ${MIN_CPUS} logical CPUs, >= ${MIN_MEMORY_MB} MB RAM, >= ${MIN_DISK_GB} GB free disk
    Existing minikube profile sizing (if any)
    kubectl cluster reachability (informational)

EXIT CODES
    0 pass   1 hard failure   2 bad arguments
EOF
}

# -----------------------------------------------------------------------------
# Long-flag parsing. getopts alone cannot do --long-flags portably, so we walk
# the argument list ourselves and translate long forms into short ones.
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf "${C_RED}unknown argument: %s${C_RESET}\n" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Results accumulator. Each entry is "Check|STATUS|Detail".
# Only FAIL makes the script exit non-zero.
# -----------------------------------------------------------------------------
RESULTS=()
add_result() { RESULTS+=("$1|$2|$3"); }

# -----------------------------------------------------------------------------
# Tool discovery
# -----------------------------------------------------------------------------
HAVE_KUBECTL=0; HAVE_HELM=0; HAVE_MINIKUBE=0; HAVE_DOCKER=0

check_tool() {
  local name="$1" version_cmd="$2" hint="$3" version=""

  if ! command -v "${name}" >/dev/null 2>&1; then
    err "${name} not found on PATH"
    info "install with: ${hint}"
    add_result "${name} on PATH" "FAIL" "missing - ${hint}"
    return 1
  fi

  # The version probe must never abort the script: some tools exit non-zero
  # when a daemon is unreachable even though the binary itself is fine.
  version="$(eval "${version_cmd}" 2>/dev/null | head -n 1 || true)"
  [[ -z "${version}" ]] && version="(version unavailable)"
  if [[ ${#version} -gt 60 ]]; then version="${version:0:57}..."; fi

  ok "${name} found -> ${version}"
  add_result "${name} on PATH" "PASS" "${version}"
  return 0
}

printf "\n${C_WHITE}k8s-observability-stack - pre-flight check${C_RESET}\n"
printf "${C_GREY}repo root: %s${C_RESET}\n" "${REPO_ROOT}"
printf "${C_GREY}target namespaces: %s, %s${C_RESET}\n" "${MONITORING_NS}" "${APP_NS}"

# -----------------------------------------------------------------------------
# 1. Required CLI tools
# -----------------------------------------------------------------------------
step "Checking required CLI tools"

# `|| true` keeps `set -e` from killing us; the HAVE_* flags carry the result.
if check_tool "kubectl"  "kubectl version --client=true -o yaml" "brew install kubectl | winget install Kubernetes.kubectl"; then HAVE_KUBECTL=1; fi
if check_tool "helm"     "helm version --short"                  "brew install helm | winget install Helm.Helm"; then HAVE_HELM=1; fi
if check_tool "minikube" "minikube version --short"              "brew install minikube | winget install Kubernetes.minikube"; then HAVE_MINIKUBE=1; fi
if check_tool "docker"   "docker --version"                      "install Docker Desktop | winget install Docker.DockerDesktop"; then HAVE_DOCKER=1; fi

# k6 is intentionally NOT required: the load generator runs as a Kubernetes Job
# (load/k8s/k6-job.yaml), so nothing needs to be installed on the host.
info "k6 is not required locally - load tests run as a Kubernetes Job"

# -----------------------------------------------------------------------------
# 2. Docker daemon reachability
# -----------------------------------------------------------------------------
step "Checking the Docker daemon"

if [[ "${HAVE_DOCKER}" -eq 0 ]]; then
  err "skipping daemon check because the docker CLI is missing"
  add_result "Docker daemon running" "FAIL" "docker CLI missing"
else
  # `docker info` is the cheapest round-trip that actually talks to the daemon.
  if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    DOCKER_SERVER="$(docker info --format '{{.ServerVersion}}' 2>/dev/null | head -n 1 || echo unknown)"
    ok "Docker daemon reachable (server ${DOCKER_SERVER})"
    add_result "Docker daemon running" "PASS" "server ${DOCKER_SERVER}"
  else
    err "the Docker daemon is not responding"
    info "Docker Desktop is probably not started. Launch it, wait for the whale icon"
    info "to stop animating, then re-run this script."
    info "minikube --driver=docker cannot start a cluster without a running daemon."
    add_result "Docker daemon running" "FAIL" "start Docker Desktop and retry"
  fi
fi

# -----------------------------------------------------------------------------
# 3. Host CPU and memory. Linux reads nproc + /proc/meminfo; macOS falls back
#    to sysctl, which reports bytes for hw.memsize.
# -----------------------------------------------------------------------------
step "Checking host capacity (need >= ${MIN_CPUS} CPUs and >= ${MIN_MEMORY_MB} MB RAM)"

HOST_CPUS=0
HOST_MEM_MB=0

if command -v nproc >/dev/null 2>&1; then
  HOST_CPUS="$(nproc 2>/dev/null || echo 0)"
elif command -v sysctl >/dev/null 2>&1; then
  HOST_CPUS="$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
fi

if [[ -r /proc/meminfo ]]; then
  # MemTotal is reported in kB.
  HOST_MEM_MB="$(awk '/^MemTotal:/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || echo 0)"
elif command -v sysctl >/dev/null 2>&1; then
  HOST_MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  HOST_MEM_MB=$(( HOST_MEM_BYTES / 1024 / 1024 ))
fi

[[ -z "${HOST_CPUS}" ]] && HOST_CPUS=0
[[ -z "${HOST_MEM_MB}" ]] && HOST_MEM_MB=0

if [[ "${HOST_CPUS}" -le 0 ]]; then
  warn "CPU count could not be determined"
  add_result "Host CPUs" "WARN" "undetermined"
elif [[ "${HOST_CPUS}" -lt "${MIN_CPUS}" ]]; then
  err "only ${HOST_CPUS} logical CPUs detected, need at least ${MIN_CPUS}"
  add_result "Host CPUs" "FAIL" "${HOST_CPUS} (need ${MIN_CPUS})"
else
  ok "${HOST_CPUS} logical CPUs"
  add_result "Host CPUs" "PASS" "${HOST_CPUS}"
fi

if [[ "${HOST_MEM_MB}" -le 0 ]]; then
  warn "RAM size could not be determined"
  add_result "Host RAM" "WARN" "undetermined"
elif [[ "${HOST_MEM_MB}" -lt "${MIN_MEMORY_MB}" ]]; then
  err "only ${HOST_MEM_MB} MB RAM detected, need at least ${MIN_MEMORY_MB} MB"
  info "you can still try: ./scripts/cluster-up.sh --memory 6144 (Loki/Tempo retention will suffer)"
  add_result "Host RAM" "FAIL" "${HOST_MEM_MB} MB (need ${MIN_MEMORY_MB} MB)"
else
  ok "${HOST_MEM_MB} MB RAM"
  add_result "Host RAM" "PASS" "${HOST_MEM_MB} MB"
fi

# -----------------------------------------------------------------------------
# 4. Free disk space on the filesystem holding the repo
# -----------------------------------------------------------------------------
step "Checking free disk space (need >= ${MIN_DISK_GB} GB)"

FREE_GB=-1
if command -v df >/dev/null 2>&1; then
  # -P forces POSIX single-line output; -k gives 1K blocks everywhere.
  FREE_KB="$(df -Pk "${REPO_ROOT}" 2>/dev/null | awk 'NR==2 { print $4 }' || echo "")"
  if [[ -n "${FREE_KB}" ]]; then FREE_GB=$(( FREE_KB / 1024 / 1024 )); fi
fi

if [[ "${FREE_GB}" -lt 0 ]]; then
  warn "free disk space could not be determined"
  add_result "Free disk space" "WARN" "undetermined"
elif [[ "${FREE_GB}" -lt "${MIN_DISK_GB}" ]]; then
  err "${FREE_GB} GB free, need at least ${MIN_DISK_GB} GB"
  info "minikube is started with --disk-size=40g; Prometheus/Loki/Tempo PVCs live inside it."
  add_result "Free disk space" "FAIL" "${FREE_GB} GB (need ${MIN_DISK_GB} GB)"
else
  ok "${FREE_GB} GB free"
  add_result "Free disk space" "PASS" "${FREE_GB} GB"
fi

# -----------------------------------------------------------------------------
# 5. Existing minikube profile sizing
# -----------------------------------------------------------------------------
step "Checking for an existing minikube profile named '${MINIKUBE_PROFILE}'"

if [[ "${HAVE_MINIKUBE}" -eq 0 ]]; then
  warn "minikube CLI missing - cannot inspect existing profiles"
  add_result "minikube profile" "WARN" "minikube CLI missing"
else
  PROFILE_JSON="$(minikube profile list -o json 2>/dev/null || echo "")"
  if [[ -z "${PROFILE_JSON}" ]]; then
    info "no minikube profile exists yet - run ./scripts/cluster-up.sh to create one"
    add_result "minikube profile" "WARN" "not created yet"
  else
    # Prefer jq when available; otherwise fall back to a tolerant grep/sed parse.
    P_CPUS=""; P_MEM=""; P_STATUS=""
    if command -v jq >/dev/null 2>&1; then
      P_CPUS="$(printf '%s' "${PROFILE_JSON}"   | jq -r --arg n "${MINIKUBE_PROFILE}" '.valid[]? | select(.Name==$n) | .Config.CPUs'   2>/dev/null || true)"
      P_MEM="$(printf '%s' "${PROFILE_JSON}"    | jq -r --arg n "${MINIKUBE_PROFILE}" '.valid[]? | select(.Name==$n) | .Config.Memory' 2>/dev/null || true)"
      P_STATUS="$(printf '%s' "${PROFILE_JSON}" | jq -r --arg n "${MINIKUBE_PROFILE}" '.valid[]? | select(.Name==$n) | .Status'        2>/dev/null || true)"
    else
      info "jq not installed - falling back to 'minikube status' only"
      P_STATUS="$(minikube -p "${MINIKUBE_PROFILE}" status --format '{{.Host}}' 2>/dev/null || true)"
    fi

    if [[ -z "${P_STATUS}" || "${P_STATUS}" == "null" ]]; then
      info "profile '${MINIKUBE_PROFILE}' not found"
      add_result "minikube profile" "WARN" "not created yet"
    elif [[ -z "${P_CPUS}" || "${P_CPUS}" == "null" ]]; then
      info "profile '${MINIKUBE_PROFILE}' exists (status ${P_STATUS}); install jq to report its sizing"
      add_result "minikube profile" "WARN" "exists, sizing unknown (${P_STATUS})"
    else
      info "profile '${MINIKUBE_PROFILE}' status=${P_STATUS} cpus=${P_CPUS} memory=${P_MEM}MB"
      if [[ "${P_CPUS}" -lt "${MIN_CPUS}" ]] || [[ "${P_MEM}" -lt "${MIN_MEMORY_MB}" ]]; then
        warn "existing profile is undersized (need ${MIN_CPUS} cpus / ${MIN_MEMORY_MB} MB)"
        info "recreate it with: minikube delete && ./scripts/cluster-up.sh"
        add_result "minikube profile" "WARN" "undersized: ${P_CPUS}cpu/${P_MEM}MB"
      else
        ok "existing profile meets the minimum (${P_CPUS} cpus / ${P_MEM} MB, status ${P_STATUS})"
        add_result "minikube profile" "PASS" "${P_CPUS}cpu/${P_MEM}MB ${P_STATUS}"
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 6. kubectl cluster reachability - informational only. A missing cluster is
#    expected before cluster-up has run, so this can never produce a FAIL.
# -----------------------------------------------------------------------------
step "Checking kubectl connectivity (informational)"

if [[ "${HAVE_KUBECTL}" -eq 0 ]]; then
  add_result "kubectl reaches cluster" "WARN" "kubectl missing"
elif kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
  ok "kubectl reaches a cluster (context: ${CTX})"
  add_result "kubectl reaches cluster" "PASS" "context ${CTX}"
else
  info "kubectl cannot reach a cluster yet - that is normal before cluster-up"
  add_result "kubectl reaches cluster" "WARN" "no cluster yet"
fi

# -----------------------------------------------------------------------------
# Summary table
# -----------------------------------------------------------------------------
printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_WHITE} PRE-FLIGHT SUMMARY${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_WHITE} %-26s %-6s %s${C_RESET}\n" "CHECK" "STATUS" "DETAIL"
printf "${C_GREY} -------------------------- ------ ---------------------------------------${C_RESET}\n"

FAIL_COUNT=0
WARN_COUNT=0

for row in "${RESULTS[@]}"; do
  CHECK="${row%%|*}"
  REST="${row#*|}"
  STATUS="${REST%%|*}"
  DETAIL="${REST#*|}"

  case "${STATUS}" in
    PASS) COLOUR="${C_GREEN}" ;;
    WARN) COLOUR="${C_YELLOW}"; WARN_COUNT=$(( WARN_COUNT + 1 )) ;;
    FAIL) COLOUR="${C_RED}";    FAIL_COUNT=$(( FAIL_COUNT + 1 )) ;;
    *)    COLOUR="${C_RESET}" ;;
  esac

  printf "${COLOUR} %-26s %-6s %s${C_RESET}\n" "${CHECK}" "${STATUS}" "${DETAIL}"
done

printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  printf "${C_RED} RESULT: FAIL (%s hard failure(s), %s warning(s))${C_RESET}\n" "${FAIL_COUNT}" "${WARN_COUNT}"
  printf "${C_RED} Fix the FAIL rows above, then re-run: ./scripts/preflight.sh${C_RESET}\n\n"
  exit 1
fi

printf "${C_GREEN} RESULT: PASS (%s warning(s))${C_RESET}\n" "${WARN_COUNT}"
printf "${C_GREEN} Next step: ./scripts/cluster-up.sh${C_RESET}\n\n"
exit 0

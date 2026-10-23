#!/usr/bin/env bash
# =============================================================================
# deploy-app.sh - build and deploy orders-api into the 'demo' namespace
# =============================================================================
#
# PURPOSE
#   1. Points the current shell at minikube's internal Docker daemon so the
#      image is built INSIDE the cluster VM. That is what makes
#      'imagePullPolicy: IfNotPresent' work without a registry: there is no
#      push step and no registry credentials anywhere in this project.
#   2. Builds orders-api:0.1.0 from app/.
#   3. Applies app/k8s/namespace.yaml, service.yaml, deployment.yaml and
#      servicemonitor.yaml.
#   4. Waits for the Deployment rollout.
#   5. Verifies that /metrics is actually scrapeable and exposes
#      http_requests_total - because a ServiceMonitor pointing at a broken
#      endpoint fails silently and every dashboard stays empty.
#
# USAGE
#   ./scripts/deploy-app.sh
#   ./scripts/deploy-app.sh --skip-build
#   ./scripts/deploy-app.sh --tag 0.2.0
#
# PARAMETERS
#   -s, --skip-build        do not rebuild the image; deploy the manifests only
#   -t, --tag <string>      image tag to build and deploy (default 0.1.0)
#       --timeout <min>     rollout timeout in minutes (default 5)
#   -h, --help              print usage and exit 0
#
# PREREQUISITES
#   * A running cluster (./scripts/cluster-up.sh)
#   * Docker daemon running (the build goes through minikube's daemon)
#   * ./scripts/install-stack.sh already run, otherwise the ServiceMonitor CRD
#     does not exist yet
#
# WHAT IT CHANGES
#   * Builds orders-api:<tag> inside the minikube Docker daemon.
#   * Creates namespace 'demo', Service/Deployment/ServiceMonitor 'orders-api'.
#
# HOW TO UNDO IT
#   kubectl delete namespace demo      (or: ./scripts/uninstall.sh)
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

APP_NAME="orders-api"
IMAGE_NAME="orders-api"
MINIKUBE_PROFILE="minikube"
APP_PORT=8080

APP_DIR="${REPO_ROOT}/app"
MANIFEST_DIR="${REPO_ROOT}/app/k8s"

# Applied in this order on purpose: the namespace must exist before anything
# lands in it, and the Service must exist before the ServiceMonitor selects it.
MANIFESTS=("namespace.yaml" "service.yaml" "deployment.yaml" "servicemonitor.yaml")

SKIP_BUILD=0
TAG="0.1.0"
TIMEOUT_MINUTES=5

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
deploy-app.sh - build and deploy ${APP_NAME} into namespace '${APP_NS}'

USAGE
    ./scripts/deploy-app.sh [-s|--skip-build] [-t|--tag <string>]
                            [--timeout <min>] [-h|--help]

OPTIONS
    -s, --skip-build     deploy manifests only, do not rebuild the image
    -t, --tag <string>   image tag (default ${TAG}) -> ${IMAGE_NAME}:<tag>
        --timeout <min>  rollout timeout in minutes (default ${TIMEOUT_MINUTES})
    -h, --help           print this help and exit

EXAMPLES
    ./scripts/deploy-app.sh
    ./scripts/deploy-app.sh --skip-build
    ./scripts/deploy-app.sh --tag 0.2.0
EOF
}

require_value() {
  if [[ -z "${2:-}" ]]; then err "option $1 requires a value"; exit 2; fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--skip-build) SKIP_BUILD=1; shift ;;
    -t|--tag)        require_value "$1" "${2:-}"; TAG="$2"; shift 2 ;;
    --timeout)       require_value "$1" "${2:-}"; TIMEOUT_MINUTES="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

IMAGE="${IMAGE_NAME}:${TAG}"

printf "\n${C_WHITE}k8s-observability-stack - deploy-app${C_RESET}\n"
printf "${C_GREY}repo root : %s${C_RESET}\n" "${REPO_ROOT}"
printf "${C_GREY}image     : %s${C_RESET}\n" "${IMAGE}"
printf "${C_GREY}namespace : %s${C_RESET}\n" "${APP_NS}"

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
step "Checking prerequisites"

for tool in kubectl minikube; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "${tool} not found on PATH - run ./scripts/preflight.sh"
    exit 1
  fi
  ok "${tool} found"
done

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    err "docker not found on PATH, and --skip-build was not passed"
    exit 1
  fi
  ok "docker found"
fi

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster - run ./scripts/cluster-up.sh first"
  exit 1
fi
ok "cluster reachable"

for m in "${MANIFESTS[@]}"; do
  if [[ ! -f "${MANIFEST_DIR}/${m}" ]]; then
    err "manifest not found: ${MANIFEST_DIR}/${m}"
    exit 1
  fi
done
ok "all four manifests present in app/k8s/"

# The ServiceMonitor CRD is installed by kube-prometheus-stack. Without it the
# apply below dies with a confusing "no matches for kind" error, so the
# situation is detected up front and explained.
HAVE_SM_CRD=0
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  HAVE_SM_CRD=1
  ok "ServiceMonitor CRD present"
else
  warn "the ServiceMonitor CRD is not installed"
  info "run ./scripts/install-stack.sh first, otherwise Prometheus will never scrape ${APP_NAME}"
  info "the servicemonitor.yaml manifest will be skipped for now"
fi

# -----------------------------------------------------------------------------
# Build the image inside minikube's Docker daemon
#
# `minikube docker-env` prints shell exports. `eval` applies them to THIS shell
# process only, so the caller's terminal is not permanently redirected.
# Everything after this - including `docker build` - talks to the daemon inside
# the minikube VM, which is exactly where the kubelet looks for images when
# imagePullPolicy is IfNotPresent.
# -----------------------------------------------------------------------------
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  step "Skipping image build (--skip-build)"
  info "the cluster must already have ${IMAGE} or the pod will stay in ImagePullBackOff"
else
  step "Pointing this shell at minikube's Docker daemon"

  if ! eval "$(minikube -p "${MINIKUBE_PROFILE}" docker-env)"; then
    err "minikube -p ${MINIKUBE_PROFILE} docker-env failed"
    info "is the cluster running? try: minikube -p ${MINIKUBE_PROFILE} status"
    exit 1
  fi
  ok "DOCKER_HOST now points at ${DOCKER_HOST:-(unset)}"

  step "Building ${IMAGE} from app/"

  if [[ ! -f "${APP_DIR}/Dockerfile" ]]; then
    err "no Dockerfile found at ${APP_DIR}/Dockerfile"
    exit 1
  fi

  if ! docker build --tag "${IMAGE}" --file "${APP_DIR}/Dockerfile" "${APP_DIR}"; then
    err "docker build ${IMAGE} failed"
    info "check the Go build output above; the module is github.com/fakhfakhahmed/k8s-observability-stack/app"
    exit 1
  fi
  ok "built ${IMAGE}"

  # Confirm the image really landed in the cluster's daemon and not on the host.
  FOUND="$(docker images --filter "reference=${IMAGE}" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | head -n 1 || true)"
  if [[ -n "${FOUND}" ]]; then
    ok "image visible to the cluster daemon: ${FOUND}"
  else
    warn "could not confirm the image inside minikube's daemon"
  fi
fi

# -----------------------------------------------------------------------------
# Apply manifests. `kubectl apply` is idempotent by definition.
# -----------------------------------------------------------------------------
step "Applying Kubernetes manifests"

for m in "${MANIFESTS[@]}"; do
  if [[ "${m}" == "servicemonitor.yaml" && "${HAVE_SM_CRD}" -eq 0 ]]; then
    warn "skipping servicemonitor.yaml (CRD missing)"
    continue
  fi
  kubectl apply -f "${MANIFEST_DIR}/${m}" >/dev/null
  ok "applied ${m}"
done

# When only the tag changed, the Deployment manifest still names 0.1.0, so the
# running image is corrected explicitly. `kubectl set image` is a no-op when the
# image already matches.
if [[ "${TAG}" != "0.1.0" ]]; then
  info "non-default tag requested - pinning the Deployment to ${IMAGE}"
  kubectl -n "${APP_NS}" set image "deployment/${APP_NAME}" "${APP_NAME}=${IMAGE}" >/dev/null
fi

# -----------------------------------------------------------------------------
# Rollout
# -----------------------------------------------------------------------------
step "Waiting for the ${APP_NAME} rollout"

ROLLOUT_SECONDS=$(( TIMEOUT_MINUTES * 60 ))
if ! kubectl -n "${APP_NS}" rollout status "deployment/${APP_NAME}" --timeout="${ROLLOUT_SECONDS}s"; then
  err "${APP_NAME} did not become ready within ${ROLLOUT_SECONDS}s"
  printf "\n"
  info "pod state:"
  kubectl -n "${APP_NS}" get pods -l "app.kubernetes.io/name=${APP_NAME}" -o wide || true
  printf "\n"
  info "most common cause: the image is not in minikube's daemon."
  info "re-run WITHOUT --skip-build, or inspect:"
  info "    kubectl -n ${APP_NS} describe pod -l app.kubernetes.io/name=${APP_NAME}"
  exit 1
fi
ok "deployment/${APP_NAME} is ready"

# -----------------------------------------------------------------------------
# Verify the metrics endpoint
#
# This is the single most valuable check in the script. A ServiceMonitor
# pointing at an endpoint that does not serve Prometheus text format produces
# no error anywhere - Prometheus simply reports the target as down and every
# panel renders "No data". Checking here turns a silent failure into a loud one.
#
# The probe runs INSIDE the app pod via kubectl exec, so it needs no
# port-forward and no extra image pull.
# -----------------------------------------------------------------------------
step "Verifying the /metrics endpoint exposes http_requests_total"

POD_NAME="$(kubectl -n "${APP_NS}" get pods -l "app.kubernetes.io/name=${APP_NAME}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "${POD_NAME}" ]]; then
  err "could not find a Running ${APP_NAME} pod"
  exit 1
fi
info "probing pod ${POD_NAME}"

# Prefer curl, fall back to busybox wget: slim Go base images ship one or the
# other but rarely both.
METRICS_BODY="$(kubectl -n "${APP_NS}" exec "${POD_NAME}" -- sh -c \
  "curl -sS --max-time 10 http://127.0.0.1:${APP_PORT}/metrics 2>/dev/null || wget -q -O - --timeout=10 http://127.0.0.1:${APP_PORT}/metrics 2>/dev/null" 2>/dev/null || true)"

if [[ -z "${METRICS_BODY}" ]]; then
  # Fall back to a throwaway curl pod on the cluster network. This also proves
  # the Service - not just the pod - is routable.
  warn "in-pod probe failed (neither curl nor wget available?) - retrying from a throwaway pod"
  PROBE_NAME="metrics-probe-$(date +%s)"
  METRICS_BODY="$(kubectl -n "${APP_NS}" run "${PROBE_NAME}" \
    --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 \
    --command -- curl -sS --max-time 10 \
    "http://${APP_NAME}.${APP_NS}.svc.cluster.local:${APP_PORT}/metrics" 2>/dev/null || true)"
fi

if [[ -z "${METRICS_BODY}" ]]; then
  err "could not read /metrics from ${APP_NAME}"
  info "try manually: kubectl -n ${APP_NS} port-forward svc/${APP_NAME} ${APP_PORT}:${APP_PORT}"
  info "then open:    http://localhost:${APP_PORT}/metrics"
  exit 1
fi

if printf '%s' "${METRICS_BODY}" | grep -q 'http_requests_total'; then
  ok "/metrics serves http_requests_total - Prometheus will be able to scrape it"

  # Report the other contract metrics too, so a missing one is obvious.
  for metric in http_request_duration_seconds_bucket http_requests_in_flight \
                orders_processed_total queue_depth app_build_info; do
    if printf '%s' "${METRICS_BODY}" | grep -q "${metric}"; then
      info "found ${metric}"
    else
      warn "expected metric not found: ${metric}"
    fi
  done
else
  err "/metrics responded but does not contain http_requests_total"
  info "the ServiceMonitor will scrape an endpoint with no useful series and every dashboard will be empty"
  exit 1
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
step "Deployed objects"
kubectl -n "${APP_NS}" get deployment,service,pods -l "app.kubernetes.io/name=${APP_NAME}" || true

if [[ "${HAVE_SM_CRD}" -eq 1 ]] && kubectl -n "${APP_NS}" get servicemonitor "${APP_NAME}" >/dev/null 2>&1; then
  ok "ServiceMonitor '${APP_NAME}' present - Prometheus job label will be '${APP_NAME}'"
  info "verify the target in ~60s at http://localhost:9090/targets (after port-forward)"
fi

printf "\n${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf "${C_GREEN} ORDERS-API DEPLOYED${C_RESET}\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n"
printf " image      : %s (imagePullPolicy IfNotPresent, built in minikube)\n" "${IMAGE}"
printf " namespace  : %s\n" "${APP_NS}"
printf " service    : %s.%s.svc.cluster.local:%s\n" "${APP_NAME}" "${APP_NS}" "${APP_PORT}"
printf " metrics    : same port, path /metrics\n"
printf " traces     : OTLP gRPC -> tempo.%s.svc.cluster.local:4317\n" "${MONITORING_NS}"
printf "\n${C_WHITE} NEXT STEPS${C_RESET}\n"
printf "   1. ./scripts/port-forward.sh --include-app\n"
printf "      Grafana      http://localhost:3000  (admin / observability)\n"
printf "      orders-api   http://localhost:8080/api/orders\n"
printf "   2. ./scripts/trigger-incident.sh   run the SLO burn-rate demo\n"
printf "${C_WHITE}---------------------------------------------------------------------------${C_RESET}\n\n"
exit 0

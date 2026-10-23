<#
.SYNOPSIS
    Build and deploy the orders-api demo application into the 'demo' namespace.

.DESCRIPTION
    Purpose
    -------
    1. Points the current shell at minikube's internal Docker daemon so the
       image is built INSIDE the cluster VM. That is what makes
       'imagePullPolicy: IfNotPresent' work without a registry: there is no
       push step and no registry credentials anywhere in this project.
    2. Builds orders-api:0.1.0 from app/.
    3. Applies app/k8s/namespace.yaml, service.yaml, deployment.yaml and
       servicemonitor.yaml.
    4. Waits for the Deployment rollout.
    5. Verifies that /metrics is actually scrapeable and exposes
       http_requests_total - because a ServiceMonitor that points at a broken
       endpoint fails silently and every dashboard stays empty.

    Usage
    -----
        .\scripts\deploy-app.ps1
        .\scripts\deploy-app.ps1 -SkipBuild
        .\scripts\deploy-app.ps1 -Tag 0.2.0
        .\scripts\deploy-app.ps1 -Help

    Parameters
    ----------
        -SkipBuild        do not rebuild the image; deploy the manifests only.
                          Use this when you only edited YAML.
        -Tag <string>     image tag to build and deploy (default 0.1.0).
                          The image name is always 'orders-api'.
        -TimeoutMinutes   rollout timeout in minutes (default 5)
        -Help             print usage and exit 0

    Prerequisites
    -------------
        * A running cluster (.\scripts\cluster-up.ps1)
        * Docker Desktop running (the build happens through minikube's daemon)
        * .\scripts\install-stack.ps1 already run, otherwise the ServiceMonitor
          CRD does not exist yet and step 3 fails with
          'no matches for kind ServiceMonitor'

    What it changes
    ---------------
        * Builds the image orders-api:<Tag> inside the minikube Docker daemon.
        * Creates namespace 'demo', Service 'orders-api', Deployment
          'orders-api' and ServiceMonitor 'orders-api'.

    How to undo it
    --------------
        kubectl delete namespace demo
        or: .\scripts\uninstall.ps1

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$Tag = '0.1.0',
    [int]$TimeoutMinutes = 5,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# ---------------------------------------------------------------------------
$MonitoringNs = 'monitoring'
$AppNs        = 'demo'

$AppName         = 'orders-api'
$ImageName       = 'orders-api'
$MinikubeProfile = 'minikube'
$AppPort         = 8080

$AppDir      = Join-Path $RepoRoot 'app'
$ManifestDir = Join-Path $RepoRoot 'app\k8s'

# Applied in this order on purpose: the namespace must exist before anything
# lands in it, and the Service must exist before the ServiceMonitor selects it.
$Manifests = @(
    'namespace.yaml',
    'service.yaml',
    'deployment.yaml',
    'servicemonitor.yaml'
)

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
deploy-app.ps1 - build and deploy $AppName into namespace '$AppNs'

USAGE
    .\scripts\deploy-app.ps1 [-SkipBuild] [-Tag <string>]
                             [-TimeoutMinutes <int>] [-Help]

PARAMETERS
    -SkipBuild        deploy manifests only, do not rebuild the image
    -Tag              image tag (default 0.1.0) -> ${ImageName}:<Tag>
    -TimeoutMinutes   rollout timeout in minutes (default 5)
    -Help             print this help and exit

EXAMPLES
    .\scripts\deploy-app.ps1
    .\scripts\deploy-app.ps1 -SkipBuild
    .\scripts\deploy-app.ps1 -Tag 0.2.0
"@
}

if ($Help) { Show-Usage; exit 0 }

function Assert-ExitCode {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [string]$Hint = ''
    )
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$What failed (exit code $LASTEXITCODE)"
        if ($Hint) { Write-Info $Hint }
        exit 1
    }
}

$Image = "${ImageName}:${Tag}"

Write-Host ""
Write-Host "k8s-observability-stack - deploy-app" -ForegroundColor White
Write-Host "repo root : $RepoRoot" -ForegroundColor DarkGray
Write-Host "image     : $Image" -ForegroundColor DarkGray
Write-Host "namespace : $AppNs" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

foreach ($tool in @('kubectl', 'minikube')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Err "$tool not found on PATH - run .\scripts\preflight.ps1"
        exit 1
    }
    Write-Ok "$tool found"
}

if (-not $SkipBuild) {
    if ($null -eq (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
        Write-Err "docker not found on PATH, and -SkipBuild was not passed"
        exit 1
    }
    Write-Ok "docker found"
}

$null = & kubectl cluster-info --request-timeout=10s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "kubectl cannot reach a cluster - run .\scripts\cluster-up.ps1 first"
    exit 1
}
Write-Ok "cluster reachable"

foreach ($m in $Manifests) {
    $p = Join-Path $ManifestDir $m
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Err "manifest not found: $p"
        exit 1
    }
}
Write-Ok "all four manifests present in app/k8s/"

# The ServiceMonitor CRD is installed by kube-prometheus-stack. Without it the
# apply in step 3 dies with a confusing "no matches for kind" error, so the
# situation is detected up front and explained.
$null = & kubectl get crd servicemonitors.monitoring.coreos.com 2>&1
$haveServiceMonitorCrd = ($LASTEXITCODE -eq 0)
if (-not $haveServiceMonitorCrd) {
    Write-Warn "the ServiceMonitor CRD is not installed"
    Write-Info "run .\scripts\install-stack.ps1 first, otherwise Prometheus will never scrape $AppName"
    Write-Info "the servicemonitor.yaml manifest will be skipped for now"
}
else {
    Write-Ok "ServiceMonitor CRD present"
}

# ---------------------------------------------------------------------------
# Build the image inside minikube's Docker daemon
#
# `minikube docker-env` prints a set of $env: assignments. Invoke-Expression
# applies them to THIS PowerShell process only, so the caller's shell is not
# permanently redirected. Everything after this point - including `docker
# build` - talks to the daemon inside the minikube VM, which is exactly where
# the kubelet looks for images when imagePullPolicy is IfNotPresent.
# ---------------------------------------------------------------------------
if ($SkipBuild) {
    Write-Step "Skipping image build (-SkipBuild)"
    Write-Info "the cluster must already have $Image or the pod will stay in ErrImageNeverPull/ImagePullBackOff"
}
else {
    Write-Step "Pointing this shell at minikube's Docker daemon"

    $dockerEnv = & minikube -p $MinikubeProfile docker-env --shell powershell
    Assert-ExitCode -What "minikube -p $MinikubeProfile docker-env" `
        -Hint "is the cluster running? try: minikube -p $MinikubeProfile status"

    # The last line of docker-env output is a REM/# comment telling the user how
    # to invoke it; evaluating the whole block is harmless and standard practice.
    $dockerEnv | Invoke-Expression
    Write-Ok "DOCKER_HOST now points at $($env:DOCKER_HOST)"

    Write-Step "Building $Image from app/"

    if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'Dockerfile'))) {
        Write-Err "no Dockerfile found at $AppDir\Dockerfile"
        exit 1
    }

    & docker build --tag $Image --file (Join-Path $AppDir 'Dockerfile') $AppDir
    Assert-ExitCode -What "docker build $Image" `
        -Hint "check the Go build output above; the module is github.com/fakhfakhahmed/k8s-observability-stack/app"

    Write-Ok "built $Image"

    # Confirm the image really landed in the cluster's daemon and not on the host.
    $found = & docker images --filter "reference=$Image" --format '{{.Repository}}:{{.Tag}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $found) {
        Write-Ok "image visible to the cluster daemon: $($found | Select-Object -First 1)"
    }
    else {
        Write-Warn "could not confirm the image inside minikube's daemon"
    }
}

# ---------------------------------------------------------------------------
# Apply manifests. `kubectl apply` is idempotent by definition.
# ---------------------------------------------------------------------------
Write-Step "Applying Kubernetes manifests"

foreach ($m in $Manifests) {
    if ($m -eq 'servicemonitor.yaml' -and -not $haveServiceMonitorCrd) {
        Write-Warn "skipping servicemonitor.yaml (CRD missing)"
        continue
    }

    $p = Join-Path $ManifestDir $m
    & kubectl apply -f $p | Out-Null
    Assert-ExitCode -What "kubectl apply -f app/k8s/$m"
    Write-Ok "applied $m"
}

# When only the tag changed, the Deployment manifest still names 0.1.0, so the
# running image is corrected explicitly. `kubectl set image` is a no-op when
# the image already matches.
if ($Tag -ne '0.1.0') {
    Write-Info "non-default tag requested - pinning the Deployment to $Image"
    & kubectl -n $AppNs set image "deployment/$AppName" "$AppName=$Image" | Out-Null
    Assert-ExitCode -What "kubectl set image deployment/$AppName"
}

# ---------------------------------------------------------------------------
# Rollout
# ---------------------------------------------------------------------------
Write-Step "Waiting for the $AppName rollout"

$rolloutSeconds = $TimeoutMinutes * 60
& kubectl -n $AppNs rollout status "deployment/$AppName" --timeout="${rolloutSeconds}s"
if ($LASTEXITCODE -ne 0) {
    Write-Err "$AppName did not become ready within ${rolloutSeconds}s"
    Write-Host ""
    Write-Info "pod state:"
    & kubectl -n $AppNs get pods -l "app.kubernetes.io/name=$AppName" -o wide
    Write-Host ""
    Write-Info "most common cause: the image is not in minikube's daemon."
    Write-Info "re-run WITHOUT -SkipBuild, or inspect: kubectl -n $AppNs describe pod -l app.kubernetes.io/name=$AppName"
    exit 1
}
Write-Ok "deployment/$AppName is ready"

# ---------------------------------------------------------------------------
# Verify the metrics endpoint
#
# This is the single most valuable check in the script. A ServiceMonitor
# pointing at an endpoint that does not serve Prometheus text format produces
# no error anywhere - Prometheus simply reports the target as down and every
# panel renders "No data". Checking here turns a silent failure into a loud one.
#
# The curl runs INSIDE the app pod via kubectl exec, so it needs no
# port-forward and no extra image pull.
# ---------------------------------------------------------------------------
Write-Step "Verifying the /metrics endpoint exposes http_requests_total"

$podName = & kubectl -n $AppNs get pods -l "app.kubernetes.io/name=$AppName" `
    --field-selector=status.phase=Running `
    -o jsonpath='{.items[0].metadata.name}' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $podName) {
    Write-Err "could not find a Running $AppName pod"
    exit 1
}
Write-Info "probing pod $podName"

# Prefer wget: the distroless/alpine base images used for Go services usually
# ship busybox wget but not curl. Try curl first, fall back to wget.
$metricsBody = $null
$metricsBody = & kubectl -n $AppNs exec $podName -- sh -c "curl -sS --max-time 10 http://127.0.0.1:$AppPort/metrics 2>/dev/null || wget -q -O - --timeout=10 http://127.0.0.1:$AppPort/metrics 2>/dev/null" 2>$null
$execExit = $LASTEXITCODE

if ($execExit -ne 0 -or -not $metricsBody) {
    # Fall back to a throwaway curl pod on the cluster network. This also
    # proves the Service - not just the pod - is routable.
    Write-Warn "in-pod probe failed (neither curl nor wget available?) - retrying from a throwaway pod"

    $metricsBody = & kubectl -n $AppNs run "metrics-probe-$([System.Guid]::NewGuid().ToString('N').Substring(0,6))" `
        --rm -i --restart=Never --quiet `
        --image=curlimages/curl:8.10.1 `
        --command -- curl -sS --max-time 10 "http://$AppName.$AppNs.svc.cluster.local:$AppPort/metrics" 2>$null
    $execExit = $LASTEXITCODE
}

if ($execExit -ne 0 -or -not $metricsBody) {
    Write-Err "could not read /metrics from $AppName"
    Write-Info "try manually: kubectl -n $AppNs port-forward svc/$AppName ${AppPort}:${AppPort}"
    Write-Info "then open:    http://localhost:$AppPort/metrics"
    exit 1
}

$metricsText = ($metricsBody | Out-String)
if ($metricsText -match 'http_requests_total') {
    Write-Ok "/metrics serves http_requests_total - Prometheus will be able to scrape it"

    # Report the other contract metrics too, so a missing one is obvious.
    foreach ($metric in @('http_request_duration_seconds_bucket', 'http_requests_in_flight', 'orders_processed_total', 'queue_depth', 'app_build_info')) {
        if ($metricsText -match [regex]::Escape($metric)) {
            Write-Info "found $metric"
        }
        else {
            Write-Warn "expected metric not found: $metric"
        }
    }
}
else {
    Write-Err "/metrics responded but does not contain http_requests_total"
    Write-Info "the ServiceMonitor will scrape an endpoint with no useful series and every dashboard will be empty"
    exit 1
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Step "Deployed objects"
& kubectl -n $AppNs get deployment,service,pods -l "app.kubernetes.io/name=$AppName"
if ($LASTEXITCODE -ne 0) { Write-Warn "kubectl get returned $LASTEXITCODE" }

if ($haveServiceMonitorCrd) {
    & kubectl -n $AppNs get servicemonitor $AppName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "ServiceMonitor '$AppName' present - Prometheus job label will be '$AppName'"
        Write-Info "verify the target in ~60s at http://localhost:9090/targets (after port-forward)"
    }
}

Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " ORDERS-API DEPLOYED" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " image      : $Image (imagePullPolicy IfNotPresent, built in minikube)" -ForegroundColor Gray
Write-Host " namespace  : $AppNs" -ForegroundColor Gray
Write-Host " service    : $AppName.$AppNs.svc.cluster.local:$AppPort" -ForegroundColor Gray
Write-Host " metrics    : same port, path /metrics" -ForegroundColor Gray
Write-Host " traces     : OTLP gRPC -> tempo.$MonitoringNs.svc.cluster.local:4317" -ForegroundColor Gray
Write-Host ""
Write-Host " NEXT STEPS" -ForegroundColor White
Write-Host "   1. .\scripts\port-forward.ps1 -IncludeApp" -ForegroundColor Gray
Write-Host "      Grafana      http://localhost:3000  (admin / observability)" -ForegroundColor Gray
Write-Host "      orders-api   http://localhost:8080/api/orders" -ForegroundColor Gray
Write-Host "   2. .\scripts\trigger-incident.ps1   run the SLO burn-rate demo" -ForegroundColor Gray
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

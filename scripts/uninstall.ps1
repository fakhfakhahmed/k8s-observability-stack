<#
.SYNOPSIS
    Tear down everything this repo installed.

.DESCRIPTION
    Purpose
    -------
    The reverse of install-stack.ps1 + deploy-app.ps1, in reverse dependency
    order:
        1. Stop any local port-forwards (port-forward.ps1 -Stop)
        2. Delete the k6 Job/ConfigMap, if present
        3. Delete the orders-api app (namespace 'demo' - Deployment, Service,
           ServiceMonitor, PDB all go with it)
        4. helm uninstall tempo, promtail, loki, kube-prometheus-stack
        5. Delete the 'monitoring' and 'demo' namespaces
        6. (-DeleteCrds only) delete the Prometheus Operator CRDs, which are
           cluster-scoped and NOT removed by helm uninstall or namespace
           deletion - they would otherwise survive and silently affect the
           next install

    Deleting the NAMESPACE rather than enumerating every object inside it is
    deliberate: Helm's own uninstall removes what it tracks, but PVCs,
    dynamically-provisioned PVs and any ConfigMap this project's scripts
    created by hand (grafana-datasources, grafana-dashboard-*, k6-scripts) are
    NOT Helm-owned and would otherwise be orphaned.

    Usage
    -----
        .\scripts\uninstall.ps1
        .\scripts\uninstall.ps1 -DeleteCrds
        .\scripts\uninstall.ps1 -KeepNamespaces
        .\scripts\uninstall.ps1 -Yes

    Parameters
    ----------
        -DeleteCrds       also remove the Prometheus Operator CRDs
                          (cluster-wide effect)
        -KeepNamespaces   uninstall the Helm releases and the app but leave
                          the 'monitoring' and 'demo' namespaces in place
        -Yes              skip the confirmation prompt
        -Help             print usage and exit 0

    What it changes
    ---------------
        Removes every Helm release, Kubernetes object and (with -DeleteCrds)
        CRD this project created. Does NOT touch minikube itself - run
        'minikube delete' separately for a full teardown.

    How to undo it
    --------------
        .\scripts\cluster-up.ps1; .\scripts\install-stack.ps1; .\scripts\deploy-app.ps1

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [switch]$DeleteCrds,
    [switch]$KeepNamespaces,
    [switch]$Yes,
    [switch]$Help
)

$RepoRoot = Split-Path -Parent $PSScriptRoot

$MonitoringNs = 'monitoring'
$AppNs        = 'demo'

$KpsRelease      = 'kube-prometheus-stack'
$LokiRelease     = 'loki'
$PromtailRelease = 'promtail'
$TempoRelease    = 'tempo'

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
uninstall.ps1 - remove everything this repo installed

USAGE
    .\scripts\uninstall.ps1 [-DeleteCrds] [-KeepNamespaces] [-Yes] [-Help]

PARAMETERS
    -DeleteCrds       also delete the Prometheus Operator CRDs (cluster-wide)
    -KeepNamespaces   leave '$MonitoringNs' and '$AppNs' in place
    -Yes              skip the confirmation prompt
    -Help             print this help and exit
"@
}

if ($Help) { Show-Usage; exit 0 }

Write-Host ""
Write-Host "k8s-observability-stack - uninstall" -ForegroundColor White
Write-Host "repo root : $RepoRoot" -ForegroundColor DarkGray

if ($null -eq (Get-Command 'kubectl' -ErrorAction SilentlyContinue)) {
    Write-Err "kubectl not found on PATH"
    exit 1
}

$null = & kubectl cluster-info --request-timeout=10s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "kubectl cannot reach a cluster - nothing to uninstall, or the cluster is already gone"
    exit 0
}

if (-not $Yes) {
    Write-Host ""
    Write-Host "This will delete:"
    Write-Host "  - Helm releases: $KpsRelease, $LokiRelease, $PromtailRelease, $TempoRelease"
    Write-Host "  - the orders-api app (namespace '$AppNs')"
    if (-not $KeepNamespaces) {
        Write-Host "  - namespaces '$MonitoringNs' and '$AppNs' (and everything left inside them)"
    }
    if ($DeleteCrds) {
        Write-Host "  - the Prometheus Operator CRDs (cluster-wide - affects ANY other Prometheus install on this cluster)"
    }
    $reply = Read-Host "`nContinue? [y/N]"
    if ($reply -notmatch '^[Yy]$') {
        Write-Info "aborted - nothing was changed"
        exit 0
    }
}

# -----------------------------------------------------------------------------
# 1. Stop local port-forwards
# -----------------------------------------------------------------------------
Write-Step "Stopping local port-forwards"
$pfScript = Join-Path $RepoRoot 'scripts\port-forward.ps1'
if (Test-Path $pfScript) {
    try { & $pfScript -Stop } catch { Write-Warn "port-forward.ps1 -Stop reported an error: $($_.Exception.Message)" }
}
else {
    Write-Warn "scripts\port-forward.ps1 not found - skipping"
}

# -----------------------------------------------------------------------------
# 2. k6 Job/ConfigMap
# -----------------------------------------------------------------------------
Write-Step "Removing the k6 load-test Job and ConfigMap"
$null = & kubectl -n $AppNs delete job k6-load-test --ignore-not-found 2>&1
$null = & kubectl -n $AppNs delete configmap k6-scripts --ignore-not-found 2>&1
Write-Ok "k6 resources removed (if present)"

# -----------------------------------------------------------------------------
# 3. orders-api app
# -----------------------------------------------------------------------------
Write-Step "Removing orders-api"
$null = & kubectl get namespace $AppNs 2>&1
if ($LASTEXITCODE -eq 0) {
    $null = & kubectl delete -f (Join-Path $RepoRoot 'app\k8s\servicemonitor.yaml') --ignore-not-found 2>&1
    $null = & kubectl delete -f (Join-Path $RepoRoot 'app\k8s\deployment.yaml') --ignore-not-found 2>&1
    $null = & kubectl delete -f (Join-Path $RepoRoot 'app\k8s\service.yaml') --ignore-not-found 2>&1
    Write-Ok "orders-api objects removed"
}
else {
    Write-Info "namespace '$AppNs' does not exist - nothing to remove"
}

# -----------------------------------------------------------------------------
# 4. Helm releases, in reverse install order
# -----------------------------------------------------------------------------
Write-Step "Uninstalling Helm releases from '$MonitoringNs'"

if ($null -ne (Get-Command 'helm' -ErrorAction SilentlyContinue)) {
    foreach ($release in @($TempoRelease, $PromtailRelease, $LokiRelease, $KpsRelease)) {
        $null = & helm status $release -n $MonitoringNs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $null = & helm uninstall $release -n $MonitoringNs 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Ok "uninstalled $release" }
            else { Write-Warn "failed to uninstall $release - it may already be gone" }
        }
        else {
            Write-Info "release '$release' not found - skipping"
        }
    }
}
else {
    Write-Warn "helm not found on PATH - skipping Helm release uninstall (namespace deletion below still removes the workloads)"
}

# -----------------------------------------------------------------------------
# 5. Namespaces (unless -KeepNamespaces)
# -----------------------------------------------------------------------------
if ($KeepNamespaces) {
    Write-Step "Leaving namespaces in place (-KeepNamespaces)"
    Write-Info "'$MonitoringNs' and '$AppNs' were left as-is; any remaining PVCs/ConfigMaps/Secrets live on in them"
}
else {
    Write-Step "Deleting namespaces '$MonitoringNs' and '$AppNs'"
    $null = & kubectl delete namespace $MonitoringNs --ignore-not-found --timeout=120s 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "namespace '$MonitoringNs' deleted" }
    else { Write-Warn "namespace '$MonitoringNs' deletion did not confirm within 120s - check: kubectl get namespace" }

    $null = & kubectl delete namespace $AppNs --ignore-not-found --timeout=120s 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "namespace '$AppNs' deleted" }
    else { Write-Warn "namespace '$AppNs' deletion did not confirm within 120s - check: kubectl get namespace" }
}

# -----------------------------------------------------------------------------
# 6. CRDs - cluster-scoped, survive both helm uninstall and namespace deletion.
# -----------------------------------------------------------------------------
if ($DeleteCrds) {
    Write-Step "Deleting Prometheus Operator CRDs (cluster-wide)"
    $crds = & kubectl get crd -o name 2>$null | Where-Object { $_ -match 'monitoring\.coreos\.com' }
    if (-not $crds) {
        Write-Info "no monitoring.coreos.com CRDs found - already clean"
    }
    else {
        $failed = $false
        foreach ($crd in $crds) {
            $null = & kubectl delete $crd 2>&1
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        }
        if ($failed) { Write-Warn "some CRDs may not have deleted - check: kubectl get crd | findstr monitoring.coreos.com" }
        else { Write-Ok "Prometheus Operator CRDs deleted" }
    }
}
else {
    Write-Step "Leaving CRDs in place"
    Write-Info "re-run with -DeleteCrds to remove monitoring.coreos.com CRDs cluster-wide"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " UNINSTALL COMPLETE" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " The minikube cluster itself is untouched. For a full reset:"
Write-Host "   minikube delete"
Write-Host " To reinstall:"
Write-Host "   .\scripts\cluster-up.ps1; .\scripts\install-stack.ps1; .\scripts\deploy-app.ps1"
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

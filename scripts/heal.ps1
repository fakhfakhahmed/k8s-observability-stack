<#
.SYNOPSIS
    The escape hatch: disarm chaos on every orders-api pod.

.DESCRIPTION
    Purpose
    -------
    scripts/trigger-incident.ps1's own teardown is best-effort (see
    load/k6/failure-scenario.js's header comment for exactly why a k6 Job's
    teardown() can fail to run: the pod is killed, activeDeadlineSeconds
    expires, the node dies, or you close your laptop mid-demo). This script is
    the AUTHORITATIVE, idempotent "stop the bleeding" command - run it any
    time you are not sure whether chaos is still armed.

    Chaos state lives IN-MEMORY, per pod (see app/main.go's chaosState
    comment) - there is no single place to reset it. This script iterates
    every orders-api pod individually and calls its own /chaos/reset, rather
    than hitting the Service once (which would only reach ONE replica, at
    random, behind the ClusterIP load balancer).

    Usage
    -----
        .\scripts\heal.ps1
        .\scripts\heal.ps1 -Restart

    Parameters
    ----------
        -Restart   also rollout-restart deployment/orders-api for a
                   guaranteed clean slate, even if a pod's own /chaos/reset
                   call fails
        -Help      print usage and exit 0

    What it changes
    ---------------
        Calls /chaos/reset inside every orders-api pod. With -Restart, also
        triggers a rolling restart of deployment/orders-api in namespace
        'demo'. Also deletes a completed/failed k6-load-test Job so
        trigger-incident.ps1 can be re-run without a manual kubectl delete
        job first.

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$AppNs   = 'demo'
$AppName = 'orders-api'
$AppPort = 8080

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
heal.ps1 - disarm chaos on every $AppName pod (the trigger-incident escape hatch)

USAGE
    .\scripts\heal.ps1 [-Restart] [-Help]

PARAMETERS
    -Restart   also rollout-restart deployment/$AppName for a guaranteed
               clean slate, even if a pod's own /chaos/reset call fails
    -Help      print this help and exit
"@
}

if ($Help) { Show-Usage; exit 0 }

Write-Host ""
Write-Host "k8s-observability-stack - heal" -ForegroundColor White
Write-Host "repo root : $RepoRoot" -ForegroundColor DarkGray

Write-Step "Checking prerequisites"

if ($null -eq (Get-Command 'kubectl' -ErrorAction SilentlyContinue)) {
    Write-Err "kubectl not found on PATH"
    exit 1
}
Write-Ok "kubectl found"

$null = & kubectl cluster-info --request-timeout=10s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "kubectl cannot reach a cluster"
    exit 1
}
Write-Ok "cluster reachable"

# -----------------------------------------------------------------------------
# Reset chaos on every pod individually
# -----------------------------------------------------------------------------
Write-Step "Resetting chaos on every $AppName pod in '$AppNs'"

$podNames = & kubectl -n $AppNs get pods -l "app.kubernetes.io/name=$AppName" `
    --field-selector=status.phase=Running `
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>$null
$pods = @($podNames -split "`n" | Where-Object { $_ -ne '' })

$resetFail = 0
if ($pods.Count -eq 0) {
    Write-Warn "no Running $AppName pods found in namespace '$AppNs'"
    Write-Info "nothing to heal - is the app deployed? .\scripts\deploy-app.ps1"
}
else {
    foreach ($pod in $pods) {
        $result = & kubectl -n $AppNs exec $pod -- sh -c `
            "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:$AppPort/chaos/reset 2>/dev/null" 2>$null

        if ($result -match '^2\d\d$') {
            Write-Ok "$pod`: chaos reset (HTTP $result)"
        }
        else {
            Write-Warn "$pod`: chaos reset failed or inconclusive (result: '$result')"
            $resetFail++
        }
    }

    if ($resetFail -gt 0 -and -not $Restart) {
        Write-Warn "$resetFail pod(s) could not be confirmed healed"
        Write-Info "re-run with -Restart for a guaranteed clean slate:"
        Write-Info "    .\scripts\heal.ps1 -Restart"
    }
}

# -----------------------------------------------------------------------------
# Optional: rollout restart (chaos state is in-memory, so a fresh pod has none)
# -----------------------------------------------------------------------------
if ($Restart) {
    Write-Step "Rolling restart of deployment/$AppName"
    $null = & kubectl -n $AppNs rollout restart "deployment/$AppName" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $null = & kubectl -n $AppNs rollout status "deployment/$AppName" --timeout=120s 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "deployment/$AppName restarted and ready"
        }
        else {
            Write-Warn "rollout restart started but did not confirm ready within 120s"
        }
    }
    else {
        Write-Err "rollout restart failed - deployment/$AppName may not exist"
    }
}

# -----------------------------------------------------------------------------
# Clean up a finished k6 Job so trigger-incident.ps1 can be re-run without a
# manual kubectl delete job first - Jobs are immutable once created.
# -----------------------------------------------------------------------------
Write-Step "Clearing any finished k6-load-test Job"

$null = & kubectl -n $AppNs get job k6-load-test 2>&1
if ($LASTEXITCODE -eq 0) {
    $null = & kubectl -n $AppNs delete job k6-load-test --ignore-not-found 2>&1
    Write-Ok "removed job/k6-load-test"
}
else {
    Write-Info "no k6-load-test Job present - nothing to remove"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " HEAL COMPLETE" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " Verify on the dashboards (allow ~1 short-window period for alerts to clear):"
Write-Host "   obs-app-red    error rate back near 0%, p99 back under 300ms"
Write-Host "   obs-slo-budget burn-rate ladder back under 1x"
Write-Host "   Alertmanager   ErrorBudgetBurn / HighErrorRate resolved (not just silenced)"
Write-Host ""
Write-Host " If an alert stays firing much longer than its short window after this,"
Write-Host " something else is wrong - see docs/troubleshooting.md, not just this script."
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

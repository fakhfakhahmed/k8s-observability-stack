<#
.SYNOPSIS
    The LinkedIn demo: prove the alerting pipeline actually works.

.DESCRIPTION
    Purpose
    -------
    Runs load/k6/failure-scenario.js as a Kubernetes Job against orders-api.
    That script, on its own, arms the app's chaos endpoints (35% forced 5xx,
    25% of requests delayed 900ms), holds a steady broken state, generates
    enough traffic for Prometheus to notice, then (best-effort) disarms chaos
    again on exit. This script is the operator-friendly wrapper: it checks
    prerequisites, regenerates the k6 ConfigMap from the REAL source scripts,
    prints the exact incident timeline, and tells you precisely what to
    screenshot and when.

    A RED/FAILED k6 summary at the end is the CORRECT, EXPECTED result - see
    load/k6/failure-scenario.js's header comment. This script's own exit code
    reflects whether the DEMO ran successfully, not whether orders-api stayed
    healthy (it is not supposed to).

    Usage
    -----
        .\scripts\trigger-incident.ps1
        .\scripts\trigger-incident.ps1 -Duration 20m
        .\scripts\trigger-incident.ps1 -ErrorPct 50 -LatencyMs 1200 -LatencyPct 40
        .\scripts\trigger-incident.ps1 -NoFollow

    Parameters
    ----------
        -Duration <string>   how long to hold the broken steady state
                              (default 10m; 20m reaches the 3x/1x ticket
                              rungs too, 45m reaches the latency page)
        -Vus <int>            concurrent virtual users (default 10)
        -ErrorPct <int>       % of requests forced to 5xx (default 35)
        -LatencyMs <int>      injected delay in ms (default 900)
        -LatencyPct <int>     % of requests delayed (default 25)
        -NoFollow             apply the Job and exit instead of streaming logs
        -Help                 print usage and exit 0

    Prerequisites
    -------------
        orders-api deployed with CHAOS_ENABLED=true (the default in
        app/k8s/deployment.yaml - .\scripts\deploy-app.ps1 already sets it).

    What it changes
    ---------------
        Regenerates ConfigMap 'k6-scripts' and creates Job 'k6-load-test' in
        namespace 'demo'. Deletes any previous k6-load-test Job first (Jobs
        are immutable once created). orders-api is deliberately broken for
        the run's duration via its own chaos endpoints - this is the point.

    How to undo it
    --------------
        .\scripts\heal.ps1

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [string]$Duration = '10m',
    [int]$Vus = 10,
    [int]$ErrorPct = 35,
    [int]$LatencyMs = 900,
    [int]$LatencyPct = 25,
    [switch]$NoFollow,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$AppNs         = 'demo'
$AppName       = 'orders-api'
$K6Dir         = Join-Path $RepoRoot 'load\k6'
$JobName       = 'k6-load-test'
$ConfigMapName = 'k6-scripts'

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
trigger-incident.ps1 - burn the error budget on purpose and watch the alerting fire

USAGE
    .\scripts\trigger-incident.ps1 [-Duration <dur>] [-Vus <n>]
        [-ErrorPct <n>] [-LatencyMs <n>] [-LatencyPct <n>] [-NoFollow]

PARAMETERS
    -Duration <dur>    hold time, e.g. 10m / 20m / 45m (default 10m)
    -Vus <n>           concurrent virtual users (default 10)
    -ErrorPct <n>      % of requests forced to 5xx (default 35)
    -LatencyMs <n>     injected delay, ms (default 900)
    -LatencyPct <n>    % of requests delayed (default 25)
    -NoFollow          apply the Job and exit, do not stream logs

RUNG TIMING GUIDE (default 35%/900ms/25%)
    ~5 min   ErrorBudgetBurn availability 14.4x (page)
    ~8 min   ErrorBudgetBurn availability 6x    (page)
    ~14 min  ErrorBudgetBurn availability 3x and 1x (ticket)
    ~37 min  ErrorBudgetBurn latency 14.4x (page) - needs -Duration 45m
"@
}

if ($Help) { Show-Usage; exit 0 }

Write-Host ""
Write-Host "k8s-observability-stack - trigger-incident" -ForegroundColor White
Write-Host "repo root : $RepoRoot" -ForegroundColor DarkGray
Write-Host "profile   : $Vus VUs, $Duration hold, $ErrorPct% errors, $LatencyPct% @ ${LatencyMs}ms latency" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if ($null -eq (Get-Command 'kubectl' -ErrorAction SilentlyContinue)) {
    Write-Err "kubectl not found on PATH"
    exit 1
}
Write-Ok "kubectl found"

$null = & kubectl cluster-info --request-timeout=10s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "kubectl cannot reach a cluster - run .\scripts\cluster-up.ps1 first"
    exit 1
}
Write-Ok "cluster reachable"

$null = & kubectl -n $AppNs get deployment $AppName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "deployment/$AppName not found in namespace '$AppNs'"
    Write-Info "run .\scripts\deploy-app.ps1 first"
    exit 1
}
Write-Ok "deployment/$AppName found"

$chaosFlag = & kubectl -n $AppNs get deployment $AppName `
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHAOS_ENABLED")].value}' 2>$null
if ($chaosFlag -ne 'true') {
    Write-Warn "CHAOS_ENABLED is not 'true' on deployment/$AppName (found: '$chaosFlag')"
    Write-Info "the chaos endpoints will 404 and the k6 setup() will abort"
    Write-Info "fix with: kubectl -n $AppNs set env deployment/$AppName CHAOS_ENABLED=true"
    Write-Info "          kubectl -n $AppNs rollout status deployment/$AppName"
    exit 1
}
Write-Ok "CHAOS_ENABLED=true confirmed"

foreach ($f in @('steady.js', 'spike.js', 'failure-scenario.js')) {
    if (-not (Test-Path (Join-Path $K6Dir $f))) {
        Write-Err "missing $K6Dir\$f"
        exit 1
    }
}
Write-Ok "k6 scripts present"

# ---------------------------------------------------------------------------
# Regenerate the ConfigMap from the REAL source files
# ---------------------------------------------------------------------------
Write-Step "Regenerating ConfigMap '$ConfigMapName' from load\k6\"

$cmArgs = @(
    'create', 'configmap', $ConfigMapName,
    '--namespace', $AppNs,
    "--from-file=$(Join-Path $K6Dir 'steady.js')",
    "--from-file=$(Join-Path $K6Dir 'spike.js')",
    "--from-file=$(Join-Path $K6Dir 'failure-scenario.js')",
    '--dry-run=client', '-o', 'yaml'
)
$cmYaml = & kubectl @cmArgs
$cmYaml | & kubectl apply -f - | Out-Null
Write-Ok "ConfigMap '$ConfigMapName' applied"

# ---------------------------------------------------------------------------
# Clear any previous run
# ---------------------------------------------------------------------------
Write-Step "Clearing any previous $JobName Job"
$null = & kubectl -n $AppNs delete job $JobName --ignore-not-found 2>&1
Write-Ok "namespace clear for a new run"

# ---------------------------------------------------------------------------
# Apply the incident Job
# ---------------------------------------------------------------------------
Write-Step "Starting the failure scenario (Job/$JobName)"

$jobYaml = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $JobName
  namespace: $AppNs
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
              value: "http://$AppName.$AppNs.svc.cluster.local:8080"
            - name: DURATION
              value: "$Duration"
            - name: VUS
              value: "$Vus"
            - name: ERROR_PCT
              value: "$ErrorPct"
            - name: LATENCY_MS
              value: "$LatencyMs"
            - name: LATENCY_PCT
              value: "$LatencyPct"
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
            name: $ConfigMapName
"@

$jobYaml | & kubectl apply -f - | Out-Null
Write-Ok "job/$JobName created"

# ---------------------------------------------------------------------------
# Watch / screenshot guidance
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " INCIDENT RUNNING - WATCH / SCREENSHOT, IN THIS ORDER" -ForegroundColor White
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host "  1. http://localhost:3000/d/obs-app-red        RED dashboard: error %, p99, in-flight climbing"
Write-Host "  2. http://localhost:3000/d/obs-slo-budget      SLO dashboard: burn-rate ladder crossing 14.4x"
Write-Host "  3. http://localhost:9090/alerts                Prometheus: PENDING then FIRING"
Write-Host "  4. http://localhost:9093                       Alertmanager: grouped, routed, runbook_url visible"
Write-Host "  5. Tempo (via Grafana): a trace with the injected chaos span and its correlated log line"
Write-Host "  6. http://localhost:3000/d/obs-logs-explorer    Logs: error-level lines for orders-api"
Write-Host ""
Write-Host "  (If a UI above is not open yet: .\scripts\port-forward.ps1)"
Write-Host ""
Write-Host "  Approximate timing at the defaults (35% errors / 900ms / 25%):"
Write-Host "    ~5 min   ErrorBudgetBurn availability 14.4x fires (page)"
Write-Host "    ~8 min   ErrorBudgetBurn availability 6x fires (page)"
Write-Host "    ~14 min  ErrorBudgetBurn availability 3x and 1x fire (ticket)"
Write-Host "    ~37 min  ErrorBudgetBurn latency 14.4x fires (page) - needs -Duration 45m"
Write-Host ""
Write-Host "  A RED/FAILED k6 summary at the end is the CORRECT result - see"
Write-Host "  load/k6/failure-scenario.js's header comment for why."
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White

if ($NoFollow) {
    Write-Info "not following logs (-NoFollow) - stream them yourself with:"
    Write-Info "    kubectl logs -f job/$JobName -n $AppNs"
    Write-Host ""
    exit 0
}

Write-Step "Streaming job/$JobName logs (Ctrl-C to detach - the Job keeps running)"
Write-Host ""

for ($i = 0; $i -lt 30; $i++) {
    $podName = & kubectl -n $AppNs get pods -l "job-name=$JobName" -o jsonpath='{.items[0].metadata.name}' 2>$null
    if (-not [string]::IsNullOrWhiteSpace($podName)) { break }
    Start-Sleep -Seconds 1
}

& kubectl logs -f "job/$JobName" -n $AppNs
# Logs streaming can exit non-zero once the Job pod terminates (expected for a
# failed-threshold k6 run) - do not let that abort this wrapper script.

Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " INCIDENT RUN FINISHED" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " teardown() inside failure-scenario.js should have already called /chaos/reset."
Write-Host " DO NOT TRUST IT - confirm (or force it) with:"
Write-Host "   .\scripts\heal.ps1"
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

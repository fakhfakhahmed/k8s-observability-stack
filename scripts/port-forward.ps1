<#
.SYNOPSIS
    Start (or stop) background kubectl port-forwards for the observability UIs.

.DESCRIPTION
    Purpose
    -------
    Opens the four UIs this project uses on fixed local ports:

        Grafana       http://localhost:3000   svc/kube-prometheus-stack-grafana      (ns monitoring)
        Prometheus    http://localhost:9090   svc/kube-prometheus-stack-prometheus   (ns monitoring)
        Alertmanager  http://localhost:9093   svc/kube-prometheus-stack-alertmanager (ns monitoring)
        orders-api    http://localhost:8080   svc/orders-api                         (ns demo, -IncludeApp)

    Each forward runs as a detached process. Their PIDs are written to
    .portforward-pids in the repo root so a later '-Stop' can terminate exactly
    the processes this script started - and nothing else.

    Usage
    -----
        .\scripts\port-forward.ps1
        .\scripts\port-forward.ps1 -IncludeApp
        .\scripts\port-forward.ps1 -Stop
        .\scripts\port-forward.ps1 -Status
        .\scripts\port-forward.ps1 -Help

    Parameters
    ----------
        -IncludeApp   also forward orders-api on 8080 (needed by
                      'trigger-incident.ps1 -ViaPortForward')
        -Stop         kill every port-forward recorded in .portforward-pids
        -Status       list the recorded forwards and whether they are alive
        -Help         print usage and exit 0

    Prerequisites
    -------------
        .\scripts\install-stack.ps1 (and .\scripts\deploy-app.ps1 for -IncludeApp).

    What it changes
    ---------------
        Starts local processes and writes <repo>\.portforward-pids.
        Nothing inside the cluster is modified.

    How to undo it
    --------------
        .\scripts\port-forward.ps1 -Stop

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [switch]$IncludeApp,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# ---------------------------------------------------------------------------
$MonitoringNs = 'monitoring'
$AppNs        = 'demo'
$KpsRelease   = 'kube-prometheus-stack'
$AppName      = 'orders-api'

$GrafanaAdminUser = 'admin'
$GrafanaAdminPass = 'observability'

# Dashboard uids are fixed by the naming contract and are what make the deep
# links below stable across re-installs.
$DashUidAppRed    = 'obs-app-red'
$DashUidSloBudget = 'obs-slo-budget'
$DashUidCluster   = 'obs-k8s-cluster'
$DashUidLogs      = 'obs-logs-explorer'

$PidFile = Join-Path $RepoRoot '.portforward-pids'

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
port-forward.ps1 - background port-forwards for Grafana, Prometheus, Alertmanager

USAGE
    .\scripts\port-forward.ps1 [-IncludeApp] [-Stop] [-Status] [-Help]

PARAMETERS
    -IncludeApp   also forward $AppName on 8080
    -Stop         kill every forward recorded in .portforward-pids
    -Status       show the recorded forwards and whether they are alive
    -Help         print this help and exit

PORTS
    3000 Grafana   9090 Prometheus   9093 Alertmanager   8080 $AppName
"@
}

if ($Help) { Show-Usage; exit 0 }

# ---------------------------------------------------------------------------
# PID file helpers. The file is a simple "port<TAB>pid<TAB>label" record so it
# is both machine-parseable and readable if someone opens it in an editor.
# ---------------------------------------------------------------------------
function Read-PidFile {
    if (-not (Test-Path -LiteralPath $PidFile)) { return @() }
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }
        $rows += [pscustomobject]@{
            Port  = [int]$parts[0]
            Pid   = [int]$parts[1]
            Label = $parts[2]
        }
    }
    return $rows
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    return ($null -ne $p)
}

# ---------------------------------------------------------------------------
# -Status
# ---------------------------------------------------------------------------
if ($Status) {
    Write-Step "Recorded port-forwards"
    $rows = Read-PidFile
    if ($rows.Count -eq 0) {
        Write-Info "no .portforward-pids file - nothing has been started from this repo"
        exit 0
    }
    Write-Host (" {0,-6} {1,-8} {2,-16} {3}" -f 'PORT', 'PID', 'TARGET', 'STATE') -ForegroundColor White
    foreach ($r in $rows) {
        $alive = Test-ProcessAlive -ProcessId $r.Pid
        $state = 'dead'
        $colour = 'Yellow'
        if ($alive) { $state = 'running'; $colour = 'Green' }
        Write-Host (" {0,-6} {1,-8} {2,-16} {3}" -f $r.Port, $r.Pid, $r.Label, $state) -ForegroundColor $colour
    }
    exit 0
}

# ---------------------------------------------------------------------------
# -Stop
# ---------------------------------------------------------------------------
if ($Stop) {
    Write-Step "Stopping port-forwards recorded in .portforward-pids"

    $rows = Read-PidFile
    if ($rows.Count -eq 0) {
        Write-Info "nothing to stop (no .portforward-pids file)"
        exit 0
    }

    foreach ($r in $rows) {
        if (Test-ProcessAlive -ProcessId $r.Pid) {
            try {
                Stop-Process -Id $r.Pid -Force -ErrorAction Stop
                Write-Ok "stopped $($r.Label) on port $($r.Port) (pid $($r.Pid))"
            }
            catch {
                Write-Warn "could not stop pid $($r.Pid): $($_.Exception.Message)"
            }
        }
        else {
            Write-Info "$($r.Label) (pid $($r.Pid)) was already gone"
        }
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Ok "removed .portforward-pids"
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Start mode
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "k8s-observability-stack - port-forward" -ForegroundColor White
Write-Host "repo root : $RepoRoot" -ForegroundColor DarkGray

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

# Running the script twice should not spawn a second set of forwards.
$existing = Read-PidFile
$liveExisting = @($existing | Where-Object { Test-ProcessAlive -ProcessId $_.Pid })
if ($liveExisting.Count -gt 0) {
    Write-Warn "$($liveExisting.Count) port-forward(s) from a previous run are still alive"
    Write-Info "stopping them first so the ports are free (this is the idempotent path)"
    foreach ($r in $liveExisting) {
        try { Stop-Process -Id $r.Pid -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 500
}
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Forward definitions
# ---------------------------------------------------------------------------
$Forwards = @(
    [pscustomobject]@{ Label = 'grafana';      Namespace = $MonitoringNs; Service = "svc/$KpsRelease-grafana";      Local = 3000; Remote = 80;   Url = 'http://localhost:3000' }
    [pscustomobject]@{ Label = 'prometheus';   Namespace = $MonitoringNs; Service = "svc/$KpsRelease-prometheus";   Local = 9090; Remote = 9090; Url = 'http://localhost:9090' }
    [pscustomobject]@{ Label = 'alertmanager'; Namespace = $MonitoringNs; Service = "svc/$KpsRelease-alertmanager"; Local = 9093; Remote = 9093; Url = 'http://localhost:9093' }
)

if ($IncludeApp) {
    $Forwards += [pscustomobject]@{ Label = $AppName; Namespace = $AppNs; Service = "svc/$AppName"; Local = 8080; Remote = 8080; Url = 'http://localhost:8080' }
}

# ---------------------------------------------------------------------------
# Port availability. Detecting a conflict before kubectl does lets us explain
# which process is squatting on the port instead of printing kubectl's terse
# "unable to listen on any of the requested ports".
# ---------------------------------------------------------------------------
function Test-PortFree {
    param([int]$Port)
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($null -ne $conns) { return $false }
        return $true
    }
    catch {
        # Get-NetTCPConnection is unavailable on some minimal systems; fall back
        # to a raw socket bind test.
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            $listener.Stop()
            return $true
        }
        catch { return $false }
    }
}

function Get-PortOwner {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $conn) { return 'unknown' }
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return "pid $($conn.OwningProcess)" }
        return "$($proc.ProcessName) (pid $($proc.Id))"
    }
    catch { return 'unknown' }
}

Write-Step "Starting port-forwards"

$started = New-Object System.Collections.ArrayList
$lines   = New-Object System.Collections.ArrayList

foreach ($f in $Forwards) {
    # Does the Service exist? A missing Service is far more likely than a real
    # networking problem, and the message should say so.
    $null = & kubectl -n $f.Namespace get $f.Service 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "$($f.Service) not found in namespace $($f.Namespace) - skipping $($f.Label)"
        if ($f.Label -eq $AppName) {
            Write-Info "run .\scripts\deploy-app.ps1 first"
        }
        else {
            Write-Info "run .\scripts\install-stack.ps1 first"
        }
        continue
    }

    if (-not (Test-PortFree -Port $f.Local)) {
        $owner = Get-PortOwner -Port $f.Local
        Write-Warn "local port $($f.Local) is already in use by $owner - skipping $($f.Label)"
        Write-Info "if that is an old forward from this repo: .\scripts\port-forward.ps1 -Stop"
        Write-Info "otherwise free the port, or forward manually on another one:"
        Write-Info "    kubectl -n $($f.Namespace) port-forward $($f.Service) <otherport>:$($f.Remote)"
        continue
    }

    # Start-Process with -WindowStyle Hidden detaches the forward so the current
    # shell stays usable. Its PID is what -Stop later targets.
    $procArgs = @('-n', $f.Namespace, 'port-forward', $f.Service, "$($f.Local):$($f.Remote)", '--address=127.0.0.1')
    $proc = Start-Process -FilePath 'kubectl' -ArgumentList $procArgs -WindowStyle Hidden -PassThru

    if ($null -eq $proc) {
        Write-Err "failed to start the port-forward for $($f.Label)"
        continue
    }

    $null = $started.Add($proc.Id)
    $null = $lines.Add("$($f.Local)`t$($proc.Id)`t$($f.Label)")
    Write-Ok "$($f.Label) -> $($f.Url) (pid $($proc.Id))"
}

if ($lines.Count -eq 0) {
    Write-Err "no port-forwards could be started"
    exit 1
}

# Persist the PIDs so -Stop can clean up precisely.
Set-Content -LiteralPath $PidFile -Value ($lines -join "`r`n") -Encoding ASCII
Write-Info "PIDs recorded in .portforward-pids"

# kubectl needs a moment to establish the tunnel before the first HTTP request
# succeeds; without this a user clicking immediately sees a connection refused.
Start-Sleep -Seconds 3

# Drop any forward that died during startup - usually a port race.
$final = @()
foreach ($r in (Read-PidFile)) {
    if (Test-ProcessAlive -ProcessId $r.Pid) { $final += $r }
    else { Write-Warn "the $($r.Label) forward exited immediately - port $($r.Port) may have been taken" }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " PORT-FORWARDS ACTIVE" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host (" {0,-14} {1,-28} {2}" -f 'UI', 'URL', 'KUBERNETES SERVICE') -ForegroundColor White
Write-Host " -------------- ---------------------------- -----------------------------" -ForegroundColor DarkGray

foreach ($f in $Forwards) {
    $isLive = @($final | Where-Object { $_.Label -eq $f.Label }).Count -gt 0
    if (-not $isLive) { continue }
    Write-Host (" {0,-14} {1,-28} {2}" -f $f.Label, $f.Url, "$($f.Service) (ns $($f.Namespace))") -ForegroundColor Gray
}

Write-Host ""
Write-Host " GRAFANA LOGIN" -ForegroundColor White
Write-Host "   user     : $GrafanaAdminUser" -ForegroundColor Gray
Write-Host "   password : $GrafanaAdminPass" -ForegroundColor Gray
Write-Host "   (stored in Secret 'grafana-admin-credentials' in namespace '$MonitoringNs')" -ForegroundColor DarkGray

Write-Host ""
Write-Host " DASHBOARD DEEP LINKS" -ForegroundColor White
Write-Host (" {0,-34} {1}" -f 'Orders API - RED Metrics',       "http://localhost:3000/d/$DashUidAppRed")    -ForegroundColor Gray
Write-Host (" {0,-34} {1}" -f 'Orders API - SLO & Error Budget', "http://localhost:3000/d/$DashUidSloBudget") -ForegroundColor Gray
Write-Host (" {0,-34} {1}" -f 'Kubernetes - Cluster Health',     "http://localhost:3000/d/$DashUidCluster")   -ForegroundColor Gray
Write-Host (" {0,-34} {1}" -f 'Orders API - Logs Explorer',      "http://localhost:3000/d/$DashUidLogs")      -ForegroundColor Gray

Write-Host ""
Write-Host " USEFUL PROMETHEUS / ALERTMANAGER PAGES" -ForegroundColor White
Write-Host "   targets  : http://localhost:9090/targets" -ForegroundColor Gray
Write-Host "   alerts   : http://localhost:9090/alerts" -ForegroundColor Gray
Write-Host "   rules    : http://localhost:9090/rules" -ForegroundColor Gray
Write-Host "   silences : http://localhost:9093/#/silences" -ForegroundColor Gray

Write-Host ""
Write-Host " These forwards survive this shell. Stop them with:" -ForegroundColor White
Write-Host "   .\scripts\port-forward.ps1 -Stop" -ForegroundColor Yellow
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

<#
.SYNOPSIS
    Start (or verify) the local minikube cluster used by k8s-observability-stack.

.DESCRIPTION
    Purpose
    -------
    Brings up a single-node minikube cluster sized for the full observability
    stack, enables the addons the stack depends on, and pre-creates the two
    namespaces used by the project:

        monitoring  -> kube-prometheus-stack, Loki, Promtail, Tempo
        demo        -> the orders-api demo application

    The script is idempotent: if the profile is already Running it skips the
    start but still verifies the sizing, re-applies the addons and re-applies
    the namespaces.

    Usage
    -----
        .\scripts\cluster-up.ps1
        .\scripts\cluster-up.ps1 -Cpus 6 -Memory 12288
        .\scripts\cluster-up.ps1 -Memory 6144            # low-RAM fallback
        .\scripts\cluster-up.ps1 -Driver hyperv
        .\scripts\cluster-up.ps1 -Help

    Parameters
    ----------
        -Cpus      vCPUs given to the cluster       (default 4)
        -Memory    MB of RAM given to the cluster   (default 8192)
        -DiskSize  disk image size, minikube syntax (default 40g)
        -Driver    minikube driver                  (default docker)
        -Profile   minikube profile name            (default minikube)
        -Help      print usage and exit 0

    Prerequisites
    -------------
        .\scripts\preflight.ps1 passing. In particular Docker Desktop must be
        running when the default --driver=docker is used.

    What it changes
    ---------------
        * Creates/starts the minikube profile named by -Profile.
        * Enables addons: metrics-server, storage-provisioner, default-storageclass.
        * Creates namespaces 'monitoring' and 'demo'.
        * Switches the current kubectl context to the profile.

    How to undo it
    --------------
        .\scripts\uninstall.ps1 -DeleteCluster
        or simply: minikube delete -p minikube

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [int]$Cpus      = 4,
    [int]$Memory    = 8192,
    [string]$DiskSize = '40g',
    [string]$Driver = 'docker',
    [string]$Profile = 'minikube',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# ---------------------------------------------------------------------------
$MonitoringNs = 'monitoring'
$AppNs        = 'demo'

# Minimums the stack genuinely needs. Below these Prometheus and Loki will be
# OOMKilled or the kubelet will start evicting pods mid-demo.
$MinCpus     = 4
$MinMemoryMb = 8192

# Addons. metrics-server backs `kubectl top` and the HPA panels on the cluster
# dashboard; storage-provisioner + default-storageclass back the PVCs that
# Prometheus, Alertmanager, Loki and Tempo all request.
$Addons = @('metrics-server', 'default-storageclass', 'storage-provisioner')

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
cluster-up.ps1 - start the local minikube cluster for k8s-observability-stack

USAGE
    .\scripts\cluster-up.ps1 [-Cpus <int>] [-Memory <mb>] [-DiskSize <size>]
                             [-Driver <name>] [-Profile <name>] [-Help]

PARAMETERS
    -Cpus      vCPUs for the cluster              (default 4,     minimum $MinCpus)
    -Memory    MB of RAM for the cluster          (default 8192,  minimum $MinMemoryMb)
    -DiskSize  disk image size (minikube syntax)  (default 40g)
    -Driver    minikube driver                    (default docker)
    -Profile   minikube profile name              (default minikube)
    -Help      print this help and exit

EXAMPLES
    .\scripts\cluster-up.ps1
    .\scripts\cluster-up.ps1 -Memory 6144
    .\scripts\cluster-up.ps1 -Cpus 6 -Memory 12288 -DiskSize 60g
"@
}

if ($Help) { Show-Usage; exit 0 }

# ---------------------------------------------------------------------------
# Native-command guard. PowerShell's $ErrorActionPreference does NOT trap a
# non-zero exit code from an external executable, so every single native call
# in this repo is followed by an explicit check.
# ---------------------------------------------------------------------------
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

Write-Host ""
Write-Host "k8s-observability-stack - cluster-up" -ForegroundColor White
Write-Host "repo root: $RepoRoot" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Sanity-check the requested sizing before we ask minikube for anything.
# ---------------------------------------------------------------------------
Write-Step "Validating requested cluster size"

if ($Cpus -lt $MinCpus) {
    Write-Warn "requested $Cpus CPUs which is below the recommended $MinCpus"
    Write-Info "Prometheus rule evaluation and the k6 load job will contend for CPU."
}
if ($Memory -lt $MinMemoryMb) {
    Write-Warn "requested $Memory MB which is below the recommended $MinMemoryMb MB"
    Write-Info "Expect shorter Loki/Tempo retention and possible OOMKills under load."
}
Write-Info "profile=$Profile cpus=$Cpus memory=${Memory}MB disk=$DiskSize driver=$Driver"

# ---------------------------------------------------------------------------
# Required tooling
# ---------------------------------------------------------------------------
Write-Step "Checking required tools"

foreach ($tool in @('minikube', 'kubectl')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Err "$tool not found on PATH"
        Write-Info "run .\scripts\preflight.ps1 for installation hints"
        exit 1
    }
    Write-Ok "$tool found"
}

# With the docker driver minikube is useless without a live daemon, and the
# error minikube emits in that case is long and unhelpful. Catch it early.
if ($Driver -eq 'docker') {
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "the Docker daemon is not responding, but -Driver docker was requested"
        Write-Info "Start Docker Desktop, wait for the tray icon to settle, then re-run this script."
        Write-Info "Alternatively pass a different driver, for example: -Driver hyperv"
        exit 1
    }
    Write-Ok "Docker daemon reachable"
}

# ---------------------------------------------------------------------------
# Is the profile already up? `minikube status` exits non-zero when the profile
# does not exist or is stopped, which is exactly the signal we want - so the
# $LASTEXITCODE here is inspected, not asserted.
# ---------------------------------------------------------------------------
Write-Step "Checking whether profile '$Profile' is already running"

$hostStatus = ''
$statusOut = & minikube -p $Profile status --format '{{.Host}}' 2>$null
if ($LASTEXITCODE -eq 0 -and $statusOut) {
    $hostStatus = ($statusOut | Select-Object -First 1).ToString().Trim()
}

$alreadyRunning = ($hostStatus -eq 'Running')

if ($alreadyRunning) {
    Write-Ok "profile '$Profile' is already Running - skipping 'minikube start'"
    Write-Info "delete it first if you need to change cpus/memory: minikube delete -p $Profile"
}
else {
    if ($hostStatus) {
        Write-Info "profile '$Profile' exists but reports status '$hostStatus' - starting it"
    }
    else {
        Write-Info "profile '$Profile' does not exist yet - creating it"
    }

    Write-Step "Starting minikube (this takes 2-5 minutes on a first run)"

    & minikube start `
        --profile=$Profile `
        --cpus=$Cpus `
        --memory=$Memory `
        --disk-size=$DiskSize `
        --driver=$Driver `
        --addons=metrics-server `
        --wait=all

    if ($LASTEXITCODE -ne 0) {
        Write-Err "minikube start failed (exit code $LASTEXITCODE)"
        Write-Host ""
        Write-Host "    Most common causes and what to do:" -ForegroundColor Yellow
        Write-Host "      1. Not enough RAM assigned to Docker Desktop." -ForegroundColor Yellow
        Write-Host "         Docker Desktop -> Settings -> Resources -> Memory must be >= $([math]::Round($Memory/1024, 1)) GB." -ForegroundColor Yellow
        Write-Host "      2. The host simply does not have $Memory MB spare. Retry smaller:" -ForegroundColor Yellow
        Write-Host "             .\scripts\cluster-up.ps1 -Memory 6144" -ForegroundColor Yellow
        Write-Host "         What degrades at 6144 MB:" -ForegroundColor Yellow
        Write-Host "           - Prometheus retention must drop (edit stack/prometheus/values.yaml)." -ForegroundColor Yellow
        Write-Host "           - Loki and Tempo may be OOMKilled while the k6 load job runs." -ForegroundColor Yellow
        Write-Host "           - The 14.4x burn-rate demo still works, but with fewer samples." -ForegroundColor Yellow
        Write-Host "      3. A stale profile from a previous run. Clean up and retry:" -ForegroundColor Yellow
        Write-Host "             minikube delete -p $Profile" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    Write-Ok "minikube start completed"
}

# ---------------------------------------------------------------------------
# Verify the effective sizing. When the profile pre-existed, the -Cpus/-Memory
# arguments were ignored by minikube, so report what is actually in place.
# ---------------------------------------------------------------------------
Write-Step "Verifying effective cluster resources"

$profileJson = & minikube profile list -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $profileJson) {
    Write-Warn "could not read 'minikube profile list -o json' - skipping sizing verification"
}
else {
    try {
        $parsed = $profileJson | ConvertFrom-Json
        $match = $null
        foreach ($p in @($parsed.valid)) {
            if ($p.Name -eq $Profile) { $match = $p }
        }

        if ($null -eq $match) {
            Write-Warn "profile '$Profile' not present in 'minikube profile list' output"
        }
        else {
            $effCpus   = [int]$match.Config.CPUs
            $effMemory = [int]$match.Config.Memory
            Write-Info "effective: cpus=$effCpus memory=${effMemory}MB"

            if ($effCpus -lt $MinCpus -or $effMemory -lt $MinMemoryMb) {
                Write-Warn "the running cluster is below the recommended $MinCpus cpus / $MinMemoryMb MB"
                Write-Info "to resize you must recreate: minikube delete -p $Profile; .\scripts\cluster-up.ps1"
            }
            else {
                Write-Ok "cluster meets the recommended minimum"
            }
        }
    }
    catch {
        Write-Warn "could not parse minikube profile JSON: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Addons. `minikube addons enable` is naturally idempotent - enabling an
# already-enabled addon is a no-op that still exits 0.
# ---------------------------------------------------------------------------
Write-Step "Enabling required addons"

foreach ($addon in $Addons) {
    $null = & minikube -p $Profile addons enable $addon 2>&1
    if ($LASTEXITCODE -ne 0) {
        # default-storageclass/storage-provisioner are enabled by default on
        # most drivers; a failure there is noisy but not fatal.
        Write-Warn "addon '$addon' could not be enabled (exit $LASTEXITCODE) - continuing"
    }
    else {
        Write-Ok "addon '$addon' enabled"
    }
}

# ---------------------------------------------------------------------------
# kubectl context
# ---------------------------------------------------------------------------
Write-Step "Pointing kubectl at the '$Profile' context"

& kubectl config use-context $Profile | Out-Null
Assert-ExitCode -What "kubectl config use-context $Profile" -Hint "run: minikube -p $Profile update-context"
Write-Ok "current context is now '$Profile'"

# ---------------------------------------------------------------------------
# Namespaces. `kubectl create ns --dry-run=client -o yaml | kubectl apply -f -`
# is the canonical idempotent create: it succeeds whether or not the namespace
# already exists, and never mutates anything that is already correct.
# ---------------------------------------------------------------------------
Write-Step "Creating namespaces"

foreach ($ns in @($MonitoringNs, $AppNs)) {
    $manifest = & kubectl create namespace $ns --dry-run=client -o yaml
    Assert-ExitCode -What "kubectl create namespace $ns --dry-run=client"

    $manifest | & kubectl apply -f - | Out-Null
    Assert-ExitCode -What "kubectl apply namespace $ns"

    Write-Ok "namespace '$ns' present"
}

# ---------------------------------------------------------------------------
# Final state
# ---------------------------------------------------------------------------
Write-Step "Cluster nodes"
& kubectl get nodes -o wide
Assert-ExitCode -What 'kubectl get nodes'

Write-Step "Namespaces"
& kubectl get namespace $MonitoringNs $AppNs
Assert-ExitCode -What 'kubectl get namespace'

Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " CLUSTER READY" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " profile     : $Profile" -ForegroundColor Gray
Write-Host " driver      : $Driver" -ForegroundColor Gray
Write-Host " namespaces  : $MonitoringNs, $AppNs" -ForegroundColor Gray
Write-Host " addons      : $($Addons -join ', ')" -ForegroundColor Gray
Write-Host ""
Write-Host " NEXT STEPS" -ForegroundColor White
Write-Host "   1. .\scripts\install-stack.ps1      install Prometheus, Loki, Promtail, Tempo" -ForegroundColor Gray
Write-Host "   2. .\scripts\deploy-app.ps1         build and deploy orders-api" -ForegroundColor Gray
Write-Host "   3. .\scripts\port-forward.ps1       open Grafana / Prometheus / Alertmanager" -ForegroundColor Gray
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

<#
.SYNOPSIS
    Pre-flight environment check for the k8s-observability-stack demo.

.DESCRIPTION
    Purpose
    -------
    Verifies that this workstation can actually run the full observability stack
    (kube-prometheus-stack + Loki + Promtail + Tempo + the orders-api demo app)
    BEFORE you spend 15 minutes watching Helm time out. It checks:

      1. Required CLI tools are on PATH   : kubectl, helm, minikube, docker
      2. The Docker daemon is actually RUNNING (Docker Desktop is often stopped)
      3. Host capacity                    : >= 4 logical CPUs, >= 8 GB RAM
      4. Free disk space                  : >= 40 GB on the system drive
      5. Existing minikube profile        : reports its cpus/memory and whether it is enough
      6. kubectl can reach a cluster      : informational only, never fatal

    Usage
    -----
        .\scripts\preflight.ps1
        .\scripts\preflight.ps1 -Quiet
        .\scripts\preflight.ps1 -Help

    Parameters
    ----------
        -Quiet   Suppress the per-check narration; print only the summary table
                 and any failures. Useful from a Makefile or CI step.
        -Help    Print this usage block and exit 0.

    Prerequisites
    -------------
        Windows PowerShell 5.1 or PowerShell 7+. No admin rights required.
        If PowerShell refuses to run the script:
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

    What it changes
    ---------------
        NOTHING. This script is strictly read-only. It starts no cluster,
        installs no chart, and writes no file.

    How to undo it
    --------------
        Nothing to undo.

    Exit codes
    ----------
        0  all hard requirements satisfied (warnings may still be present)
        1  at least one hard requirement failed
        2  bad arguments

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Repo root is resolved from the script's own location so the script works no
# matter what directory the caller happens to be sitting in.
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Constants. Kept identical across every script in scripts/.
# ---------------------------------------------------------------------------
$MonitoringNs    = 'monitoring'
$AppNs           = 'demo'
$MinikubeProfile = 'minikube'

$MinCpus      = 4
$MinMemoryMb  = 8192
$MinDiskGb    = 40

# ---------------------------------------------------------------------------
# Output helpers. Every script in scripts/ uses the same five verbs so the
# console output reads consistently across the whole workflow.
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) if (-not $Quiet) { Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan } }
function Write-Ok   { param([string]$Message) if (-not $Quiet) { Write-Host "    [ OK ] $Message" -ForegroundColor Green } }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) if (-not $Quiet) { Write-Host "    $Message" -ForegroundColor DarkGray } }

function Show-Usage {
    Write-Host @"
preflight.ps1 - verify this machine can run the k8s-observability-stack demo

USAGE
    .\scripts\preflight.ps1 [-Quiet] [-Help]

PARAMETERS
    -Quiet   Only print the summary table and failures.
    -Help    Print this help and exit.

CHECKS
    kubectl / helm / minikube / docker on PATH
    Docker daemon reachable
    >= $MinCpus logical CPUs, >= $MinMemoryMb MB RAM, >= $MinDiskGb GB free disk
    Existing minikube profile sizing (if any)
    kubectl cluster reachability (informational)

EXIT CODES
    0 pass   1 hard failure   2 bad arguments
"@
}

if ($Help) { Show-Usage; exit 0 }

# ---------------------------------------------------------------------------
# Results accumulator. Each entry becomes one row of the final summary table.
# Status is one of PASS / WARN / FAIL. Only FAIL makes the script exit non-zero.
# ---------------------------------------------------------------------------
$Results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    $null = $Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

# ---------------------------------------------------------------------------
# Tool discovery. We deliberately do NOT use `$?` after Get-Command because we
# want a soft lookup; -ErrorAction SilentlyContinue returns $null when missing.
# ---------------------------------------------------------------------------
function Test-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$VersionArgs,
        [Parameter(Mandatory = $true)][string]$InstallHint
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        Write-Err "$Name not found on PATH"
        Write-Info "install with: $InstallHint"
        Add-Result -Check "$Name on PATH" -Status 'FAIL' -Detail "missing - $InstallHint"
        return $false
    }

    # Version probe. Some tools (docker) print to stderr or exit non-zero when
    # the daemon is down, so failures here are reported but not fatal: the
    # binary existing is what this particular check cares about.
    $version = '(version unavailable)'
    try {
        $raw = & $Name $VersionArgs.Split(' ') 2>&1
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $version = ($raw | Select-Object -First 1).ToString().Trim()
        }
    }
    catch {
        $version = '(version probe failed)'
    }

    # Trim the noisy kubectl/helm banners down to something table-friendly.
    if ($version.Length -gt 60) { $version = $version.Substring(0, 57) + '...' }

    Write-Ok "$Name found -> $version"
    Add-Result -Check "$Name on PATH" -Status 'PASS' -Detail $version
    return $true
}

Write-Host ""
Write-Host "k8s-observability-stack - pre-flight check" -ForegroundColor White
Write-Host "repo root: $RepoRoot" -ForegroundColor DarkGray
Write-Host "target namespaces: $MonitoringNs, $AppNs" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Required CLI tools
# ---------------------------------------------------------------------------
Write-Step "Checking required CLI tools"

$haveKubectl  = Test-Tool -Name 'kubectl'  -VersionArgs 'version --client=true -o yaml' -InstallHint 'winget install Kubernetes.kubectl'
$haveHelm     = Test-Tool -Name 'helm'     -VersionArgs 'version --short'                -InstallHint 'winget install Helm.Helm'
$haveMinikube = Test-Tool -Name 'minikube' -VersionArgs 'version --short'                -InstallHint 'winget install Kubernetes.minikube'
$haveDocker   = Test-Tool -Name 'docker'   -VersionArgs '--version'                      -InstallHint 'winget install Docker.DockerDesktop'

# k6 is intentionally NOT required: the load generator runs as a Kubernetes Job
# (load/k8s/k6-job.yaml), so nothing needs to be installed on the host.
Write-Info "k6 is not required locally - load tests run as a Kubernetes Job"

# ---------------------------------------------------------------------------
# 2. Docker daemon reachability
# ---------------------------------------------------------------------------
Write-Step "Checking the Docker daemon"

if (-not $haveDocker) {
    Write-Err "skipping daemon check because the docker CLI is missing"
    Add-Result -Check 'Docker daemon running' -Status 'FAIL' -Detail 'docker CLI missing'
}
else {
    # `docker info` is the cheapest round-trip that actually talks to the daemon.
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    $dockerExit = $LASTEXITCODE
    if ($dockerExit -ne 0) {
        Write-Err "the Docker daemon is not responding"
        Write-Info "Docker Desktop is probably not started. Open the Docker Desktop app,"
        Write-Info "wait for the whale icon in the tray to stop animating, then re-run this script."
        Write-Info "minikube --driver=docker cannot start a cluster without a running daemon."
        Add-Result -Check 'Docker daemon running' -Status 'FAIL' -Detail 'start Docker Desktop and retry'
    }
    else {
        $serverVersion = (& docker info --format '{{.ServerVersion}}' 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $serverVersion = 'unknown' }
        Write-Ok "Docker daemon reachable (server $serverVersion)"
        Add-Result -Check 'Docker daemon running' -Status 'PASS' -Detail "server $serverVersion"
    }
}

# ---------------------------------------------------------------------------
# 3. Host CPU and memory
# ---------------------------------------------------------------------------
Write-Step "Checking host capacity (need >= $MinCpus CPUs and >= $MinMemoryMb MB RAM)"

$hostCpus     = 0
$hostMemoryMb = 0
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $hostMemoryMb = [int]([math]::Floor($cs.TotalPhysicalMemory / 1MB))

    # NumberOfLogicalProcessors is per-socket; sum across sockets for the real total.
    $procs = Get-CimInstance -ClassName Win32_Processor
    foreach ($p in $procs) { $hostCpus += [int]$p.NumberOfLogicalProcessors }
    if ($hostCpus -le 0) { $hostCpus = [int]$cs.NumberOfLogicalProcessors }
}
catch {
    Write-Warn "could not query Win32_ComputerSystem / Win32_Processor: $($_.Exception.Message)"
}

if ($hostCpus -le 0) {
    Write-Warn "CPU count could not be determined"
    Add-Result -Check 'Host CPUs' -Status 'WARN' -Detail 'undetermined'
}
elseif ($hostCpus -lt $MinCpus) {
    Write-Err "only $hostCpus logical CPUs detected, need at least $MinCpus"
    Add-Result -Check 'Host CPUs' -Status 'FAIL' -Detail "$hostCpus (need $MinCpus)"
}
else {
    Write-Ok "$hostCpus logical CPUs"
    Add-Result -Check 'Host CPUs' -Status 'PASS' -Detail "$hostCpus"
}

if ($hostMemoryMb -le 0) {
    Write-Warn "RAM size could not be determined"
    Add-Result -Check 'Host RAM' -Status 'WARN' -Detail 'undetermined'
}
elseif ($hostMemoryMb -lt $MinMemoryMb) {
    Write-Err "only $hostMemoryMb MB RAM detected, need at least $MinMemoryMb MB"
    Write-Info "you can still try: .\scripts\cluster-up.ps1 -Memory 6144 (Loki/Tempo retention will suffer)"
    Add-Result -Check 'Host RAM' -Status 'FAIL' -Detail "$hostMemoryMb MB (need $MinMemoryMb MB)"
}
else {
    Write-Ok "$hostMemoryMb MB RAM"
    Add-Result -Check 'Host RAM' -Status 'PASS' -Detail "$hostMemoryMb MB"
}

# ---------------------------------------------------------------------------
# 4. Free disk space on the drive that holds the Docker data root
# ---------------------------------------------------------------------------
Write-Step "Checking free disk space (need >= $MinDiskGb GB)"

$freeGb = -1
try {
    $driveLetter = (Get-Item $env:SystemDrive).PSDrive.Name
    $drive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
    $freeGb = [int]([math]::Floor($drive.Free / 1GB))
}
catch {
    Write-Warn "could not read free space: $($_.Exception.Message)"
}

if ($freeGb -lt 0) {
    Add-Result -Check 'Free disk space' -Status 'WARN' -Detail 'undetermined'
}
elseif ($freeGb -lt $MinDiskGb) {
    Write-Err "$freeGb GB free on $env:SystemDrive, need at least $MinDiskGb GB"
    Write-Info "minikube is started with --disk-size=40g; Prometheus/Loki/Tempo PVCs live inside it."
    Add-Result -Check 'Free disk space' -Status 'FAIL' -Detail "$freeGb GB (need $MinDiskGb GB)"
}
else {
    Write-Ok "$freeGb GB free on $env:SystemDrive"
    Add-Result -Check 'Free disk space' -Status 'PASS' -Detail "$freeGb GB"
}

# ---------------------------------------------------------------------------
# 5. Existing minikube profile sizing
# ---------------------------------------------------------------------------
Write-Step "Checking for an existing minikube profile named '$MinikubeProfile'"

if (-not $haveMinikube) {
    Write-Warn "minikube CLI missing - cannot inspect existing profiles"
    Add-Result -Check 'minikube profile' -Status 'WARN' -Detail 'minikube CLI missing'
}
else {
    $profileJson = & minikube profile list -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $profileJson) {
        Write-Info "no minikube profile exists yet - run .\scripts\cluster-up.ps1 to create one"
        Add-Result -Check 'minikube profile' -Status 'WARN' -Detail 'not created yet'
    }
    else {
        try {
            $parsed = $profileJson | ConvertFrom-Json
            $valid = @()
            if ($parsed.valid) { $valid = @($parsed.valid) }

            $match = $null
            foreach ($p in $valid) {
                if ($p.Name -eq $MinikubeProfile) { $match = $p }
            }

            if ($null -eq $match) {
                Write-Info "profile '$MinikubeProfile' not found among existing profiles"
                Add-Result -Check 'minikube profile' -Status 'WARN' -Detail 'not created yet'
            }
            else {
                $pCpus   = [int]$match.Config.CPUs
                $pMemory = [int]$match.Config.Memory
                $pStatus = $match.Status
                Write-Info "profile '$MinikubeProfile' status=$pStatus cpus=$pCpus memory=${pMemory}MB"

                if ($pCpus -lt $MinCpus -or $pMemory -lt $MinMemoryMb) {
                    Write-Warn "existing profile is undersized (need $MinCpus cpus / $MinMemoryMb MB)"
                    Write-Info "recreate it with: minikube delete; .\scripts\cluster-up.ps1"
                    Add-Result -Check 'minikube profile' -Status 'WARN' -Detail "undersized: ${pCpus}cpu/${pMemory}MB"
                }
                else {
                    Write-Ok "existing profile meets the minimum (${pCpus} cpus / ${pMemory} MB, status $pStatus)"
                    Add-Result -Check 'minikube profile' -Status 'PASS' -Detail "${pCpus}cpu/${pMemory}MB $pStatus"
                }
            }
        }
        catch {
            Write-Warn "could not parse 'minikube profile list -o json' output"
            Add-Result -Check 'minikube profile' -Status 'WARN' -Detail 'unparseable'
        }
    }
}

# ---------------------------------------------------------------------------
# 6. kubectl cluster reachability - informational only.
#    A missing cluster is entirely expected before cluster-up has been run,
#    so this check can never produce a FAIL.
# ---------------------------------------------------------------------------
Write-Step "Checking kubectl connectivity (informational)"

if (-not $haveKubectl) {
    Add-Result -Check 'kubectl reaches cluster' -Status 'WARN' -Detail 'kubectl missing'
}
else {
    $null = & kubectl cluster-info --request-timeout=5s 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Info "kubectl cannot reach a cluster yet - that is normal before cluster-up"
        Add-Result -Check 'kubectl reaches cluster' -Status 'WARN' -Detail 'no cluster yet'
    }
    else {
        $ctx = (& kubectl config current-context 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $ctx) { $ctx = 'unknown' }
        Write-Ok "kubectl reaches a cluster (context: $ctx)"
        Add-Result -Check 'kubectl reaches cluster' -Status 'PASS' -Detail "context $ctx"
    }
}

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " PRE-FLIGHT SUMMARY" -ForegroundColor White
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host (" {0,-26} {1,-6} {2}" -f 'CHECK', 'STATUS', 'DETAIL') -ForegroundColor White
Write-Host " -------------------------- ------ ---------------------------------------" -ForegroundColor DarkGray

foreach ($r in $Results) {
    $colour = 'Green'
    if ($r.Status -eq 'WARN') { $colour = 'Yellow' }
    if ($r.Status -eq 'FAIL') { $colour = 'Red' }
    Write-Host (" {0,-26} {1,-6} {2}" -f $r.Check, $r.Status, $r.Detail) -ForegroundColor $colour
}

$failCount = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($Results | Where-Object { $_.Status -eq 'WARN' }).Count

Write-Host "---------------------------------------------------------------------------" -ForegroundColor White

if ($failCount -gt 0) {
    Write-Host " RESULT: FAIL ($failCount hard failure(s), $warnCount warning(s))" -ForegroundColor Red
    Write-Host " Fix the FAIL rows above, then re-run: .\scripts\preflight.ps1" -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host " RESULT: PASS ($warnCount warning(s))" -ForegroundColor Green
Write-Host " Next step: .\scripts\cluster-up.ps1" -ForegroundColor Green
Write-Host ""
exit 0

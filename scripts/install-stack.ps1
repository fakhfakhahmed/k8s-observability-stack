<#
.SYNOPSIS
    Install the full observability stack: metrics, logs and traces.

.DESCRIPTION
    Purpose
    -------
    Installs, in dependency order, everything that lives in the 'monitoring'
    namespace:

        a. Helm repos 'prometheus-community' and 'grafana', then 'helm repo update'
        b. Secret 'grafana-admin-credentials' (admin / observability)
        c. kube-prometheus-stack  -f stack/prometheus/values.yaml
        d. loki                   -f stack/loki/values.yaml
        e. promtail               -f stack/loki/promtail-values.yaml
        f. tempo                  -f stack/tempo/values.yaml
        g. PrometheusRule objects from stack/prometheus/rules/
        h. Grafana datasource + dashboard ConfigMaps (sidecar discovery)
        i. kubectl rollout status for every workload
        j. summary + next command

    Every step is idempotent. Re-running the script is the supported way to
    pick up edits to the values files or the dashboard JSON.

    Usage
    -----
        .\scripts\install-stack.ps1
        .\scripts\install-stack.ps1 -MetricsOnly
        .\scripts\install-stack.ps1 -LogsOnly
        .\scripts\install-stack.ps1 -TracesOnly
        .\scripts\install-stack.ps1 -SkipDashboards
        .\scripts\install-stack.ps1 -TimeoutMinutes 20
        .\scripts\install-stack.ps1 -Help

    Parameters
    ----------
        -MetricsOnly      install only kube-prometheus-stack (+ rules, dashboards)
        -LogsOnly         install only Loki + Promtail
        -TracesOnly       install only Tempo
        -SkipDashboards   do not create the Grafana dashboard/datasource ConfigMaps
        -TimeoutMinutes   Helm --timeout and rollout timeout in minutes (default 15)
        -Help             print usage and exit 0

        The three *Only switches are mutually exclusive. When none is given,
        everything is installed.

    Prerequisites
    -------------
        A running cluster (.\scripts\cluster-up.ps1) and helm on PATH
        (winget install Helm.Helm).

    What it changes
    ---------------
        Creates four Helm releases, one Secret, several ConfigMaps and a set of
        PrometheusRule custom resources, all in the 'monitoring' namespace.
        It also installs the Prometheus Operator CRDs cluster-wide.

    How to undo it
    --------------
        .\scripts\uninstall.ps1
        (add -DeleteCRDs to also remove the cluster-scoped CRDs)

.NOTES
    Ahmed Fakhfakh - DevOps / SRE
#>

[CmdletBinding()]
param(
    [switch]$MetricsOnly,
    [switch]$LogsOnly,
    [switch]$TracesOnly,
    [switch]$SkipDashboards,
    [int]$TimeoutMinutes = 15,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Constants - identical across every script in scripts/
# ---------------------------------------------------------------------------
$MonitoringNs = 'monitoring'
$AppNs        = 'demo'

$KpsRelease      = 'kube-prometheus-stack'
$LokiRelease     = 'loki'
$PromtailRelease = 'promtail'
$TempoRelease    = 'tempo'

$PromRepoName = 'prometheus-community'
$PromRepoUrl  = 'https://prometheus-community.github.io/helm-charts'
$GrafanaRepoName = 'grafana'
$GrafanaRepoUrl  = 'https://grafana.github.io/helm-charts'

# ---------------------------------------------------------------------------
# Chart versions are PINNED DELIBERATELY.
#
# Why: an unpinned `helm upgrade --install` silently picks up whatever is
# newest in the repo index at the moment you run it. That makes the repo
# irreproducible - a reviewer cloning this in six months would get different
# dashboards, different CRD schemas and possibly broken values keys. Pinning
# means the screenshots in docs/screenshots/ always match what the scripts
# produce.
#
# How to check for newer versions (safe, read-only):
#     helm repo update
#     helm search repo prometheus-community/kube-prometheus-stack --versions | head
#     helm search repo grafana/loki     --versions | Select-Object -First 5
#     helm search repo grafana/promtail --versions | Select-Object -First 5
#     helm search repo grafana/tempo    --versions | Select-Object -First 5
#
# How to bump: change the constant below, re-run this script, and re-check the
# values files - major chart bumps frequently rename values keys.
# ---------------------------------------------------------------------------
$KpsVersion      = '65.1.1'
$LokiVersion     = '6.16.0'
$PromtailVersion = '6.16.6'
$TempoVersion    = '1.10.3'

# Grafana admin credentials. Stored in a Secret so the values file can
# reference it via grafana.admin.existingSecret rather than hard-coding a
# password into a file that ends up on GitHub.
$GrafanaSecretName = 'grafana-admin-credentials'
$GrafanaAdminUser  = 'admin'
$GrafanaAdminPass  = 'observability'

# Paths, all relative to the repo root.
$PrometheusValues = Join-Path $RepoRoot 'stack\prometheus\values.yaml'
$LokiValues       = Join-Path $RepoRoot 'stack\loki\values.yaml'
$PromtailValues   = Join-Path $RepoRoot 'stack\loki\promtail-values.yaml'
$TempoValues      = Join-Path $RepoRoot 'stack\tempo\values.yaml'
$RulesDir         = Join-Path $RepoRoot 'stack\prometheus\rules'
$DatasourcesFile  = Join-Path $RepoRoot 'stack\grafana\datasources\datasources.yaml'
$DashboardsDir    = Join-Path $RepoRoot 'stack\grafana\dashboards\json'

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Show-Usage {
    Write-Host @"
install-stack.ps1 - install Prometheus, Loki, Promtail and Tempo into '$MonitoringNs'

USAGE
    .\scripts\install-stack.ps1 [-MetricsOnly|-LogsOnly|-TracesOnly]
                                [-SkipDashboards] [-TimeoutMinutes <int>] [-Help]

PARAMETERS
    -MetricsOnly      only kube-prometheus-stack (plus rules and dashboards)
    -LogsOnly         only Loki + Promtail
    -TracesOnly       only Tempo
    -SkipDashboards   skip the Grafana datasource/dashboard ConfigMaps
    -TimeoutMinutes   Helm and rollout timeout, minutes (default 15)
    -Help             print this help and exit

PINNED CHART VERSIONS
    kube-prometheus-stack  $KpsVersion
    loki                   $LokiVersion
    promtail               $PromtailVersion
    tempo                  $TempoVersion
"@
}

if ($Help) { Show-Usage; exit 0 }

# ---------------------------------------------------------------------------
# PowerShell does not trap non-zero exit codes from native executables, so
# every helm/kubectl invocation is followed by one of these.
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

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Purpose
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Err "required file not found: $Path"
        Write-Info "needed for: $Purpose"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Wait for a workload to finish rolling out. The workload is looked up first
# so that a chart that renames a resource between versions produces a clear
# warning rather than a hard failure halfway through the install.
# ---------------------------------------------------------------------------
function Wait-Rollout {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('deployment', 'statefulset', 'daemonset')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Namespace = $MonitoringNs,
        [int]$TimeoutSeconds = 600
    )

    $null = & kubectl get $Kind $Name -n $Namespace 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "$Kind/$Name not found in '$Namespace' - skipping rollout wait"
        return
    }

    Write-Info "waiting for $Kind/$Name ..."
    & kubectl rollout status "$Kind/$Name" -n $Namespace --timeout="${TimeoutSeconds}s" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Kind/$Name did not become ready within ${TimeoutSeconds}s"
        Write-Info "inspect with: kubectl -n $Namespace describe $Kind $Name"
        Write-Info "and:          kubectl -n $Namespace get pods"
        exit 1
    }
    Write-Ok "$Kind/$Name ready"
}

# ---------------------------------------------------------------------------
# Decide which layers to install.
# ---------------------------------------------------------------------------
$onlyFlags = @($MetricsOnly, $LogsOnly, $TracesOnly) | Where-Object { $_ }
if ($onlyFlags.Count -gt 1) {
    Write-Err "-MetricsOnly, -LogsOnly and -TracesOnly are mutually exclusive"
    exit 2
}

$doMetrics = $true
$doLogs    = $true
$doTraces  = $true
if ($MetricsOnly) { $doLogs = $false; $doTraces = $false }
if ($LogsOnly)    { $doMetrics = $false; $doTraces = $false }
if ($TracesOnly)  { $doMetrics = $false; $doLogs = $false }

$HelmTimeout    = "${TimeoutMinutes}m"
$RolloutSeconds = $TimeoutMinutes * 60

Write-Host ""
Write-Host "k8s-observability-stack - install-stack" -ForegroundColor White
Write-Host "repo root : $RepoRoot" -ForegroundColor DarkGray
Write-Host "namespace : $MonitoringNs" -ForegroundColor DarkGray
Write-Host "layers    : metrics=$doMetrics logs=$doLogs traces=$doTraces dashboards=$(-not $SkipDashboards)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

foreach ($tool in @('helm', 'kubectl')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Err "$tool not found on PATH"
        if ($tool -eq 'helm') { Write-Info "install with: winget install Helm.Helm" }
        exit 1
    }
    Write-Ok "$tool found"
}

$null = & kubectl cluster-info --request-timeout=10s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "kubectl cannot reach a cluster"
    Write-Info "run .\scripts\cluster-up.ps1 first"
    exit 1
}
Write-Ok "cluster reachable"

# Namespace must exist before the Secret is created; --create-namespace on the
# Helm call would be too late for step (b).
$manifest = & kubectl create namespace $MonitoringNs --dry-run=client -o yaml
Assert-ExitCode -What "kubectl create namespace $MonitoringNs --dry-run=client"
$manifest | & kubectl apply -f - | Out-Null
Assert-ExitCode -What "kubectl apply namespace $MonitoringNs"
Write-Ok "namespace '$MonitoringNs' present"

# ---------------------------------------------------------------------------
# (a) Helm repositories
# ---------------------------------------------------------------------------
Write-Step "Adding Helm repositories"

# `helm repo add --force-update` is the idempotent form: it rewrites the entry
# instead of failing with "repository name already exists".
& helm repo add $PromRepoName $PromRepoUrl --force-update | Out-Null
Assert-ExitCode -What "helm repo add $PromRepoName"
Write-Ok "$PromRepoName -> $PromRepoUrl"

& helm repo add $GrafanaRepoName $GrafanaRepoUrl --force-update | Out-Null
Assert-ExitCode -What "helm repo add $GrafanaRepoName"
Write-Ok "$GrafanaRepoName -> $GrafanaRepoUrl"

& helm repo update $PromRepoName $GrafanaRepoName | Out-Null
Assert-ExitCode -What 'helm repo update'
Write-Ok "repo indexes refreshed"

# ---------------------------------------------------------------------------
# (b) Grafana admin Secret
#
# The create/--dry-run=client/apply pipeline is the idempotent way to manage a
# Secret imperatively: `kubectl create secret` alone fails on the second run,
# and `kubectl apply` alone cannot build the Secret from literals.
# ---------------------------------------------------------------------------
Write-Step "Creating the Grafana admin Secret '$GrafanaSecretName'"

$secretYaml = & kubectl create secret generic $GrafanaSecretName `
    --namespace $MonitoringNs `
    --from-literal=admin-user=$GrafanaAdminUser `
    --from-literal=admin-password=$GrafanaAdminPass `
    --dry-run=client -o yaml
Assert-ExitCode -What "kubectl create secret $GrafanaSecretName --dry-run=client"

$secretYaml | & kubectl apply -f - | Out-Null
Assert-ExitCode -What "kubectl apply secret $GrafanaSecretName"
Write-Ok "Secret '$GrafanaSecretName' present (user '$GrafanaAdminUser')"

# ---------------------------------------------------------------------------
# (c) kube-prometheus-stack
# ---------------------------------------------------------------------------
if ($doMetrics) {
    Write-Step "Installing $KpsRelease (chart version $KpsVersion)"
    Assert-FileExists -Path $PrometheusValues -Purpose 'kube-prometheus-stack values'

    Write-Info "this pulls Prometheus, Alertmanager, Grafana, node-exporter and kube-state-metrics"
    Write-Info "first install typically takes 3-8 minutes"

    & helm upgrade --install $KpsRelease "$PromRepoName/kube-prometheus-stack" `
        --version $KpsVersion `
        --namespace $MonitoringNs `
        --create-namespace `
        -f $PrometheusValues `
        --wait `
        --timeout $HelmTimeout
    Assert-ExitCode -What "helm upgrade --install $KpsRelease" `
        -Hint "inspect with: kubectl -n $MonitoringNs get pods ; helm -n $MonitoringNs status $KpsRelease"
    Write-Ok "$KpsRelease installed"
}
else {
    Write-Info "skipping $KpsRelease (metrics layer disabled)"
}

# ---------------------------------------------------------------------------
# (d) Loki
# ---------------------------------------------------------------------------
if ($doLogs) {
    Write-Step "Installing $LokiRelease (chart version $LokiVersion)"
    Assert-FileExists -Path $LokiValues -Purpose 'Loki values'

    & helm upgrade --install $LokiRelease "$GrafanaRepoName/loki" `
        --version $LokiVersion `
        --namespace $MonitoringNs `
        --create-namespace `
        -f $LokiValues `
        --wait `
        --timeout $HelmTimeout
    Assert-ExitCode -What "helm upgrade --install $LokiRelease" `
        -Hint "a common cause is a PVC stuck Pending - check: kubectl -n $MonitoringNs get pvc"
    Write-Ok "$LokiRelease installed (push/query at http://loki.$MonitoringNs.svc.cluster.local:3100)"

    # ---------------------------------------------------------------------------
    # (e) Promtail - the log shipper. It must come after Loki so its push target
    # already resolves; otherwise its first few batches land in a retry loop.
    # ---------------------------------------------------------------------------
    Write-Step "Installing $PromtailRelease (chart version $PromtailVersion)"
    Assert-FileExists -Path $PromtailValues -Purpose 'Promtail values'

    & helm upgrade --install $PromtailRelease "$GrafanaRepoName/promtail" `
        --version $PromtailVersion `
        --namespace $MonitoringNs `
        --create-namespace `
        -f $PromtailValues `
        --wait `
        --timeout $HelmTimeout
    Assert-ExitCode -What "helm upgrade --install $PromtailRelease"
    Write-Ok "$PromtailRelease installed (DaemonSet tailing /var/log/pods)"
}
else {
    Write-Info "skipping $LokiRelease and $PromtailRelease (logs layer disabled)"
}

# ---------------------------------------------------------------------------
# (f) Tempo
# ---------------------------------------------------------------------------
if ($doTraces) {
    Write-Step "Installing $TempoRelease (chart version $TempoVersion)"
    Assert-FileExists -Path $TempoValues -Purpose 'Tempo values'

    & helm upgrade --install $TempoRelease "$GrafanaRepoName/tempo" `
        --version $TempoVersion `
        --namespace $MonitoringNs `
        --create-namespace `
        -f $TempoValues `
        --wait `
        --timeout $HelmTimeout
    Assert-ExitCode -What "helm upgrade --install $TempoRelease"
    Write-Ok "$TempoRelease installed (OTLP gRPC at tempo.$MonitoringNs.svc.cluster.local:4317)"
}
else {
    Write-Info "skipping $TempoRelease (traces layer disabled)"
}

# ---------------------------------------------------------------------------
# (g) PrometheusRule objects
#
# These are plain CRs, so `kubectl apply` is already idempotent. They are
# applied after kube-prometheus-stack because the PrometheusRule CRD only
# exists once the Prometheus Operator has been installed.
# ---------------------------------------------------------------------------
if ($doMetrics) {
    Write-Step "Applying PrometheusRule objects from stack/prometheus/rules/"

    if (-not (Test-Path -LiteralPath $RulesDir)) {
        Write-Warn "rules directory not found: $RulesDir - skipping"
    }
    else {
        $ruleFiles = @(Get-ChildItem -LiteralPath $RulesDir -Filter '*.yaml' -File | Sort-Object Name)
        if ($ruleFiles.Count -eq 0) {
            Write-Warn "no .yaml files under $RulesDir"
        }
        else {
            foreach ($rf in $ruleFiles) {
                & kubectl apply -n $MonitoringNs -f $rf.FullName | Out-Null
                Assert-ExitCode -What "kubectl apply -f $($rf.Name)" `
                    -Hint "if this says 'no matches for kind PrometheusRule', install the metrics layer first"
                Write-Ok "applied $($rf.Name)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# (h) Grafana datasources and dashboards
#
# The Grafana chart runs two sidecar containers that watch ConfigMaps in the
# namespace and drop their contents into Grafana's provisioning directories:
#     label grafana_datasource=1  ->  /etc/grafana/provisioning/datasources
#     label grafana_dashboard=1   ->  /etc/grafana/provisioning/dashboards
# That is why the label matters far more than the ConfigMap name.
# ---------------------------------------------------------------------------
if ($SkipDashboards) {
    Write-Info "skipping Grafana datasource/dashboard ConfigMaps (-SkipDashboards)"
}
else {
    Write-Step "Creating the Grafana datasource ConfigMap"

    if (-not (Test-Path -LiteralPath $DatasourcesFile)) {
        Write-Warn "datasource file not found: $DatasourcesFile - skipping"
    }
    else {
        $dsYaml = & kubectl create configmap grafana-datasources `
            --namespace $MonitoringNs `
            --from-file="datasources.yaml=$DatasourcesFile" `
            --dry-run=client -o yaml
        Assert-ExitCode -What 'kubectl create configmap grafana-datasources --dry-run=client'

        # `kubectl label --local` edits the YAML in flight without touching the
        # cluster, so the final apply ships both data and label in one object.
        $dsLabelled = $dsYaml | & kubectl label --local -f - grafana_datasource=1 -o yaml
        Assert-ExitCode -What 'kubectl label --local grafana_datasource=1'

        $dsLabelled | & kubectl apply -f - | Out-Null
        Assert-ExitCode -What 'kubectl apply configmap grafana-datasources'
        Write-Ok "ConfigMap 'grafana-datasources' applied (uids: prometheus, loki, tempo)"
    }

    Write-Step "Creating one ConfigMap per Grafana dashboard"

    if (-not (Test-Path -LiteralPath $DashboardsDir)) {
        Write-Warn "dashboard directory not found: $DashboardsDir - skipping"
    }
    else {
        $jsonFiles = @(Get-ChildItem -LiteralPath $DashboardsDir -Filter '*.json' -File | Sort-Object Name)
        if ($jsonFiles.Count -eq 0) {
            Write-Warn "no .json files under $DashboardsDir"
        }
        else {
            foreach ($jf in $jsonFiles) {
                # grafana-dashboard-app-red-metrics, grafana-dashboard-slo-error-budget, ...
                $cmName = 'grafana-dashboard-' + $jf.BaseName.ToLower()

                $cmYaml = & kubectl create configmap $cmName `
                    --namespace $MonitoringNs `
                    --from-file="$($jf.Name)=$($jf.FullName)" `
                    --dry-run=client -o yaml
                Assert-ExitCode -What "kubectl create configmap $cmName --dry-run=client"

                $cmLabelled = $cmYaml | & kubectl label --local -f - grafana_dashboard=1 -o yaml
                Assert-ExitCode -What "kubectl label --local grafana_dashboard=1 ($cmName)"

                $cmLabelled | & kubectl apply -f - | Out-Null
                Assert-ExitCode -What "kubectl apply configmap $cmName"

                Write-Ok "$cmName  <- $($jf.Name)"
            }
            Write-Info "the Grafana sidecar picks these up within ~30 seconds; no restart needed"
        }
    }
}

# ---------------------------------------------------------------------------
# (i) Rollout waits
#
# `helm --wait` already blocks, but it only waits on the resources that Helm
# itself owns and it reports a single opaque timeout. An explicit per-workload
# rollout wait pinpoints exactly which component is unhealthy.
# ---------------------------------------------------------------------------
Write-Step "Waiting for workloads to become ready"

if ($doMetrics) {
    Wait-Rollout -Kind 'deployment'  -Name "$KpsRelease-grafana"              -TimeoutSeconds $RolloutSeconds
    Wait-Rollout -Kind 'deployment'  -Name "$KpsRelease-kube-state-metrics"   -TimeoutSeconds $RolloutSeconds
    Wait-Rollout -Kind 'deployment'  -Name "$KpsRelease-operator"             -TimeoutSeconds $RolloutSeconds
    Wait-Rollout -Kind 'daemonset'   -Name "$KpsRelease-prometheus-node-exporter" -TimeoutSeconds $RolloutSeconds
    Wait-Rollout -Kind 'statefulset' -Name "prometheus-$KpsRelease-prometheus"     -TimeoutSeconds $RolloutSeconds
    Wait-Rollout -Kind 'statefulset' -Name "alertmanager-$KpsRelease-alertmanager" -TimeoutSeconds $RolloutSeconds
}
if ($doLogs) {
    # The Loki chart in SingleBinary deployment mode produces statefulset/loki.
    Wait-Rollout -Kind 'statefulset' -Name $LokiRelease     -TimeoutSeconds $RolloutSeconds
    Wait-Rollout -Kind 'daemonset'   -Name $PromtailRelease -TimeoutSeconds $RolloutSeconds
}
if ($doTraces) {
    Wait-Rollout -Kind 'statefulset' -Name $TempoRelease -TimeoutSeconds $RolloutSeconds
}

# ---------------------------------------------------------------------------
# (j) Summary
# ---------------------------------------------------------------------------
Write-Step "Installed Helm releases in '$MonitoringNs'"
& helm list --namespace $MonitoringNs
if ($LASTEXITCODE -ne 0) { Write-Warn "helm list returned $LASTEXITCODE" }

Write-Host ""
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host " OBSERVABILITY STACK INSTALLED" -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host (" {0,-24} {1,-10} {2}" -f 'COMPONENT', 'VERSION', 'ROLE') -ForegroundColor White
Write-Host " ------------------------ ---------- ---------------------------------------" -ForegroundColor DarkGray
if ($doMetrics) {
    Write-Host (" {0,-24} {1,-10} {2}" -f $KpsRelease, $KpsVersion, 'metrics, alerting, Grafana') -ForegroundColor Gray
}
if ($doLogs) {
    Write-Host (" {0,-24} {1,-10} {2}" -f $LokiRelease, $LokiVersion, 'log storage and LogQL') -ForegroundColor Gray
    Write-Host (" {0,-24} {1,-10} {2}" -f $PromtailRelease, $PromtailVersion, 'log shipper (DaemonSet)') -ForegroundColor Gray
}
if ($doTraces) {
    Write-Host (" {0,-24} {1,-10} {2}" -f $TempoRelease, $TempoVersion, 'distributed traces (OTLP)') -ForegroundColor Gray
}
Write-Host ""
Write-Host " Grafana login : $GrafanaAdminUser / $GrafanaAdminPass" -ForegroundColor Gray
Write-Host " Secret        : $GrafanaSecretName (ns $MonitoringNs)" -ForegroundColor Gray
Write-Host ""
Write-Host " NEXT STEPS" -ForegroundColor White
Write-Host "   1. .\scripts\deploy-app.ps1     build and deploy orders-api into '$AppNs'" -ForegroundColor Gray
Write-Host "   2. .\scripts\port-forward.ps1   open Grafana on http://localhost:3000" -ForegroundColor Gray
Write-Host "   3. .\scripts\trigger-incident.ps1   run the SLO burn-rate demo" -ForegroundColor Gray
Write-Host "---------------------------------------------------------------------------" -ForegroundColor White
Write-Host ""
exit 0

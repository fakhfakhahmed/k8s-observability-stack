# Getting Started

Zero to three working dashboards, a firing alert and a trace-to-log correlation, on a
Windows 11 laptop running Docker Desktop and minikube.

Every step is given **PowerShell first, bash second**. Pick one column and stay in it. Each
step ends with an `Expected output` block — if what you see differs materially, stop and
check [`troubleshooting.md`](troubleshooting.md) before continuing, because every later
step assumes the previous one actually worked.

---

## How long does this take

| Step | What | First run | Repeat run |
|---|---|---|---|
| 0 | Install prerequisites (helm, k6 optional) | 3–5 min | 0 |
| 1 | Preflight checks | 30 s | 30 s |
| 2 | `minikube start` | 4–6 min | 1–2 min |
| 3 | `helm repo add` + `helm upgrade --install` the stack | 6–10 min (image pulls) | 2–3 min |
| 4 | Build `orders-api:0.1.0` into minikube's Docker daemon | 2–3 min | 40 s |
| 5 | Deploy the app, wait for Ready | 1 min | 30 s |
| 6 | Port-forward all four UIs | 10 s | 10 s |
| 7 | Log into Grafana, verify datasources | 2 min | 1 min |
| 8 | Verify Prometheus targets | 2 min | 1 min |
| 9 | Run the k6 load test Job | 5 min (it runs 5 min) | 5 min |
| 10 | Watch dashboards populate | 3 min | 3 min |
| 11 | Trigger an incident and watch the alert fire | 8–12 min (burn-rate windows) | 8–12 min |
| | **Total wall clock** | **~40–55 min** | **~25 min** |

The long pole on a first run is image pulls (roughly 2.5 GiB across Prometheus, Grafana,
Loki, Tempo and their sidecars). Step 11 is slow by design — the 14.4x burn-rate rung needs
real minutes of bad traffic before it is honest about firing.

---

## Step 0 — Prerequisites

You need, already installed: **Docker Desktop** (running, with the WSL2 backend),
**kubectl**, **git**. You very likely do **not** have `helm` yet, and you do not need `k6`
locally because the load test runs as a Kubernetes Job.

### PowerShell

```powershell
# Verify what you already have.
docker version --format '{{.Server.Version}}'
kubectl version --client -o yaml | Select-String gitVersion
minikube version

# Install Helm (this is the one you are probably missing).
winget install Helm.Helm

# Optional: a local k6 for ad-hoc scripting. NOT required — the repo runs k6 as a k8s Job.
winget install k6.k6

# Reload PATH in the current session so 'helm' resolves without reopening the terminal.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [System.Environment]::GetEnvironmentVariable("Path","User")

helm version --short
```

### bash

```bash
docker version --format '{{.Server.Version}}'
kubectl version --client -o yaml | grep gitVersion
minikube version

# Linux/macOS equivalent of the winget line above.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version --short
```

**Expected output**

```text
28.3.2
  gitVersion: v1.31.1
minikube version: v1.34.0
commit: 5bd4e7d1a7a9d5e8f1d1c2b3a4958677d8e9f0a1

Found an existing package already installed. Trying to upgrade...
Successfully installed Helm.Helm

version.BuildInfo{Version:"v3.16.2", GitCommit:"13654a5...", GoVersion:"go1.22.7"}
helm v3.16.2+g13654a5
```

Minimum versions that matter: Helm **3.12+** (the chart uses `lookup` and modern
`--set-json` behaviour), kubectl **1.28+**, minikube **1.32+**.

---

## Step 1 — Preflight

The preflight script checks tool versions, Docker daemon health, free disk, free RAM, and
whether ports 3000/9090/9093/8080 are already bound by something else. Run it before you
burn five minutes on a cluster that cannot fit the stack.

### PowerShell

```powershell
cd C:\Users\fakhf\OneDrive\Desktop\works\DevOps\k8s-observability-stack
.\scripts\preflight.ps1
```

### bash

```bash
cd ~/k8s-observability-stack
./scripts/preflight.sh
# or:
make preflight
```

**Expected output**

```text
=== k8s-observability-stack preflight ===
[ OK ]  docker          28.3.2            (daemon responding)
[ OK ]  kubectl         v1.31.1
[ OK ]  minikube        v1.34.0
[ OK ]  helm            v3.16.2
[ OK ]  git             2.47.0
[ OK ]  host memory     31.7 GiB total, 19.2 GiB available   (need 8 GiB)
[ OK ]  host cpu        16 logical cores                      (need 4)
[ OK ]  free disk       214 GiB on C:                         (need 40 GiB)
[ OK ]  port 3000       free
[ OK ]  port 9090       free
[ OK ]  port 9093       free
[ OK ]  port 8080       free
[WARN]  k6              not installed locally (optional - load test runs as a k8s Job)

preflight: 11 ok, 1 warning, 0 errors
Ready to run: make cluster-up
```

A `[FAIL]` on memory or disk is fatal — lower `--memory` is not a workaround, Prometheus
will be OOMKilled minutes into the first load test. A `[FAIL]` on a port means something
else is bound to it; find it with `Get-NetTCPConnection -LocalPort 3000` (PowerShell) or
`ss -lntp | grep 3000` (bash).

---

## Step 2 — Start the cluster

### PowerShell

```powershell
.\scripts\cluster-up.ps1
# which wraps:
#   minikube start --cpus=4 --memory=8192 --disk-size=40g --driver=docker
#   minikube addons enable metrics-server
```

### bash

```bash
./scripts/cluster-up.sh
# or:
make cluster-up
```

**Expected output**

```text
* minikube v1.34.0 on Microsoft Windows 11 Pro 10.0.26300 Build 26300
* Using the docker driver based on user configuration
* Using Docker Desktop driver with root privileges
* Starting "minikube" primary control-plane node in "minikube" cluster
* Pulling base image v0.0.45 ...
* Creating docker container (CPUs=4, Memory=8192MB) ...
* Preparing Kubernetes v1.31.0 on Docker 27.2.0 ...
  - Generating certificates and keys ...
  - Booting up control plane ...
  - Configuring RBAC rules ...
* Configuring bridge CNI (Container Networking Interface) ...
* Verifying Kubernetes components...
  - Using image gcr.io/k8s-minikube/storage-provisioner:v5
* Enabled addons: storage-provisioner, default-storageclass, metrics-server
* Done! kubectl is now configured to use "minikube" cluster and "default" namespace

NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   38s   v1.31.0
```

Sanity check the node has the resources you asked for:

```powershell
kubectl describe node minikube | Select-String -Pattern "cpu:|memory:" -Context 0,0
```

```bash
kubectl describe node minikube | grep -E "^\s+(cpu|memory):"
```

**Expected output**

```text
  cpu:                4
  memory:             8039964Ki
  cpu:                4
  memory:             8039964Ki
```

Two pairs is correct — the first is `Capacity`, the second is `Allocatable`.

---

## Step 3 — Install the observability stack

This adds the two Helm repos and installs four releases into namespace `monitoring`:
`kube-prometheus-stack`, `loki`, `promtail`, `tempo`.

### PowerShell

```powershell
.\scripts\install-stack.ps1
# which wraps, in order:
#   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#   helm repo add grafana https://grafana.github.io/helm-charts
#   helm repo update
#   kubectl create namespace monitoring
#   helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
#     -n monitoring -f stack/prometheus/values.yaml --wait --timeout 10m
#   helm upgrade --install loki grafana/loki -n monitoring -f stack/loki/values.yaml --wait
#   helm upgrade --install promtail grafana/promtail -n monitoring -f stack/loki/promtail-values.yaml --wait
#   helm upgrade --install tempo grafana/tempo -n monitoring -f stack/tempo/values.yaml --wait
```

### bash

```bash
./scripts/install-stack.sh
# or, piecewise:
make install-metrics    # kube-prometheus-stack
make install-logs       # loki + promtail
make install-traces     # tempo
# or all three:
make install
```

**Expected output**

```text
"prometheus-community" has been added to your repositories
"grafana" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
Update Complete. Happy Helming!
namespace/monitoring created

Release "kube-prometheus-stack" does not exist. Installing it now.
NAME: kube-prometheus-stack
LAST DEPLOYED: Fri Oct 17 14:12:07 2026
NAMESPACE: monitoring
STATUS: deployed
REVISION: 1
NOTES:
kube-prometheus-stack has been installed. Check its status by running:
  kubectl --namespace monitoring get pods -l "release=kube-prometheus-stack"

Release "loki" does not exist. Installing it now.
NAME: loki
STATUS: deployed
REVISION: 1

Release "promtail" does not exist. Installing it now.
NAME: promtail
STATUS: deployed
REVISION: 1

Release "tempo" does not exist. Installing it now.
NAME: tempo
STATUS: deployed
REVISION: 1

install-stack: 4 releases deployed to namespace monitoring
```

Now confirm every pod actually reached `Running`:

```powershell
kubectl get pods -n monitoring
```

```bash
kubectl get pods -n monitoring
```

**Expected output**

```text
NAME                                                        READY   STATUS    RESTARTS   AGE
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0          4m12s
kube-prometheus-stack-grafana-7c9f4b6d58-2xk4p              3/3     Running   0          4m30s
kube-prometheus-stack-kube-state-metrics-6b7d9c4f8d-ql2wr   1/1     Running   0          4m30s
kube-prometheus-stack-operator-5d8c7b9f44-m6rtn             1/1     Running   0          4m30s
kube-prometheus-stack-prometheus-node-exporter-h4zxv        1/1     Running   0          4m30s
loki-0                                                      1/1     Running   0          2m51s
loki-canary-8kt9w                                           1/1     Running   0          2m51s
loki-gateway-5f7c8d9b64-rz7qm                               1/1     Running   0          2m51s
promtail-nxw2d                                              1/1     Running   0          2m18s
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          4m05s
tempo-0                                                     1/1     Running   0          1m44s
```

Eleven pods, all `Running`, zero restarts. The `2/2` on Prometheus and Alertmanager is the
app plus its `config-reloader` sidecar; Grafana's `3/3` is Grafana plus the dashboard and
datasource sidecars that watch for labelled ConfigMaps. If anything is `Pending`, you are
out of memory — see
[Troubleshooting: minikube resource exhaustion](troubleshooting.md#pods-stuck-pending-with-01-nodes-are-available-insufficient-memory).

---

## Step 4 — Build the application image into minikube

minikube runs its own Docker daemon inside the node container. An image built on your host
Docker is invisible to it. You must point your shell's Docker client at minikube's daemon
**before** building, which is why `imagePullPolicy: IfNotPresent` works with a purely local
tag and no registry.

### PowerShell

```powershell
# Point this shell at minikube's internal Docker daemon.
& minikube -p minikube docker-env --shell powershell | Invoke-Expression

# Confirm you are talking to the right daemon: the context should now be minikube's.
docker info --format '{{.Name}}'

# Build. The tag must match the Deployment exactly.
docker build -t orders-api:0.1.0 .\app

# Verify the image is present INSIDE minikube.
docker images orders-api
```

### bash

```bash
eval $(minikube -p minikube docker-env)
docker info --format '{{.Name}}'
docker build -t orders-api:0.1.0 ./app
docker images orders-api
```

**Expected output**

```text
minikube

[+] Building 71.3s (14/14) FINISHED                               docker:default
 => [internal] load build definition from Dockerfile                        0.1s
 => [internal] load metadata for docker.io/library/golang:1.23-alpine       1.9s
 => [builder 1/6] FROM docker.io/library/golang:1.23-alpine                24.6s
 => [builder 4/6] RUN go mod download                                      28.4s
 => [builder 6/6] RUN CGO_ENABLED=0 go build -ldflags="-s -w \
      -X main.version=0.1.0 -X main.commit=9f3a2c1" -o /out/orders-api ./   12.8s
 => [stage-1 2/3] COPY --from=builder /out/orders-api /usr/local/bin/        0.3s
 => exporting to image                                                      0.4s
 => => naming to docker.io/library/orders-api:0.1.0                         0.0s

REPOSITORY   TAG       IMAGE ID       CREATED         SIZE
orders-api   0.1.0     a7d41e93b2c8   4 seconds ago   16.8MB
```

If `docker info --format '{{.Name}}'` prints `docker-desktop` instead of `minikube`, the
`docker-env` line did not take effect in this shell. Re-run it; do not continue, or you
will get `ErrImageNeverPull` in step 5.

> Note: `docker-env` only affects the **current shell**. A new terminal talks to Docker
> Desktop again. This is the single most common cause of "but I built the image".

---

## Step 5 — Deploy the application

### PowerShell

```powershell
.\scripts\deploy-app.ps1
# which wraps:
#   kubectl create namespace demo
#   kubectl apply -f app/k8s/
#   kubectl rollout status deployment/orders-api -n demo --timeout=120s
```

### bash

```bash
./scripts/deploy-app.sh
# or:
make deploy-app
```

**Expected output**

```text
namespace/demo created
deployment.apps/orders-api created
service/orders-api created
servicemonitor.monitoring.coreos.com/orders-api created
configmap/orders-api-config created
Waiting for deployment "orders-api" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "orders-api" rollout to finish: 1 of 2 updated replicas are available...
deployment "orders-api" successfully rolled out
```

Confirm the pods and that the ServiceMonitor exists with the right release label:

```powershell
kubectl get pods,svc,servicemonitor -n demo
kubectl get servicemonitor orders-api -n demo -o jsonpath='{.metadata.labels}'
```

```bash
kubectl get pods,svc,servicemonitor -n demo
kubectl get servicemonitor orders-api -n demo -o jsonpath='{.metadata.labels}'; echo
```

**Expected output**

```text
NAME                              READY   STATUS    RESTARTS   AGE
pod/orders-api-5c7b9d8f64-7q2mz   1/1     Running   0          48s
pod/orders-api-5c7b9d8f64-xk9bt   1/1     Running   0          48s

NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/orders-api   ClusterIP   10.102.47.113   <none>        8080/TCP   48s

NAME                                            AGE
servicemonitor.monitoring.coreos.com/orders-api 48s

{"app.kubernetes.io/name":"orders-api","app.kubernetes.io/part-of":"k8s-observability-stack","release":"kube-prometheus-stack"}
```

That `"release":"kube-prometheus-stack"` label is load-bearing. Without it the default
chart's `serviceMonitorSelector` will not match and your target never appears. See
[Troubleshooting: ServiceMonitor not discovered](troubleshooting.md#servicemonitor-not-discovered-target-never-appears-in-prometheus).

---

## Step 6 — Port-forward the UIs

### PowerShell

```powershell
# Opens four background jobs, one per UI, and prints the URLs.
.\scripts\port-forward.ps1
```

### bash

```bash
./scripts/port-forward.sh
# or:
make port-forward
```

**Expected output**

```text
Starting port-forwards (Ctrl+C in this window stops all of them)

  Grafana        http://localhost:3000    svc/kube-prometheus-stack-grafana       80 -> 3000
  Prometheus     http://localhost:9090    svc/kube-prometheus-stack-prometheus  9090 -> 9090
  Alertmanager   http://localhost:9093    svc/kube-prometheus-stack-alertmanager 9093 -> 9093
  orders-api     http://localhost:8080    svc/orders-api                        8080 -> 8080

Grafana login: admin / observability

Forwarding from 127.0.0.1:3000 -> 3000
Forwarding from 127.0.0.1:9090 -> 9090
Forwarding from 127.0.0.1:9093 -> 9093
Forwarding from 127.0.0.1:8080 -> 8080
```

Smoke-test the app through the forward before you trust anything downstream:

```powershell
curl.exe -s http://localhost:8080/healthz
curl.exe -s http://localhost:8080/api/orders
curl.exe -s http://localhost:8080/metrics | Select-String -Pattern "^http_requests_total" | Select-Object -First 3
```

```bash
curl -s http://localhost:8080/healthz; echo
curl -s http://localhost:8080/api/orders; echo
curl -s http://localhost:8080/metrics | grep '^http_requests_total' | head -3
```

**Expected output**

```text
{"status":"ok"}
{"orders":[{"id":"ord-1042","value_euros":87.40,"status":"success"}],"count":1}
http_requests_total{method="GET",route="/healthz",status="200"} 14
http_requests_total{method="GET",route="/api/orders",status="200"} 1
http_requests_total{method="GET",route="/metrics",status="200"} 0
```

Note the `route` label values are low-cardinality **templates**, not raw paths. That is
deliberate; see the cardinality discussion in
[`promql-cookbook.md`](promql-cookbook.md).

---

## Step 7 — Open Grafana and verify the datasources

Browse to **http://localhost:3000**, log in with `admin` / `observability`.

The credentials come from the Kubernetes Secret `grafana-admin-credentials` in namespace
`monitoring`, keys `admin-user` and `admin-password`. To read them back:

```powershell
$u = kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}'
$p = kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($u))
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
```

```bash
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**Expected output**

```text
admin
observability
```

Now verify all three datasources answer. Use the HTTP API rather than clicking "Save & test"
three times:

```powershell
$h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:observability")) }
foreach ($uid in @("prometheus","loki","tempo")) {
  $ds = Invoke-RestMethod -Headers $h -Uri "http://localhost:3000/api/datasources/uid/$uid"
  "{0,-12} {1,-12} {2}" -f $ds.uid, $ds.type, $ds.url
}
```

```bash
for uid in prometheus loki tempo; do
  curl -su admin:observability "http://localhost:3000/api/datasources/uid/$uid" \
    | jq -r '[.uid, .type, .url] | @tsv'
done
```

**Expected output**

```text
prometheus   prometheus   http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
loki         loki         http://loki.monitoring.svc.cluster.local:3100
tempo        tempo        http://tempo.monitoring.svc.cluster.local:3200
```

Fixed UIDs (`prometheus`, `loki`, `tempo`) are what the provisioned dashboard JSON
references. If these come back as random strings, the datasource provisioning did not
apply and every dashboard will render "Datasource not found".

Confirm the four dashboards were provisioned:

```powershell
Invoke-RestMethod -Headers $h -Uri "http://localhost:3000/api/search?type=dash-db" |
  Select-Object uid, title | Format-Table -AutoSize
```

```bash
curl -su admin:observability "http://localhost:3000/api/search?type=dash-db" \
  | jq -r '.[] | [.uid, .title] | @tsv'
```

**Expected output**

```text
uid              title
---              -----
obs-app-red      Orders API — RED Metrics
obs-slo-budget   Orders API — SLO & Error Budget
obs-k8s-cluster  Kubernetes — Cluster Health
obs-logs-explorer Orders API — Logs Explorer
```

---

## Step 8 — Verify Prometheus targets

Browse to **http://localhost:9090/targets**. You want `orders-api` present and `UP`.
From the CLI:

```powershell
$t = Invoke-RestMethod -Uri "http://localhost:9090/api/v1/targets?state=active"
$t.data.activeTargets |
  Select-Object @{n='job';e={$_.labels.job}}, health, lastError |
  Sort-Object job | Format-Table -AutoSize
```

```bash
curl -s "http://localhost:9090/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | [.labels.job, .health, .lastError] | @tsv' | sort
```

**Expected output**

```text
job                                              health   lastError
---                                              ------   ---------
alertmanager                                     up
kube-prometheus-stack-grafana                    up
kube-prometheus-stack-kube-state-metrics         up
kube-prometheus-stack-operator                   up
kube-prometheus-stack-prometheus                 up
kubelet                                          up
node-exporter                                    up
orders-api                                       up
orders-api                                       up
```

Two `orders-api` rows because there are two replicas — the ServiceMonitor scrapes
endpoints, not the Service VIP. That is correct and important: a Service-level scrape would
round-robin and give you one pod's counters at random.

Now prove the recording rules are loaded and producing data:

```powershell
$q = "job:http_requests:rate5m"
(Invoke-RestMethod -Uri "http://localhost:9090/api/v1/query?query=$q").data.result |
  ForEach-Object { "{0} => {1}" -f ($_.metric | ConvertTo-Json -Compress), $_.value[1] }
```

```bash
curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=job:http_requests:rate5m' \
  | jq -r '.data.result[] | "\(.metric) => \(.value[1])"'
```

**Expected output**

```text
{"job":"orders-api","service":"orders-api"} => 0.26666666666666666
```

A small non-zero rate from your own curl traffic in step 6. An empty result means the rules
have not evaluated yet (wait 60s) or the rule file was not picked up — check
`http://localhost:9090/rules`.

---

## Step 9 — Generate load

The load test runs **inside the cluster as a Kubernetes Job**, so no local k6 install is
needed and the traffic does not traverse your port-forward.

### PowerShell

```powershell
make load-test
# equivalently:
kubectl apply -f app/k8s/k6-load-job.yaml
kubectl wait --for=condition=complete job/k6-load -n demo --timeout=600s
kubectl logs job/k6-load -n demo --tail=40
```

### bash

```bash
make load-test
kubectl apply -f app/k8s/k6-load-job.yaml
kubectl wait --for=condition=complete job/k6-load -n demo --timeout=600s
kubectl logs job/k6-load -n demo --tail=40
```

**Expected output**

```text
job.batch/k6-load created

          /\      Grafana   /‾‾/
     /\  /  \     |\  __   /  /
    /  \/    \    | |/ /  /   ‾‾\
   /          \   |   (  |  (‾)  |
  / __________ \  |_|\_\  \_____/

     execution: local
        script: /scripts/load.js
        output: -

     scenarios: (100.00%) 1 scenario, 40 max VUs, 5m30s max duration
              * steady: Up to 40 looping VUs for 5m0s over 3 stages

     data_received..................: 38 MB   127 kB/s
     data_sent......................: 4.1 MB  14 kB/s
     http_req_duration..............: avg=61.2ms min=3.1ms med=47.8ms max=1.21s p(90)=118ms p(95)=167ms
       { expected_response:true }...: avg=59.9ms min=3.1ms med=47.1ms max=1.21s p(90)=115ms p(95)=161ms
     http_req_failed................: 0.21%   ✓ 61        ✗ 28939
     http_reqs......................: 29000   96.6/s
     iteration_duration.............: avg=410ms  min=102ms med=398ms max=1.9s
     iterations.....................: 29000   96.6/s
     vus............................: 1       min=1       max=40
     vus_max........................: 40      min=40      max=40

     checks.........................: 99.79%  ✓ 28939     ✗ 61

job.batch/k6-load condition met
```

Roughly 97 req/s for 5 minutes, with a deliberate ~0.2% baseline error rate so the error
budget panels are not a flat zero line. A real zero is less instructive than a small real
number.

---

## Step 10 — Watch the dashboards light up

Open **http://localhost:3000/d/obs-app-red** (`Orders API — RED Metrics`). Within one or two
scrape intervals you should see:

| Panel | What appears |
|---|---|
| Request rate by route | ~97 req/s split across `/api/orders`, `/api/checkout`, `/healthz` |
| Error ratio | a thin band around 0.2%, well under the 0.1% budget line? no — above it, which is the point |
| p50 / p90 / p99 latency | three stacked lines; p99 around 160–250 ms |
| In-flight requests | `http_requests_in_flight` oscillating 1–12 |
| Orders processed by status | `success` dominant, a trickle of `failed` / `rejected` |
| Queue depth | `queue_depth` sawtooth between 0 and ~30 |

Then open **http://localhost:3000/d/obs-slo-budget** (`Orders API — SLO & Error Budget`):

| Panel | What appears |
|---|---|
| Availability SLO (30d) | a big stat, e.g. `99.79%` against a `99.9%` target |
| Error budget remaining | a gauge; after 5 minutes of 0.2% errors you have consumed a visible slice |
| Burn rate (1h) | around `2.1x` — elevated, below the 14.4x page threshold |
| Burn rate ladder | four series, one per rung, with threshold lines at 14.4 / 6 / 3 / 1 |
| Latency SLO (30d) | the `< 300ms` ratio for `/api/orders` + `/api/checkout` |

And **http://localhost:3000/d/obs-logs-explorer** should show a live tail. Verify Loki
independently of Grafana:

```powershell
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000
$then = ([DateTimeOffset]::UtcNow.AddMinutes(-5)).ToUnixTimeMilliseconds() * 1000000
kubectl exec -n monitoring loki-0 -- wget -qO- `
  "http://localhost:3100/loki/api/v1/query_range?query=sum(count_over_time({namespace=`"demo`"}[5m]))&start=$then&end=$now"
```

```bash
kubectl exec -n monitoring loki-0 -- wget -qO- \
  'http://localhost:3100/loki/api/v1/query_range?query=sum(count_over_time({namespace="demo"}[5m]))' \
  | jq -r '.data.result[0].values[-1][1]'
```

**Expected output**

```text
29431
```

Non-zero means Promtail is shipping and Loki is accepting. Zero means stop and read
[Troubleshooting: Promtail not shipping](troubleshooting.md#promtail-is-running-but-no-logs-reach-loki).

Finally confirm traces landed, and grab one trace id to use later:

```powershell
(Invoke-RestMethod -Uri "http://localhost:3200/api/search?tags=service.name%3Dorders-api&limit=3").traces |
  Select-Object traceID, rootServiceName, rootTraceName, durationMs
```

```bash
kubectl port-forward -n monitoring svc/tempo 3200:3200 &
curl -s 'http://localhost:3200/api/search?tags=service.name%3Dorders-api&limit=3' \
  | jq -r '.traces[] | [.traceID, .rootTraceName, .durationMs] | @tsv'
```

**Expected output**

```text
4bf92f3577b34da6a3ce929d0e0e4736   POST /api/checkout   187
a1c93f4d88e24bb7c2df019e4f7a1120   GET /api/orders       41
7e22b10c9a4f41d6b5ce330a1c8e0d55   POST /api/checkout   233
```

---

## Step 11 — Trigger an incident

This is the step that produces the screenshots. It uses the app's chaos endpoints (enabled
by `CHAOS_ENABLED=true` in the Deployment) to inject errors and latency, holds the fault
long enough for the burn-rate windows to react, and then heals.

### PowerShell

```powershell
.\scripts\trigger-incident.ps1
# which does, roughly:
#   curl http://localhost:8080/chaos/errors?pct=25
#   curl "http://localhost:8080/chaos/latency?ms=900&pct=40"
#   kubectl apply -f app/k8s/k6-load-job.yaml   (re-run traffic under fault)
#   ...hold for 12 minutes...
make break
```

### bash

```bash
./scripts/trigger-incident.sh
# or:
make break
```

**Expected output**

```text
=== trigger-incident ===
[1/5] Enabling 25% error injection   -> {"chaos":"errors","pct":25,"enabled":true}
[2/5] Enabling 900ms latency on 40%  -> {"chaos":"latency","ms":900,"pct":40,"enabled":true}
[3/5] Starting sustained load job    -> job.batch/k6-load-chaos created
[4/5] Holding fault for 12m so the 1h/5m burn-rate rung can fire...

  t+01m  error_ratio_5m=0.248  burn_1h=4.1   ErrorBudgetBurn: inactive
  t+03m  error_ratio_5m=0.251  burn_1h=12.4  ErrorBudgetBurn: inactive
  t+04m  error_ratio_5m=0.249  burn_1h=16.6  ErrorBudgetBurn[14.4x]: PENDING
  t+06m  error_ratio_5m=0.250  burn_1h=24.9  ErrorBudgetBurn[14.4x]: FIRING   severity=critical
  t+09m  error_ratio_5m=0.250  burn_1h=37.2  ErrorBudgetBurn[14.4x]: FIRING
  t+11m  error_ratio_5m=0.251  burn_1h=45.5  ErrorBudgetBurn[14.4x,6x]: FIRING

[5/5] Fault still active. Capture your screenshots now, then run: make heal
```

While it is firing, check Alertmanager at **http://localhost:9093**, or from the CLI:

```powershell
(Invoke-RestMethod -Uri "http://localhost:9093/api/v2/alerts").
  Where({$_.labels.alertname -eq "ErrorBudgetBurn"}) |
  Select-Object @{n='slo';e={$_.labels.slo}},
                @{n='sev';e={$_.labels.severity}},
                @{n='long';e={$_.labels.long_window}},
                @{n='burn';e={$_.labels.burn_rate}},
                @{n='state';e={$_.status.state}}
```

```bash
curl -s http://localhost:9093/api/v2/alerts \
  | jq -r '.[] | select(.labels.alertname=="ErrorBudgetBurn")
           | [.labels.slo, .labels.severity, .labels.long_window, .labels.burn_rate, .status.state] | @tsv'
```

**Expected output**

```text
slo           sev        long   burn   state
---           ---        ----   ----   -----
availability  critical   1h     14.4   active
availability  critical   6h     6      active
latency       warning    1d     3      active
```

Note the 3x `warning` rung is present in the API but **suppressed by inhibition** at
notification time, because a `critical` for the same `service` is active. Check the
annotations carried on the page — this is what makes it actionable:

```powershell
(Invoke-RestMethod -Uri "http://localhost:9093/api/v2/alerts")[0].annotations
```

```bash
curl -s http://localhost:9093/api/v2/alerts \
  | jq -r '[.[] | select(.labels.alertname=="ErrorBudgetBurn")][0].annotations'
```

**Expected output**

```json
{
  "summary": "orders-api is burning its availability error budget 14.4x faster than sustainable",
  "description": "Over the last 1h the availability SLO error ratio is 2.49% (burn rate 24.9x, threshold 1.44% / 14.4x). At this rate the 30-day budget of 43m12s is exhausted in 28h55m.",
  "runbook_url": "https://github.com/fakhfakhahmed/k8s-observability-stack/blob/main/runbooks/ErrorBudgetBurn.md",
  "dashboard_url": "http://localhost:3000/d/obs-slo-budget"
}
```

Now do the correlation walk described in [`architecture.md`](architecture.md#3-the-correlation-flow-metric-to-trace-to-log):
open `obs-app-red`, click an exemplar on the p99 panel, land in the Tempo waterfall, click
**Logs for this span**, and read the error line with the matching `trace_id`. That is the
screenshot worth taking.

### Heal

```powershell
.\scripts\heal.ps1
make heal
```

```bash
./scripts/heal.sh
make heal
```

**Expected output**

```text
=== heal ===
Resetting chaos state            -> {"chaos":"reset","errors":0,"latency_ms":0,"leak_mb":0}
Deleting chaos load job          -> job.batch "k6-load-chaos" deleted
Restoring steady baseline load   -> job.batch/k6-load created
Watching the burn-rate windows drain ...
  t+01m  error_ratio_5m=0.0021  burn_1h=45.9  burn_5m=12.4  ErrorBudgetBurn[14.4x]: FIRING
  t+05m  error_ratio_5m=0.0021  burn_1h=45.4  burn_5m=2.1   ErrorBudgetBurn[14.4x]: RESOLVED
  t+10m  error_ratio_5m=0.0019  burn_1h=45.0  burn_5m=1.9   ErrorBudgetBurn[6x]: FIRING
  t+32m  error_ratio_5m=0.0020  burn_1h=44.6  burn_5m=2.0   ErrorBudgetBurn[6x]: RESOLVED
  t+58m  error_ratio_5m=0.0020  burn_1h=9.7   burn_5m=2.0   (1h long window finally draining)
  t+72m  error_ratio_5m=0.0020  burn_1h=2.0   burn_5m=2.0   steady state
heal: cluster is healthy
```

Read that output carefully, because it is the single best demonstration in the repo of why
multi-window alerting exists. The service was healthy from `t+00m`, yet `burn_1h` stayed
pinned at ~45x for nearly an hour — a rolling 1-hour window has a one-hour memory, and
nothing makes those bad events leave faster. A single-window alert would have kept paging
for 57 minutes after the fix. The **5m short window** collapsed within one window length,
which is what actually resolved the alert. The 6x rung took longer only because its short
window is 30m.

The full arithmetic for that table is in
[`slo-guide.md`](slo-guide.md#step-6--why-the-short-window-is-anded-with-the-long-window).

---

## Troubleshooting

If any step above produced something other than its `Expected output`, go to
[`troubleshooting.md`](troubleshooting.md). It is organised by symptom. The fast index:

| Symptom | Section |
|---|---|
| `orders-api` missing from Prometheus Targets | ServiceMonitor not discovered |
| Target shows `connection refused` / `context deadline exceeded` | Targets DOWN |
| Grafana panel shows `Bad Gateway` or `dial tcp` | Grafana datasource errors |
| Logs Explorer empty | Promtail not shipping / Loki ingestion failures |
| `entry out of order` in Promtail logs | Loki ingestion failures |
| Trace search returns nothing | Tempo not receiving spans (4317 vs 4318) |
| Trace opens but no Logs button works | Traces visible but no logs link |
| Pods `Pending` | minikube resource exhaustion |
| Prometheus restarts under load | Prometheus OOM and cardinality explosion |
| `etcd` / `kube-scheduler` targets down | minikube control-plane bind addresses |
| `helm upgrade` fails on CRDs | helm upgrade failing on CRDs |

---

## Teardown

Three levels, cheapest first.

### Remove the app only (keep the stack and the cluster)

```powershell
kubectl delete -f app/k8s/
kubectl delete namespace demo
```

```bash
kubectl delete -f app/k8s/
kubectl delete namespace demo
```

**Expected output**

```text
deployment.apps "orders-api" deleted
service "orders-api" deleted
servicemonitor.monitoring.coreos.com "orders-api" deleted
configmap "orders-api-config" deleted
namespace "demo" deleted
```

### Remove the observability stack (keep the cluster)

```powershell
.\scripts\uninstall.ps1
make uninstall
```

```bash
./scripts/uninstall.sh
make uninstall
```

**Expected output**

```text
release "tempo" uninstalled
release "promtail" uninstalled
release "loki" uninstalled
release "kube-prometheus-stack" uninstalled
persistentvolumeclaim "prometheus-kube-prometheus-stack-prometheus-db-prometheus-..." deleted
persistentvolumeclaim "storage-loki-0" deleted
persistentvolumeclaim "tempo-storage-tempo-0" deleted
namespace "monitoring" deleted

Note: CRDs are intentionally NOT removed by 'helm uninstall'.
To remove them as well:
  kubectl delete crd alertmanagerconfigs.monitoring.coreos.com alertmanagers.monitoring.coreos.com \
    podmonitors.monitoring.coreos.com probes.monitoring.coreos.com prometheusagents.monitoring.coreos.com \
    prometheuses.monitoring.coreos.com prometheusrules.monitoring.coreos.com \
    scrapeconfigs.monitoring.coreos.com servicemonitors.monitoring.coreos.com \
    thanosrulers.monitoring.coreos.com
```

PVCs are deleted explicitly because Helm does not delete StatefulSet volume claims. Leaving
them behind is the usual reason a reinstall comes up with a surprisingly full TSDB and
seven-day-old data you did not expect.

### Destroy the cluster entirely

```powershell
make cluster-down
# equivalently:
minikube delete
```

```bash
make cluster-down
minikube delete
```

**Expected output**

```text
* Deleting "minikube" in docker ...
* Deleting container "minikube" ...
* Removing C:\Users\fakhf\.minikube\machines\minikube ...
* Removed all traces of the "minikube" cluster.
```

This reclaims the full 40 GiB and all pulled images. The next `make cluster-up` is a cold
start again — budget the full 40–55 minutes from the timing table.

---

Ahmed Fakhfakh — DevOps / SRE

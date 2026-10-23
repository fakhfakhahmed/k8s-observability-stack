# Load generation with k6

Synthetic traffic for `orders-api`. Without traffic, every dashboard in this repo is an empty
grid and every SLI is `NaN`. These scripts are what make the observability stack observable.

There are three scripts, and they answer three different questions.

| Script | Question it answers | Expected exit code | Run it when |
|---|---|---|---|
| [`steady.js`](steady.js) | Does the service meet its SLO under normal load? | `0` (any failure is a real failure) | Before a demo, in CI on every PR, whenever you want a clean baseline |
| [`spike.js`](spike.js) | Where and how does the service break? | Non-zero is normal | Capacity planning, HPA tuning, before a traffic event |
| [`failure-scenario.js`](failure-scenario.js) | Does the alerting pipeline actually work? | Non-zero is the **correct** result | Fire drills, validating a new alert, recording a portfolio demo |

---

## 1. `steady.js` — the baseline

Ramps 0 to 10 VUs over one minute, holds for eight minutes, ramps down over one minute.
Traffic mix is roughly 60% `GET /api/orders`, 30% `POST /api/checkout`, 10% `GET /`, with
jittered think time so the virtual users stay decorrelated.

Thresholds are the SLOs, verbatim:

```javascript
thresholds: {
  http_req_failed:   ['rate<0.001'],  // 99.9% availability SLO
  http_req_duration: ['p(99)<300'],   // 300 ms latency SLO
  checks:            ['rate>0.99'],
}
```

Custom metrics: `checkout_latency_ms` (Trend), `orders_created_total` (Counter),
`business_errors` (Rate). `setup()` probes `/healthz` first and aborts with an actionable
message rather than generating ten minutes of noise against a dead endpoint.

## 2. `spike.js` — saturation

Ramps 5 to 120 VUs in thirty seconds, holds two minutes, drops back to 5 and holds two more
minutes. That final recovery window is the point most people skip and it is where the
interesting bugs live: queues that never drain, connection pools that stay exhausted, HPAs
that thrash.

All thresholds carry `abortOnFail: false`. During a spike you **expect** to breach — the
deliverable is the dashboard, not the exit code. The script's header comment lists exactly
which panels on `obs-app-red` to watch, and `http_requests_in_flight` plus `queue_depth` are
the two saturation signals that matter most.

## 3. `failure-scenario.js` — the error-budget burner

Used by `scripts/trigger-incident.ps1` / `.sh` (`make break`). It enables chaos itself:

```text
setup()    POST /chaos/errors?pct=35            -> 350x availability burn rate
           POST /chaos/latency?ms=900&pct=25    ->  25x latency burn rate
teardown() POST /chaos/reset
```

Thresholds are the same SLO numbers as `steady.js`, which under 35% injected errors are
arithmetically unmeetable. **A red k6 summary is the correct outcome.** We are proving the
alerting works, not proving the app is healthy.

`teardown()` is best effort. If the Job is killed (`kubectl delete job`,
`activeDeadlineSeconds`, OOM, node loss), teardown never runs and the app stays broken.
The manual escape hatch is `make heal` / `scripts/heal.ps1` / `scripts/heal.sh`. Chaos state
is in-memory, so `kubectl rollout restart deploy/orders-api -n demo` also clears it.

Requires the Deployment to carry `CHAOS_ENABLED=true`. If it does not, `setup()` aborts and
tells you the exact `kubectl set env` command.

---

## Running the tests — three ways

### Way 1 (recommended): as a Kubernetes Job

k6 is **not installed** on this machine, and does not need to be. Running in-cluster is also
more representative: traffic goes through the real ClusterIP Service and kube-proxy rather
than a port-forward tunnel, which otherwise becomes the bottleneck above ~50 VUs.

```bash
# Apply the ConfigMap + Job
kubectl apply -f load/k8s/k6-job.yaml

# Follow the output live
kubectl logs -f job/k6-load-test -n demo

# Re-run (a completed Job is immutable — you must delete it first)
kubectl delete job k6-load-test -n demo
kubectl apply -f load/k8s/k6-job.yaml
```

To run a different script, edit the Job's `args` — the ConfigMap mounts all three at
`/scripts`:

```yaml
args: ["run", "/scripts/steady.js"]            # baseline
# args: ["run", "/scripts/spike.js"]           # saturation
# args: ["run", "/scripts/failure-scenario.js"] # incident drill
```

Or override on the fly without editing the committed file:

```bash
# Swap the script with sed before applying (bash / Git Bash)
sed 's#/scripts/steady.js#/scripts/spike.js#' load/k8s/k6-job.yaml | kubectl apply -f -
```

```powershell
# PowerShell equivalent
(Get-Content load\k8s\k6-job.yaml -Raw) -replace '/scripts/steady.js','/scripts/spike.js' |
  kubectl apply -f -
```

The ConfigMap holds trimmed copies of the scripts. Regenerate it from the real sources with:

```bash
kubectl create configmap k6-scripts \
  --from-file=load/k6/ \
  --namespace demo \
  --dry-run=client -o yaml > /tmp/k6-scripts.yaml
```

### Way 2: a local k6 binary

```powershell
# Windows
winget install k6.k6
# or
choco install k6
```

```bash
# macOS / Linux
brew install k6
# or: sudo gpg -k && sudo apt-get install k6  (after adding the Grafana apt repo)
```

Then port-forward and point k6 at localhost:

```powershell
./scripts/port-forward.ps1            # exposes orders-api on http://localhost:8080

k6 run -e BASE_URL=http://localhost:8080 load/k6/steady.js
k6 run -e BASE_URL=http://localhost:8080 -e VUS=25 load/k6/spike.js
k6 run -e BASE_URL=http://localhost:8080 -e DURATION=20m load/k6/failure-scenario.js
```

Caveat: `kubectl port-forward` is a single-connection userspace proxy. It is fine for
`steady.js` at 10 VUs and actively misleading for `spike.js` at 120 VUs — you will measure the
port-forward, not the service. Use Way 1 for anything above about 25 VUs.

### Way 3: Docker, no install at all

```bash
# Pipe the script in on stdin. The trailing `-` tells k6 to read from stdin.
docker run --rm -i grafana/k6 run - < load/k6/steady.js

# With env vars and host networking so it can reach a port-forward on the host
docker run --rm -i --network host \
  -e BASE_URL=http://localhost:8080 \
  grafana/k6 run - < load/k6/steady.js

# Mounting the directory instead of piping (needed if you ever add imports
# between the scripts, because stdin mode has no module resolution root)
docker run --rm -i \
  -v "$(pwd)/load/k6:/scripts" \
  -e BASE_URL=http://host.docker.internal:8080 \
  grafana/k6 run /scripts/steady.js
```

On Windows PowerShell, `<` redirection does not work the way it does in `sh`. Use:

```powershell
Get-Content load\k6\steady.js | docker run --rm -i grafana/k6 run -
```

---

## Environment variables

All scripts read configuration from `__ENV`, which k6 populates from `-e KEY=value` on the
command line or from the container's environment when running as a Job.

| Variable | Default | Used by | Meaning |
|---|---|---|---|
| `BASE_URL` | `http://orders-api.demo.svc.cluster.local:8080` | all | Target base URL. Use `http://localhost:8080` when running from the host behind a port-forward. |
| `DURATION` | `8m` (steady), `2m` (spike peak), `10m` (failure) | all | Length of the plateau stage. Does not include ramp up/down. |
| `VUS` | `10` (steady, failure), `120` (spike) | all | Plateau virtual-user count. |
| `BASE_VUS` | `5` | spike | Background VU level either side of the spike. |
| `THINK_MIN` / `THINK_MAX` | `0.4` / `1.2` | steady | Think-time bounds in seconds. Lower them to raise the request rate without raising concurrency. |
| `ERROR_PCT` | `35` | failure | Percentage of requests forced to 5xx. |
| `LATENCY_MS` | `900` | failure | Injected delay in milliseconds. |
| `LATENCY_PCT` | `25` | failure | Percentage of requests that get the delay. |
| `RESET_ON_EXIT` | `true` | failure | Set to `false` to leave chaos enabled after the run for a longer manual investigation. You must then run `make heal` yourself. |
| `TESTID` | `<scenario>-local` | all | Free-form tag stamped on every sample. Useful for separating runs once you ship k6 metrics to Prometheus. |

Example:

```bash
k6 run -e BASE_URL=http://localhost:8080 \
       -e VUS=20 \
       -e DURATION=15m \
       -e TESTID=pr-142-baseline \
       load/k6/steady.js
```

---

## Reading k6 output

### The timing breakdown

k6 decomposes every request into phases. Confusing them is the single most common source of
wrong conclusions in load testing.

```text
http_req_duration = http_req_sending + http_req_waiting + http_req_receiving
                    (write request)    (TTFB / server)   (read body)

NOT included in http_req_duration:
  http_req_blocked   waiting for a free connection slot, plus DNS
  http_req_connecting TCP handshake
  http_req_tls_handshaking TLS negotiation
```

| Metric | What it really measures | When it is the one you want |
|---|---|---|
| `http_req_waiting` | Time to first byte. This is **server time**: queueing plus handler plus any downstream call. | Diagnosing the application. This is the number that should correlate with the app's own `http_request_duration_seconds`. |
| `http_req_duration` | TTFB plus the time to stream the body back. | The SLO. It is the closest thing to what a client experiences on an established connection. |
| `http_req_blocked` | Connection-pool starvation and DNS. | When `duration` is fine but the test still feels slow — you are out of sockets, not out of CPU. |
| `iteration_duration` | The **entire** default function, **including your `sleep()`**. | Almost never a latency signal. With a 0.4–1.2 s think time, `iteration_duration` is dominated by sleep and will sit around 1 s no matter how fast the server is. Never quote it as latency. |

So: when `http_req_duration p(99)` is 280 ms, `http_req_waiting p(99)` is 275 ms and
`iteration_duration med` is 1,050 ms, nothing is wrong. The server took 275 ms and the
virtual user then had a think. If instead `duration` is 280 ms but `blocked` is 400 ms, the
load generator is the bottleneck and the result is garbage.

### Percentiles

`p(99)<300` means the 99th percentile across **the whole run**, including the ramp. On a run
with a one-minute ramp into an eight-minute plateau, the ramp is 10% of the samples and can
drag a borderline p99 over the line. If you need the plateau in isolation, tag the stages or
use the `phase` tag pattern from `spike.js`.

k6 computes exact percentiles from retained samples. Prometheus computes them from histogram
buckets with `histogram_quantile`, which interpolates inside a bucket. The two will not agree
to the millisecond, and that is expected, not a bug. The repo's bucket list
(`0.005 0.01 0.025 0.05 0.1 0.2 0.3 0.4 0.5 0.75 1 2.5 5 10`) deliberately places a boundary
exactly at `0.3` so that the SLO threshold needs no interpolation at all.

### The failure modes to recognise

| Symptom | Likely meaning |
|---|---|
| `http_req_failed` rises before `http_req_duration` does | Something crashed or is refusing connections. Not saturation. |
| `http_req_duration` rises while throughput stays flat | Saturation. Check `http_requests_in_flight` and `queue_depth`. |
| `http_req_blocked` rises | Client-side connection exhaustion. Raise the Job's CPU, or check `ulimit -n`. |
| `status 0` responses | Transport error — connection refused, reset, or client timeout. Check whether your `timeout` is shorter than the server's p99. |
| Throughput plateaus while VUs keep climbing | You have found the capacity ceiling. That plateau value is your capacity number. Write it down. |

---

## How k6 thresholds relate to the Prometheus SLOs

The numbers are not similar. They are **identical**.

| Dimension | Prometheus (production) | k6 (pre-production) |
|---|---|---|
| Availability | `job:slo_availability_errors:ratio_rate30d{job="orders-api"} < 0.001` | `http_req_failed: ['rate<0.001']` |
| Latency | 99% of `/api/orders` + `/api/checkout` under 300 ms, from the `le="0.3"` bucket | `http_req_duration: ['p(99)<300']` |
| Window | 30-day rolling | one test run (10 minutes) |
| Consequence of breach | Error budget burns, `ErrorBudgetBurn` pages | `k6` exits non-zero, the pipeline fails |

The window differs; the contract does not. That asymmetry is the whole idea:

- **In production**, the SLO is a 30-day budget. It tolerates bad minutes because users
  tolerate bad minutes. It pages only when the *rate* of spending threatens the month, which
  is why the burn-rate ladder exists (14.4x / 6x / 3x / 1x — see
  [`../../docs/slo-guide.md`](../../docs/slo-guide.md)).
- **In CI**, there is no budget to spend and no user to annoy. A change that cannot hold
  `p(99) < 300 ms` for ten minutes against 10 VUs on a laptop is a change that will spend
  budget in production. Fail it at the pull request.

This is **shifting SLO verification left**. The conventional version of "shift left" moves
unit tests earlier. The SRE version moves the *reliability contract* earlier: the same number
that defines the production promise becomes a build gate. Three consequences worth stating:

1. **The SLO stops being a document and becomes executable.** Nobody has to remember that the
   target is 300 ms; the build remembers.
2. **Regressions are attributed to a commit, not to a week.** A 40 ms regression merged on
   Tuesday is invisible in a 30-day rolling window until it compounds with two more. In CI it
   is a red check on one pull request with one author.
3. **Changing the SLO becomes a code review.** Loosening `p(99)<300` to `p(99)<500` is a diff
   someone has to approve, in the same pull request as the change that needed it. That is
   exactly the conversation you want to force.

What this does **not** replace: a laptop minikube cluster is not production. CI thresholds
catch gross regressions and contract breaks. They do not catch anything that only appears at
production data volumes, under production cardinality, or with production dependency latency.
Treat a green `steady.js` as necessary, not sufficient.

The error-budget policy that governs what to do when the production budget actually runs low
lives in [`../../slo/README.md`](../../slo/README.md).

---

## Next step: ship k6 metrics to Prometheus

Right now k6 prints a summary and the JSON artefact, and then the data is gone. k6 can write
its metrics directly into Prometheus via remote write, which puts load-test results in the
same TSDB and the same Grafana as production telemetry.

```bash
# kube-prometheus-stack ships with the remote-write receiver available on the
# Prometheus service; enable it with --web.enable-remote-write-receiver
# (stack/prometheus/values.yaml, prometheus.prometheusSpec.enableFeatures).

K6_PROMETHEUS_RW_SERVER_URL=http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write \
K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99),min,max" \
K6_OUT=experimental-prometheus-rw \
  k6 run load/k6/steady.js
```

Why this is worth doing:

- k6 metrics land as `k6_http_req_duration_*` series carrying the `scenario` and `testid` tags
  set in each script's `options.tags`, so you can graph "p99 from the client" and "p99 from the
  server" on one panel. The gap between them **is** the network and proxy overhead, measured
  rather than guessed.
- Load-test runs become queryable history. "Has p99 drifted since release 0.1.0?" is a
  PromQL query instead of a hunt through CI logs.
- You can annotate Grafana with the test start/end and overlay it on the RED dashboard.

Caveats before you turn it on: remote write into a laptop Prometheus will noticeably grow the
TSDB, `K6_PROMETHEUS_RW_TREND_STATS` controls cardinality (do not ask for every percentile),
and the module is still flagged experimental in k6 0.54 — the series naming has changed between
releases before.

---

Ahmed Fakhfakh — DevOps / SRE

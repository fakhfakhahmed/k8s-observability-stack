# Runbook: HighLatencyP99

| Field | Value |
|---|---|
| Alert name | `HighLatencyP99` |
| Severity | `warning` |
| Team | `orders` |
| Dashboard | http://localhost:3000/d/obs-app-red |
| SLO impact | Direct — drives the `latency` SLO and `ErrorBudgetBurn{slo="latency"}` |
| Typical time-to-mitigate | 15–30 minutes |

## 1. What this alert means

The 99th percentile request duration for `orders-api` has been above **500ms** for ten
minutes. The latency SLO itself is stricter — 99% of requests to `/api/orders` and
`/api/checkout` under **300ms** — so 500ms at p99 means the SLO is already being violated
and the `latency` error budget is burning.

```promql
job:http_request_duration_seconds:p99{job="orders-api"} > 0.5
```

`for: 10m`. The recording rule behind it is a `histogram_quantile` over
`http_request_duration_seconds_bucket`, aggregated to job level:

```promql
# job:http_request_duration_seconds:p99 is recorded as
histogram_quantile(
  0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket{job="orders-api"}[5m]))
)
```

Two thresholds, two purposes: 300ms is the promise to users, 500ms is the point at which a
human should look. The gap is intentional — paging at the SLO threshold produces noise.

## 2. Impact

- Checkout and order listing feel slow. Clients with a 500ms timeout see failures that never
  appear as 5xx in our metrics, so `HighErrorRate` may stay silent while users are affected.
- `http_requests_in_flight` climbs as slow requests pile up; at some point the pod runs out
  of worker capacity and latency becomes errors.
- Burns the `latency` error budget (1% over 30 days). A sustained p99 of 500ms on a service
  whose SLO is 300ms burns at well over 1x and will trip `ErrorBudgetBurn{slo="latency"}`.

## 3. Severity and response expectation

`warning`, ticketed to the `orders` team, ack within one business day. Escalate to incident
handling immediately if `ErrorBudgetBurn{slo="latency", burn_rate="14.4"}` is also firing,
if p99 is above 1s, or if `queue_depth` is growing at the same time — that combination is
the start of a queue collapse, and it does not recover on its own.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-app-red — RED metrics: the latency heatmap and the
  p50/p90/p99 panel. Exemplars on the duration histogram link straight into Tempo.
- http://localhost:3000/d/obs-k8s-cluster — node and pod CPU, to rule out saturation
- http://localhost:3000/d/obs-slo-budget — latency budget consumption

```promql
# Which route is slow.
topk(5, route:http_request_duration_seconds:p99{job="orders-api"})
```
Bad answer: `/api/checkout` above 0.5 — that is the revenue path and the SLO path.
`/healthz` being slow means the process itself is stalled, not a handler.

```promql
# Percentile spread tells you the shape of the problem.
route:http_request_duration_seconds:p50{job="orders-api"}
  and route:http_request_duration_seconds:p90{job="orders-api"}
  and route:http_request_duration_seconds:p99{job="orders-api"}
```
Bad answer: p50 flat and p99 up means a slow tail — GC pauses, lock contention, a cold cache,
one bad replica. p50 up as well means everything is slow — saturation or a dependency.

```promql
# Concurrency — are requests piling up?
http_requests_in_flight{job="orders-api"}
```
Bad answer: a monotonic climb. The service is accepting faster than it can complete, and
latency will keep rising until something breaks.

```promql
# Saturation check: CPU per pod against the limit.
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="demo", container="orders-api"}[5m]))
```
Bad answer: a value pinned at the CPU limit — the container is being throttled and latency
is a consequence, not a cause.

## 5. Diagnosis

1. **Read the percentile spread before anything else.** Step 2 of section 4 splits the
   problem space in half: tail-only versus everything-slow.

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'route:http_request_duration_seconds:p99{job="orders-api"}'
   ```

2. **Mind the bucket boundaries — this is the classic `histogram_quantile` trap.**
   `histogram_quantile` does linear interpolation *inside* a bucket; it cannot resolve
   anything finer than the bucket edges. The configured buckets are:

   ```
   0.005 0.01 0.025 0.05 0.1 0.2 0.3 0.4 0.5 0.75 1 2.5 5 10
   ```

   Consequences you must account for before chasing a change:

   - A reported p99 of `0.5` does not mean "exactly 500ms". It means "somewhere between
     0.4 and 0.5, interpolated" — or, if the bucket above `0.5` is where the observations
     actually live, somewhere between 0.5 and 0.75.
   - A p99 that moves from `0.42` to `0.47` may be a genuine regression or may be a handful
     of requests shifting position *within the same bucket*. Do not open an investigation on
     sub-bucket movement.
   - Anything above the largest finite bucket (`10`) is reported as `+Inf`-clamped and the
     quantile saturates at `10`. A p99 of exactly `10` means "at least 10s", not "10s".
   - The `0.3 / 0.4 / 0.5` edges exist specifically so the 300ms SLO and the 500ms alert sit
     *on* bucket boundaries. That is what makes both numbers trustworthy; it is also why
     nobody should "tidy up" the bucket list.

   Cross-check the quantile against a boundary-exact ratio, which has no interpolation error:

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'sum(rate(http_request_duration_seconds_bucket{job="orders-api", route=~"/api/orders|/api/checkout", le="0.3"}[5m]))
      / sum(rate(http_request_duration_seconds_count{job="orders-api", route=~"/api/orders|/api/checkout"}[5m]))'
   ```

   This is the true SLO compliance ratio. Below `0.99` means the latency SLO is being missed,
   full stop, with no quantile estimation involved.

3. **Check saturation: CPU throttling, memory pressure, and the node.**

   ```bash
   kubectl -n demo top pods -l app.kubernetes.io/name=orders-api
   kubectl top nodes
   kubectl -n demo describe pod -l app.kubernetes.io/name=orders-api | grep -A6 'Limits\|Requests'
   ```

   CPU usage at the limit means throttling. On minikube with 4 CPUs the whole cluster shares
   them, so a noisy Prometheus compaction can slow the app — check the node, not just the pod.

4. **Pivot to a slow trace.** On the RED dashboard, click an exemplar in the high-latency
   region of the duration panel; Grafana opens it in Tempo. Or query Tempo for slow traces:

   ```bash
   kubectl -n monitoring port-forward svc/tempo 3200:3200 &
   curl -sG http://localhost:3200/api/search \
     --data-urlencode 'q={ resource.service.name="orders-api" && duration > 500ms }' \
     --data-urlencode 'limit=10' \
   | jq -r '.traces[] | [.traceID, .rootTraceName, .durationMs] | @tsv'
   ```

   In the waterfall, look for the single widest span. A gap between spans with no child
   activity is GC, scheduling delay, or a lock — not a downstream call.

5. **Correlate the trace with its logs.** Take the `trace_id` from step 4:

   ```logql
   {namespace="demo", app="orders-api"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
   ```

   The log line carries `duration_ms`, which should match the trace. If it does not, the time
   is being spent before the handler starts — queueing, TLS, or connection setup.

6. **Check whether work is backing up.**

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'queue_depth{job="orders-api"} and deriv(queue_depth{job="orders-api"}[15m]) > 0'
   ```

   A non-empty result means `QueueDepthGrowing` is about to fire too, and latency is a
   downstream effect of a stuck consumer.

7. **Check for injected latency and recent deploys.**

   ```bash
   kubectl -n demo logs deployment/orders-api --since=30m | grep -i 'chaos' | tail -20
   kubectl -n demo rollout history deployment/orders-api
   ```

   `/chaos/latency?ms=...&pct=...` is the single most common cause of this alert in a demo
   cluster. Rule it out in ten seconds rather than debugging it for twenty minutes.

## 6. Mitigation

1. **Reset chaos** — instant, no restart:

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s "http://localhost:8080/chaos/reset"
   ```

2. **Roll back** if a deploy precedes the latency change:

   ```bash
   kubectl rollout undo deployment/orders-api -n demo
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

3. **Scale out** — the correct answer when the pods are saturated and the code is fine:

   ```bash
   kubectl -n demo scale deployment/orders-api --replicas=5
   kubectl -n demo get hpa orders-api          # if HPAMaxedOut is firing, raise the ceiling
   kubectl -n demo patch hpa orders-api --type=merge -p '{"spec":{"maxReplicas":8}}'
   ```

4. **Raise the CPU limit** — if `container_cpu_cfs_throttled_seconds_total` is climbing,
   more replicas will not help; each one is still throttled:

   ```bash
   kubectl -n demo set resources deployment/orders-api \
     --containers=orders-api --limits=cpu=1000m --requests=cpu=200m
   ```

5. **Restart** — clears a cold or corrupted cache, a leaked goroutine pool, or a
   degraded connection pool:

   ```bash
   kubectl -n demo rollout restart deployment/orders-api
   ```

6. **Give the node more headroom** — minikube only, largest blast radius since it recreates
   the cluster VM. See [NodeMemoryPressure.md](NodeMemoryPressure.md) before doing this.

Verify with the boundary-exact ratio from diagnosis step 2, not with the p99 — it is the
number the SLO actually uses.

## 7. If it does not resolve — escalation

Escalate to the `orders` service owner (Ahmed Fakhfakh) if the latency is in the application;
to `platform` if diagnosis step 3 showed node-level saturation or throttling.

```bash
{
  echo "=== p50 / p90 / p99 by route ==="
  for q in p50 p90 p99; do
    echo "-- $q"
    curl -sG http://localhost:9090/api/v1/query \
      --data-urlencode "query=route:http_request_duration_seconds:${q}{job=\"orders-api\"}" \
      | jq -r '.data.result[] | [.metric.route, .value[1]] | @tsv'
  done

  echo "=== SLO compliance ratio (requests under 300ms) ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sum(rate(http_request_duration_seconds_bucket{job="orders-api",route=~"/api/orders|/api/checkout",le="0.3"}[5m])) / sum(rate(http_request_duration_seconds_count{job="orders-api",route=~"/api/orders|/api/checkout"}[5m]))' \
    | jq -r '.data.result[].value[1]'

  echo "=== in-flight and queue depth ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=http_requests_in_flight{job="orders-api"}' | jq -r '.data.result[].value[1]'
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=queue_depth{job="orders-api"}' | jq -r '.data.result[].value[1]'

  echo "=== resources ==="
  kubectl -n demo top pods -l app.kubernetes.io/name=orders-api
  kubectl top nodes
  kubectl -n demo describe deployment/orders-api | grep -A8 'Limits'
  kubectl -n demo rollout history deployment/orders-api
} > high-latency-p99-evidence.txt 2>&1
```

Attach at least one slow `trace_id` from diagnosis step 4.

## 8. Prevention and follow-up

- Add a latency assertion to the k6 scenario (`make load-test`) with a threshold at the SLO,
  not at the alert — catch 300ms regressions before they become 500ms incidents.
- Set CPU requests so the scheduler reserves what the service actually needs; a request that
  is too low gets the pod placed on a saturated node and throttled under load.
- Do not widen the histogram buckets to "make the graph smoother". The `0.3 / 0.4 / 0.5`
  edges are load-bearing for both the SLO and this alert.
- If the tail is GC-driven, set `GOMEMLIMIT` so the Go runtime collects on a schedule you
  chose rather than one the kernel chose — see [ContainerOOMKilled.md](ContainerOOMKilled.md).
- Review whether 500ms is still the right alerting threshold, or whether
  `ErrorBudgetBurn{slo="latency"}` alone is sufficient.

Docs: [`../docs/slo-guide.md`](../docs/slo-guide.md),
[`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md),
[`../docs/promql-cookbook.md`](../docs/promql-cookbook.md) (histogram and quantile recipes),
[`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml)
- Recording rules: [`../stack/prometheus/rules/recording-rules.yaml`](../stack/prometheus/rules/recording-rules.yaml)
- [ErrorBudgetBurn.md](ErrorBudgetBurn.md) — `slo="latency"` rungs
- [HighErrorRate.md](HighErrorRate.md) — latency that gets worse becomes errors
- [NodeMemoryPressure.md](NodeMemoryPressure.md), [ContainerOOMKilled.md](ContainerOOMKilled.md) — saturation causes
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

# PromQL cookbook

Every query below is runnable against this repo's actual Prometheus — all metric and label names
match exactly what `app/main.go` exposes (`http_requests_total{method,route,status}`,
`http_request_duration_seconds{method,route}` histogram with buckets at
`0.005,0.01,0.025,0.05,0.1,0.2,0.3,0.4,0.5,0.75,1,2.5,5,10`, `http_requests_in_flight`,
`orders_processed_total{status}`, `order_value_euros` histogram, `queue_depth`,
`app_build_info{version,commit,go_version}`). Open Prometheus's Graph tab
(`scripts/port-forward`) and paste any of these in.

### 1. Request rate, per route

```promql
sum by (route) (rate(http_requests_total{job="orders-api"}[5m]))
```
`rate()` turns the monotonic counter into a per-second average over the window; `sum by (route)`
collapses the `method`, `status` and per-pod labels you don't care about here. **Never graph the
raw counter** — `http_requests_total` alone just climbs forever and tells you nothing about
current load.

### 2. Error ratio, per route

```promql
sum by (route) (rate(http_requests_total{job="orders-api", status=~"5.."}[5m]))
/
sum by (route) (rate(http_requests_total{job="orders-api"}[5m]))
```
Both sides MUST carry the same `by (route)` — division in PromQL matches series by their full
label set, so without identical aggregation on both sides you get one result per
`(route, method, status)` triple, each equal to exactly 1.0 or 0.0, not a usable ratio.

### 3. `rate()` vs. `increase()` — restart counting

```promql
# "how many times has it restarted" — a COUNT, use increase()
increase(kube_pod_container_status_restarts_total{namespace="demo"}[15m])

# "what's the restart rate" — almost never what you actually want for this metric
rate(kube_pod_container_status_restarts_total{namespace="demo"}[15m])
```
`PodCrashLooping` uses `increase() > 2`, a direct count comparison — "more than twice in 15
minutes" is a natural-language count, not a rate.

### 4. `rate()` vs. `irate()` — smoothing vs. reactivity

```promql
rate(http_requests_total{job="orders-api"}[5m])   # smoothed, correct for alerting/dashboards
irate(http_requests_total{job="orders-api"}[5m])  # last two samples only — spiky, for live-tail graphs
```
Never alert on `irate()` — two noisy adjacent samples can trigger it even when the real trend is
flat.

### 5. p99 latency, correctly

```promql
histogram_quantile(0.99,
  sum by (route, le) (rate(http_request_duration_seconds_bucket{job="orders-api"}[5m]))
)
```

### 6. The `histogram_quantile` pitfall — missing `le`

```promql
# WRONG — le was summed away, histogram_quantile has nothing to interpolate between
histogram_quantile(0.99, sum by (route) (rate(http_request_duration_seconds_bucket{job="orders-api"}[5m])))

# RIGHT — le preserved through the aggregation
histogram_quantile(0.99, sum by (route, le) (rate(http_request_duration_seconds_bucket{job="orders-api"}[5m])))
```
`le` is not a dimension you want to collapse — it's the bucket-boundary label
`histogram_quantile` needs to see every value of in order to interpolate. Drop it from `by()` and
the function either errors (newer Prometheus versions warn explicitly) or returns nonsense.

### 7. Why the SLO uses a bucket count instead of `histogram_quantile`

```promql
# bad-event ratio for the latency SLO: EXACT, not interpolated, because le="0.3" is a real boundary
1 - (
  sum by (job) (rate(http_request_duration_seconds_bucket{job="orders-api", route=~"/api/orders|/api/checkout", le="0.3"}[5m]))
  /
  sum by (job) (rate(http_request_duration_seconds_count{job="orders-api", route=~"/api/orders|/api/checkout"}[5m]))
)
```
`histogram_quantile` answers "what VALUE is the 99th percentile" (an estimate via interpolation).
An SLO needs "what FRACTION of requests were under 300ms" — a direct bucket-boundary count
answers that exactly, with zero interpolation error, because `0.3` is a real `le` value in this
histogram's bucket layout. See `slo-guide.md` section 5.

### 8. Aggregation: `by` vs `without`

```promql
sum by (route) (rate(http_requests_total{job="orders-api"}[5m]))       # keep ONLY route
sum without (pod, instance) (rate(http_requests_total{job="orders-api"}[5m]))  # keep everything EXCEPT pod/instance
```
Use `by` when you know exactly which label matters. Use `without` to collapse per-replica noise
while preserving every OTHER label automatically, including ones added later that you haven't
thought of yet.

### 9. Counter resets — why `rate()` doesn't go negative on a restart

```promql
rate(http_requests_total{job="orders-api", pod="orders-api-abc123"}[5m])
```
If `orders-api-abc123` restarted mid-window, its counter reset to 0. `rate()` detects the drop
and treats it as a reset, extrapolating as though the counter had continued climbing — it does
NOT report a negative rate. This is why counters are safe to `rate()` across restarts and gauges
(`queue_depth`, `http_requests_in_flight`) are not — a gauge going down is a REAL decrease, with
no reset semantics to account for.

### 10. `increase()` vs. `rate() * window` — they're the same, pick the readable one

```promql
increase(orders_processed_total{job="orders-api", status="failed"}[1h])
# equivalent to:
rate(orders_processed_total{job="orders-api", status="failed"}[1h]) * 3600
```
`increase()` is extrapolated the same way `rate()` is internally — prefer it whenever the
question is phrased as a count ("how many failed orders in the last hour") rather than a rate.

### 11. `absent()` — detecting a metric that never existed

```promql
absent(up{job="a-job-that-does-not-exist"})
```
Returns `1` if the series is entirely absent, nothing if it exists. Useful for "did this
ServiceMonitor ever get adopted at all" sanity checks during setup — see
`docs/troubleshooting.md`.

### 12. `absent_over_time()` — detecting a metric that STOPPED existing

```promql
absent_over_time(http_requests_total{job="orders-api"}[10m])
```
This repo's `NoTrafficReceived` alert. A ratio-based SLO alert goes SILENT (not "100% bad") when
its denominator vanishes — `absent_over_time` is the only tool that can see a series disappear,
because a `>` comparison against a missing series simply never evaluates.

### 13. `predict_linear()` — forecasting a gauge's future value

```promql
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[1h], 4 * 3600) < 0
```
Fits a linear regression over the last hour of a gauge's values and asks "will it cross zero in
the next 4 hours". This pages on disk exhaustion BEFORE it happens, not after — see
`NodeDiskSpaceLow` in `stack/prometheus/rules/alerts-infra.yaml`.

### 14. `topk()` — top N series by current value

```promql
topk(5, route:http_request_duration_seconds:p99_5m{job="orders-api"})
```
Used by `app-red-metrics.json`'s "top slow routes" table. `topk` operates on an INSTANT vector —
pair it with `instant: true` in a Grafana table panel's query options, or it returns a confusing
time-windowed result.

### 15. `deriv()` — is a gauge trending up or down

```promql
deriv(queue_depth{job="orders-api"}[10m]) > 0.05
```
`rate()`/`increase()` are only valid on counters (monotonically increasing). For a GAUGE like
`queue_depth` that can go up or down, `deriv()` performs linear regression and returns the
estimated per-second slope — exactly the tool for "is this trending upward", which is what
`QueueDepthGrowing` uses it for.

### 16. Joining metrics on a shared label — attributing a graph to a deploy

```promql
route:http_request_duration_seconds:p99_5m{job="orders-api"}
  * on (job) group_left(version)
  app_build_info{job="orders-api"}
```
`app_build_info` is the classic "info metric" pattern — its value is always `1`; the payload is
in its LABELS (`version`, `commit`, `go_version`). `group_left(version)` performs a many-to-one
join, attaching the `version` label from `app_build_info` onto every series of the (potentially
many) p99 series it matches by `job`, without requiring the label sets to otherwise match. This is
how you answer "which version was running when this latency regression started" — see
`app-red-metrics.json`'s "Deploys" annotation, which uses `changes(app_build_info[1m]) > 0` to
mark every deploy directly on the timeline.

### 17. `changes()` — counting how many times a series' value changed

```promql
changes(app_build_info{job="orders-api"}[1h]) > 0
```
Since `app_build_info`'s VALUE never changes (always `1`) but its LABEL SET does on every deploy
(new `version`/`commit`), each deploy produces a brand-new series starting at 1 while the old one
goes stale — `changes()` over a window that straddles a deploy sees this as the metric
"reappearing", which is exactly the signal used to draw deploy markers on a dashboard.

### 18. Business-metric ratio — is the business healthy, not just the infrastructure

```promql
sum(rate(orders_processed_total{job="orders-api", status="success"}[5m]))
/
sum(rate(orders_processed_total{job="orders-api"}[5m]))
```
A pure infra view ("CPU fine, pods Running") can look perfectly healthy while this ratio craters
— e.g. a dependency silently returning malformed success responses. Always pair an infra
dashboard with at least one business-outcome query; see `job:orders_processed_success_ratio:rate5m`
in `stack/prometheus/rules/recording-rules.yaml`.

### 19. `offset` — comparing now against a week ago

```promql
sum(rate(http_requests_total{job="orders-api"}[5m]))
  /
sum(rate(http_requests_total{job="orders-api"}[5m] offset 7d))
```
`offset` shifts the ENTIRE query back in time before evaluating — useful for "is today's traffic
unusually low compared to the same time last week", a cheap seasonal-anomaly check without a
dedicated forecasting system.

### 20. `sum(rate(...))` vs `avg(rate(...))` — a frequent mix-up

```promql
sum(rate(http_requests_total{job="orders-api"}[5m]))   # total cluster-wide request rate
avg(rate(http_requests_total{job="orders-api"}[5m]))   # AVERAGE PER-POD rate — a different question
```
`sum` answers "how much total traffic is the service handling" (what you almost always want for
a rate panel). `avg` answers "what's a typical single pod's rate" — useful for spotting an
unbalanced load across replicas (compare `avg` against `max`/`min` per pod to see imbalance), but
graphing `avg` alone when you meant `sum` silently under-reports total load by a factor of the
replica count.

## See also

- [`slo-guide.md`](slo-guide.md) — the SLI/SLO queries from entries 2 and 7, derived in full
- [`../LEARN.md`](../LEARN.md) section 5 — the conceptual grounding behind every query above
- [`../stack/prometheus/rules/recording-rules.yaml`](../stack/prometheus/rules/recording-rules.yaml) —
  these patterns, materialised as reusable series

Ahmed Fakhfakh — DevOps / SRE

# Runbook: HighErrorRate

| Field | Value |
|---|---|
| Alert name | `HighErrorRate` |
| Severity | `warning` |
| Team | `orders` |
| Dashboard | http://localhost:3000/d/obs-app-red |
| SLO impact | Direct — drives the `availability` SLO and `ErrorBudgetBurn` |
| Typical time-to-mitigate | 10–20 minutes |

## 1. What this alert means

More than 5% of HTTP requests served by `orders-api` returned a 5xx status over the last
five minutes, sustained for ten minutes. This is a cause alert for the availability SLO:
a 5% error rate is a 50x burn rate against a 0.1% budget, so if this is still firing in
an hour the 14.4x rung of `ErrorBudgetBurn` will also have fired.

```promql
(
  sum by (job) (route:http_requests_errors:rate5m{job="orders-api"})
    /
  sum by (job) (route:http_requests:rate5m{job="orders-api"})
) > 0.05
```

`for: 10m`. The recording rules behind it count `http_requests_total{status=~"5.."}` as bad
and exclude the `/chaos` route template, so deliberate chaos traffic does not pollute the
numerator — but chaos injected *into* `/api/orders` absolutely does, by design.

4xx is deliberately not counted. A client sending malformed JSON is not our outage.

## 2. Impact

- Users see failed order listings and failed checkouts. `orders_processed_total{status="failed"}`
  rises in step with this alert.
- Any client without retries surfaces the error directly; clients with retries amplify load
  on an already failing service.
- Burns availability error budget at roughly `observed_ratio / 0.001` times the sustainable
  rate. At the 5% alert threshold that is 50x: the entire 30-day budget disappears in
  about 14 hours of continuous firing.

## 3. Severity and response expectation

`warning`, routed as a ticket to the `orders` team, ack within one business day. It does not
page on its own — `ErrorBudgetBurn` is the alert that decides whether this is worth waking up
for, and it will fire within the hour if the burn is real.

Treat it as an immediate incident, regardless of severity, when any of these is true:
the error rate is above 20%, `ErrorBudgetBurn` with `burn_rate="14.4"` is also active, or
`/api/checkout` is the affected route.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-app-red — RED metrics: rate, errors, duration per route.
  The "Errors by route" panel has exemplars enabled, which is the jump-off point to Tempo.
- http://localhost:3000/d/obs-logs-explorer — Loki, pre-filtered to `namespace="demo"`
- http://localhost:3000/d/obs-slo-budget — how much budget this has already cost

```promql
# Error ratio per route over the firing window.
route:http_requests_errors:rate5m{job="orders-api"}
  / route:http_requests:rate5m{job="orders-api"}
```
Bad answer: one route near `1.0` (a handler is fully broken) or every route around `0.05`
(shared dependency, pod, or node).

```promql
# Which status codes, exactly.
sum by (status) (rate(http_requests_total{job="orders-api", status=~"5.."}[5m]))
```
Bad answer: `503` means dependency or readiness; `500` means unhandled panic in our code;
a mix of `502`/`504` means something in front of the app is timing out.

```promql
# Is total traffic also abnormal?
sum(job:http_requests:rate5m{job="orders-api"})
```
Bad answer: a request rate spike concurrent with the errors — this is overload, not a bug,
and the mitigation is scale-out rather than rollback.

```logql
{namespace="demo", app="orders-api"} | json | level="ERROR"
```
Bad answer: thousands of identical `msg` values. That is a single code path failing, and the
`msg` string is your search term in the repository.

## 5. Diagnosis — metric, then trace, then log

This stack exists to make that pivot cheap. Do it in order; do not start in the logs.

1. **Metric: localise the failure to a route and a status code.**

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'topk(5, route:http_requests_errors:rate5m{job="orders-api"})'
   ```

   A single route dominating means an application bug or a dependency used only by that
   handler. Errors spread evenly across `/`, `/api/orders` and `/api/checkout` means the
   process or the node is unhealthy — jump to step 5.

2. **Trace: pivot from the metric spike to an exemplar.** On the
   [RED dashboard](http://localhost:3000/d/obs-app-red), hover the error or latency panel at
   the spike. Prometheus stores exemplars on `http_request_duration_seconds_bucket`, so each
   diamond marker carries a `trace_id`. Click it and Grafana opens the trace in Tempo using
   the `tempo` datasource UID.

   If exemplars are not visible, query Tempo directly for failed spans:

   ```bash
   kubectl -n monitoring port-forward svc/tempo 3200:3200 &
   curl -sG http://localhost:3200/api/search \
     --data-urlencode 'q={ resource.service.name="orders-api" && status=error }' \
     --data-urlencode 'limit=10' \
   | jq -r '.traces[] | [.traceID, .rootServiceName, .rootTraceName, .durationMs] | @tsv'
   ```

   In the trace, read the span tree top-down. The first span with `status=error` is where the
   failure originated; its parent is where it was observed. Note the `trace_id`.

3. **Log: use the `trace_id` to land on the exact log lines.** `trace_id` is deliberately
   **not** a Loki label — it is high cardinality and would shred the index. It stays inside
   the JSON log line, and Grafana's `derivedFields` config on the `loki` datasource
   regex-extracts it to render the "Tempo" button. To query it manually, filter after parsing:

   ```logql
   {namespace="demo", app="orders-api"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
   ```

   Replace the literal with the `trace_id` from step 2. This returns every structured log line
   emitted while handling that one request, in order, including the error `msg`, the `route`,
   the `status` and the `duration_ms`.

   The reverse direction works too — Loki's derived field turns the `trace_id` in any log line
   into a clickable link straight into Tempo, so a log found by text search gets you a trace.

4. **Generalise from the one trace to the population.** One trace tells you the mechanism;
   the aggregate tells you the scope.

   ```logql
   sum by (level) (count_over_time({namespace="demo", app="orders-api"} | json [5m]))
   ```

   `level` is promoted to a Loki label by Promtail, so `{namespace="demo", app="orders-api",
   level="ERROR"}` is the cheaper form of the filter and should be preferred for dashboards.
   The `| json | level="ERROR"` form parses first and is what you want when you need other
   JSON fields in the same query.

5. **Rule out infrastructure before blaming the code.**

   ```bash
   kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide
   kubectl -n demo describe pod -l app.kubernetes.io/name=orders-api | grep -E 'Restart|Last State|Reason|Exit Code'
   kubectl -n demo top pods -l app.kubernetes.io/name=orders-api
   ```

   Restarts, `OOMKilled`, or CPU at the limit means this alert is a downstream symptom:
   go to [ContainerOOMKilled.md](ContainerOOMKilled.md) or [PodCrashLooping.md](PodCrashLooping.md).

6. **Check for a recent change and for armed chaos.**

   ```bash
   kubectl -n demo rollout history deployment/orders-api
   kubectl -n demo get events --sort-by=.lastTimestamp | tail -20
   kubectl -n demo get deployment orders-api \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHAOS_ENABLED")].value}{"\n"}'
   ```

   A rollout inside the last 15 minutes is the suspect until proven otherwise.
   `CHAOS_ENABLED=true` plus a clean rollout history means somebody called `/chaos/errors`.

7. **Confirm the app is actually serving what Prometheus thinks it is.**

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/orders
   curl -s http://localhost:8080/metrics | grep '^http_requests_total' | sort | tail -15
   ```

   If curl returns 200 while the metric says 5%, the failure is partial — one replica out of
   several. Compare per-pod with `sum by (pod) (rate(http_requests_total{status=~"5.."}[5m]))`.

## 6. Mitigation

1. **Reset chaos** — zero blast radius, instant, and the right answer surprisingly often:

   ```bash
   curl -s "http://localhost:8080/chaos/reset"   # requires the port-forward from step 7
   make heal                                      # the scripted equivalent
   ```

2. **Roll back** — the default move if a deploy preceded the errors:

   ```bash
   kubectl rollout undo deployment/orders-api -n demo
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

   To go back further than one revision:

   ```bash
   kubectl -n demo rollout history deployment/orders-api
   kubectl -n demo rollout undo deployment/orders-api --to-revision=3
   ```

3. **Restart** — clears wedged connection pools, exhausted file descriptors and leaked state
   that a rollback would carry forward:

   ```bash
   kubectl -n demo rollout restart deployment/orders-api
   ```

4. **Scale out** — when step 4 of diagnosis showed overload rather than a bug:

   ```bash
   kubectl -n demo scale deployment/orders-api --replicas=5
   ```

5. **Evict the bad replica** — when only one pod is failing and you want evidence preserved
   on the others:

   ```bash
   kubectl -n demo delete pod <pod-name-from-step-5> --wait=false
   ```

Verify recovery on the 5m window, which reacts within two scrape intervals:

```promql
sum by (job) (route:http_requests_errors:rate5m{job="orders-api"})
  / sum by (job) (route:http_requests:rate5m{job="orders-api"})
```

## 7. If it does not resolve — escalation

Escalate to the `orders` service owner (Ahmed Fakhfakh). If diagnosis step 5 pointed at the
node or the scrape, bring in `platform` instead.

```bash
{
  echo "=== error ratio by route ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=route:http_requests_errors:rate5m{job="orders-api"} / route:http_requests:rate5m{job="orders-api"}' \
    | jq -r '.data.result[] | [.metric.route, .value[1]] | @tsv'

  echo "=== status code breakdown ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sum by (status) (rate(http_requests_total{job="orders-api"}[5m]))' \
    | jq -r '.data.result[] | [.metric.status, .value[1]] | @tsv'

  echo "=== workload ==="
  kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide
  kubectl -n demo rollout history deployment/orders-api
  kubectl -n demo get events --sort-by=.lastTimestamp | tail -30

  echo "=== recent error logs (include trace_id values) ==="
  kubectl -n demo logs deployment/orders-api --since=30m --tail=300 | grep '"level":"ERROR"'
} > high-error-rate-evidence.txt 2>&1
```

Include at least one `trace_id` in the handover. A trace ID turns a twenty-minute
re-investigation into a thirty-second one.

## 8. Prevention and follow-up

- Add the failing request shape to the k6 scenario so `make load-test` reproduces it.
- If the failure was a dependency, add a circuit breaker and make the handler return a
  degraded 200 rather than a 5xx where the product allows it.
- Confirm the `route` label stayed low cardinality during the incident — an unbounded route
  label is the fastest way to kill this Prometheus.
- If `HighErrorRate` fired but `ErrorBudgetBurn` did not, the error rate was below the
  sustainable burn. Consider whether a 5% threshold is still the right trigger, or whether
  this should simply be deleted in favour of the SLO alert.
- Verify exemplars are still flowing end to end; the metric-to-trace pivot in section 5 is
  worthless if the RED dashboard stops emitting them.

Docs: [`../docs/slo-guide.md`](../docs/slo-guide.md),
[`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md),
[`../docs/promql-cookbook.md`](../docs/promql-cookbook.md),
[`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml)
- Recording rules: [`../stack/prometheus/rules/recording-rules.yaml`](../stack/prometheus/rules/recording-rules.yaml)
- [ErrorBudgetBurn.md](ErrorBudgetBurn.md) — the SLO alert this feeds
- [HighLatencyP99.md](HighLatencyP99.md) — errors and latency usually travel together
- [PodCrashLooping.md](PodCrashLooping.md), [ContainerOOMKilled.md](ContainerOOMKilled.md) — infrastructure causes
- [TargetDown.md](TargetDown.md) — if the numbers look impossible
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

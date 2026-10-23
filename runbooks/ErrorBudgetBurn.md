# Runbook: ErrorBudgetBurn

| Field | Value |
|---|---|
| Alert name | `ErrorBudgetBurn` |
| Severity | `critical` (14.4x, 6x) / `warning` (3x, 1x) — read the `severity` label |
| Team | `orders` |
| Dashboard | http://localhost:3000/d/obs-slo-budget |
| SLO impact | Direct — this alert *is* the SLO |
| Typical time-to-mitigate | 15 min (critical rungs) / same business day (warning rungs) |

## 1. What this alert means

The service is consuming its 30-day error budget faster than the budget can afford.
This is the only alert in the repository that measures *user-visible harm against a promise*,
rather than a proxy for it. Everything else here is a cause alert; this one is the symptom.

One alert name, eight firing combinations: two SLOs (`availability`, `latency`) times four
burn-rate rungs. The rung is encoded in labels, not in the name.

```promql
# Rung 1 of 4 — the 14.4x page. Both windows must agree before it fires.
(
    job:slo_availability_errors:ratio_rate1h{job="orders-api", slo="availability"} > (14.4 * 0.001)
  and
    job:slo_availability_errors:ratio_rate5m{job="orders-api", slo="availability"} > (14.4 * 0.001)
)
```

The long window (`1h`) supplies the signal; the short window (`5m`) is the reset condition —
it makes the alert stop quickly once the burn stops, instead of smouldering for an hour.
The latency SLO uses the identical shape with `job:slo_latency_errors:ratio_rate*` and a
budget of `0.01` instead of `0.001`.

### The ladder

| burn_rate | long_window | short_window | severity | page | budget consumed over the long window | whole budget gone in |
|---|---|---|---|---|---|---|
| `14.4` | `1h` | `5m` | critical | true | 2% | ~50 hours |
| `6` | `6h` | `30m` | critical | true | 5% | 5 days |
| `3` | `1d` | `2h` | warning | false | 10% | 10 days |
| `1` | `3d` | `6h` | warning | false | 10% | 30 days |

Worked example — **burn rate 14.4**. The budget is sized for 30 days. Burning it at 14.4x
the sustainable rate exhausts it in `30 days / 14.4 = 2.08 days ≈ 50 hours`. In the one-hour
detection window the service has already spent `14.4 / 720 = 2%` of the month's entire budget,
which for the availability SLO is `0.02 x 43m12s ≈ 52 seconds` of unavailability-equivalent.
That is why it pages: left alone over a weekend, the month is gone before Monday.

Burn rate is defined as `observed_bad_ratio / error_budget_ratio`. For availability,
`error_budget_ratio = 1 - 0.999 = 0.001`, so a 1.44% error rate is exactly 14.4x.

### Reading the labels

| Label | Values | What it tells you |
|---|---|---|
| `slo` | `availability`, `latency` | Which promise is being broken. Availability means 5xx; latency means requests over 300ms on `/api/orders` and `/api/checkout`. |
| `long_window` | `1h`, `6h`, `1d`, `3d` | Detection window. Short window = urgent and sharp. |
| `short_window` | `5m`, `30m`, `2h`, `6h` | Reset window. If this one has recovered the incident is over even if the long window still looks bad. |
| `burn_rate` | `14.4`, `6`, `3`, `1` | Multiplier. Divide 720 hours by it to get time-to-exhaustion at the current rate. |
| `severity` | `critical`, `warning` | Page or ticket. |
| `page` | `true`, `false` | Alertmanager routing key. |

If 14.4x and 6x and 3x are all firing at once, that is normal and expected — a sharp burn
trips every rung below it. Respond to the highest rung and silence nothing.

## 2. Impact

- **Availability SLO**: real users are getting 5xx on `orders-api`. Checkout and order
  listing fail. `orders_processed_total{status="failed"}` is rising.
- **Latency SLO**: requests complete, but slowly. Clients with a sub-second timeout see
  failures that never appear as 5xx on our side.
- The 30-day budget is 0.1% for availability, which is **43 minutes 12 seconds** of
  full outage equivalent for the whole month. For latency the budget is 1%.
- Yes, this burns error budget by definition. The budget spent during this incident is not
  recoverable; it rolls off only as the 30-day window advances.

## 3. Severity and response expectation

| Rung | Routing | Ack | Expectation |
|---|---|---|---|
| 14.4x / 6x (`severity=critical`, `page=true`) | Pages the on-call | 5 minutes | Mitigate first, diagnose second. Rolling back a suspect deploy is always acceptable. |
| 3x / 1x (`severity=warning`, `page=false`) | Ticket for the `orders` team | 1 business day | Investigate during business hours. Do not silence it; it is telling you the service is slowly losing its budget. |

A warning rung that has been firing for days is more dangerous than a critical rung that
fired for ten minutes. The 1x/3d rung exists precisely to catch chronic low-grade burn.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-slo-budget — SLO and error budget: remaining budget gauge,
  burn-rate panels per window, budget-consumption timeline
- http://localhost:3000/d/obs-app-red — RED metrics, to see which route is responsible
- http://localhost:3000/d/obs-logs-explorer — error logs for the same window

```promql
# Remaining availability error budget, as a fraction of the month (1.0 = untouched).
1 - (job:slo_availability_errors:ratio_rate30d{job="orders-api"} / 0.001)
```
Bad answer: below `0.25`. Below `0` means the SLO is already missed for this 30-day window
and the error-budget policy is in force.

```promql
# Remaining availability budget expressed in minutes of the 43m12s monthly allowance.
43.2 * (1 - (job:slo_availability_errors:ratio_rate30d{job="orders-api"} / 0.001))
```
Bad answer: single digits. That is less than ten minutes of outage left for the month.

```promql
# Current burn rate across every window, side by side.
label_replace(job:slo_availability_errors:ratio_rate5m{job="orders-api"} / 0.001, "window", "5m",  "", "")
or label_replace(job:slo_availability_errors:ratio_rate1h{job="orders-api"} / 0.001, "window", "1h",  "", "")
or label_replace(job:slo_availability_errors:ratio_rate6h{job="orders-api"} / 0.001, "window", "6h",  "", "")
or label_replace(job:slo_availability_errors:ratio_rate1d{job="orders-api"} / 0.001, "window", "1d",  "", "")
```
Bad answer: the 5m value much higher than the 1h value — the incident is accelerating right now.

```promql
# Hours until the entire 30-day budget is exhausted at the current 1h burn rate.
(720 * (1 - (job:slo_availability_errors:ratio_rate30d{job="orders-api"} / 0.001)))
  /
(job:slo_availability_errors:ratio_rate1h{job="orders-api"} / 0.001)
```
Bad answer: under 24. You have less than a day of budget left at the current rate.

## 5. Diagnosis

1. **Identify the rung and the SLO.** Everything downstream depends on this.

   ```bash
   curl -s http://localhost:9093/api/v2/alerts \
     | jq -r '.[] | select(.labels.alertname=="ErrorBudgetBurn" and .status.state=="active")
              | [.labels.slo, .labels.burn_rate, .labels.long_window,
                 .labels.short_window, .labels.severity] | @tsv'
   ```

   Output `availability 14.4 1h 5m critical` means: the 5xx ratio has been above 1.44% for
   an hour and is still above it over the last five minutes. If only `latency` rows appear,
   the service is up and slow — skip to `HighLatencyP99.md`.

2. **Confirm the budget position.** A 14.4x burn with 90% of the budget intact is an
   incident; the same burn with 2% left is a business decision.

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     '43.2 * (1 - (job:slo_availability_errors:ratio_rate30d{job="orders-api"} / 0.001))'
   ```

   Result in minutes of remaining outage allowance. Negative means the SLO is already missed.

3. **Find the responsible route.** The SLO is job-level; the fault is almost never.

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'topk(5, route:http_requests_errors:rate5m{job="orders-api"}
             / route:http_requests:rate5m{job="orders-api"})'
   ```

   One route at ~1.0 and the rest at 0 means a single handler is broken. All routes burning
   evenly points at a shared dependency, the pod itself, or the node.

4. **Correlate with a change.** Most budget burn is self-inflicted and recent.

   ```bash
   kubectl -n demo rollout history deployment/orders-api
   kubectl -n demo get events --sort-by=.lastTimestamp | tail -30
   kubectl -n demo describe deployment/orders-api | grep -A5 'Pod Template'
   ```

   A revision timestamp within the alert's long window is your prime suspect. Deliberate
   demo breakage (`make break`) also shows up here as a changed env var or chaos call.

5. **Check whether chaos injection is still armed.** This repo ships chaos endpoints and
   it is embarrassing to debug a chaos run for twenty minutes.

   ```bash
   kubectl -n demo get deployment orders-api \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHAOS_ENABLED")].value}{"\n"}'
   kubectl -n demo logs deployment/orders-api --since=1h | grep -i chaos | tail -20
   ```

   `true` plus recent `chaos` log lines means someone (possibly a script) is injecting errors.

6. **Separate "the app is failing" from "the app is gone".**

   ```bash
   kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 'up{job="orders-api"}'
   ```

   `up == 0` while the budget burns means the scrape is broken and the SLO numerator may be
   wrong — treat it as `TargetDown` first, because a stale SLO is worse than a loud one.

7. **Pull the actual errors.** Use the trace-aware workflow documented in `HighErrorRate.md`.

   ```logql
   {namespace="demo", app="orders-api"} | json | level="ERROR"
   ```

   A single repeated `msg` across thousands of lines is a code path, not infrastructure.

## 6. Mitigation

Ordered by blast radius — the smallest reversible action first.

1. **Disarm chaos** (no restart, instant, zero risk) — if chaos is armed:

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s "http://localhost:8080/chaos/reset"
   # or, from the repo root:
   make heal
   ```

2. **Roll back the suspect deploy** (one deployment, controlled, reversible). This is the
   default move for any budget burn that starts within minutes of a rollout:

   ```bash
   kubectl rollout undo deployment/orders-api -n demo
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

   Watch the 5m burn rate, not the 1h one — it should fall within two scrape intervals.

3. **Restart the workload** (brief capacity dip) — for leaks, wedged connection pools, or
   state that a rollback would not clear:

   ```bash
   kubectl -n demo rollout restart deployment/orders-api
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

4. **Scale out** (more cost, no behaviour change) — when the burn is latency-driven and the
   pods are saturated:

   ```bash
   kubectl -n demo scale deployment/orders-api --replicas=5
   kubectl -n demo get hpa orders-api
   ```

5. **Shed or disable the failing route** (largest blast radius, do it consciously) — if one
   non-critical route is responsible for the entire burn, turning it off preserves the budget
   for checkout. Record the decision in the incident channel before you do it.

After any mitigation, verify against the short window — the long window lags by design:

```promql
job:slo_availability_errors:ratio_rate5m{job="orders-api"} / 0.001
```
This must drop below the rung's burn rate for the alert to clear.

## 7. If it does not resolve — escalation

Escalate to the `orders` service owner (Ahmed Fakhfakh) after 20 minutes on a critical rung,
or immediately if remaining budget is under 10 minutes. Bring the `platform` team in if
section 5 step 6 showed the scrape or the node is at fault rather than the app.

```bash
# Evidence pack — paste the whole block, attach the output to the incident.
{
  echo "=== active ErrorBudgetBurn alerts ==="
  curl -s http://localhost:9093/api/v2/alerts \
    | jq -r '.[] | select(.labels.alertname=="ErrorBudgetBurn")
             | [.status.state,.labels.slo,.labels.burn_rate,.labels.long_window,.startsAt] | @tsv'

  echo "=== budget position (minutes remaining of 43.2) ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=43.2 * (1 - (job:slo_availability_errors:ratio_rate30d{job="orders-api"} / 0.001))' \
    | jq -r '.data.result[].value[1]'

  echo "=== burn rates 5m/1h/6h/1d ==="
  for w in 5m 1h 6h 1d; do
    printf '%s\t' "$w"
    curl -sG http://localhost:9090/api/v1/query \
      --data-urlencode "query=job:slo_availability_errors:ratio_rate${w}{job=\"orders-api\"} / 0.001" \
      | jq -r '.data.result[].value[1]'
  done

  echo "=== errors by route ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=topk(5, route:http_requests_errors:rate5m{job="orders-api"})' \
    | jq -r '.data.result[] | [.metric.route, .value[1]] | @tsv'

  echo "=== workload state ==="
  kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide
  kubectl -n demo rollout history deployment/orders-api
  kubectl -n demo logs deployment/orders-api --since=30m --tail=200
} > error-budget-burn-evidence.txt 2>&1
```

## 8. Prevention and follow-up

The error-budget policy is what makes this alert mean something. When the 30-day availability
budget is **exhausted or projected to exhaust within 7 days**, the `orders` team:

1. **Freezes risky deploys.** Only reliability fixes, security patches and rollbacks ship.
   Feature work waits for the window to roll off.
2. **Prioritises reliability work** in the next sprint over roadmap items, with a named owner.
3. **Writes a postmortem** for any single incident that consumed more than 25% of the budget.
4. **Reviews the SLO itself** if the budget is exhausted two months running — either the
   target is wrong or the architecture cannot support it. Both are findings, not failures.

Follow-up actions after any `ErrorBudgetBurn` incident:

- Add the failure mode to the load test (`make load-test`) so the next regression is caught
  pre-production.
- Check whether a cause alert (`HighErrorRate`, `HighLatencyP99`, `ContainerOOMKilled`)
  fired *before* this one. If not, there is a detection gap worth closing.
- Confirm the recording rules still straddle the thresholds; the histogram buckets
  `0.3 / 0.4 / 0.5` exist specifically so the 300ms latency SLO is measurable.
- Record budget spend for the month in the incident log.

Docs: [`../docs/slo-guide.md`](../docs/slo-guide.md) (budget maths and window choice),
[`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md) (why only two rungs page),
[`../docs/promql-cookbook.md`](../docs/promql-cookbook.md) (burn-rate query patterns),
[`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/slo-alerts.yaml`](../stack/prometheus/rules/slo-alerts.yaml)
- Recording rules: [`../stack/prometheus/rules/recording-rules.yaml`](../stack/prometheus/rules/recording-rules.yaml)
- [HighErrorRate.md](HighErrorRate.md) — the usual cause of an `availability` burn
- [HighLatencyP99.md](HighLatencyP99.md) — the usual cause of a `latency` burn
- [PodCrashLooping.md](PodCrashLooping.md), [ContainerOOMKilled.md](ContainerOOMKilled.md) — infrastructure causes
- [TargetDown.md](TargetDown.md) — when the SLO numbers themselves cannot be trusted
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

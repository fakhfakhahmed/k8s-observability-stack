# Runbooks

An alert without a response procedure is a pager that wakes someone up to say "good luck".
Every alert rule in this repository carries a `runbook_url` annotation pointing into this
directory, so the first link in the Alertmanager notification is the procedure that resolves it.

That link is not decoration. It is the contract we make with the person on call:

- The alert tells you **what** broke.
- The runbook tells you **what it costs**, **what to look at first**, and **what to do about it**.
- The dashboard tells you **where** in the system it broke.

A rule that cannot be given a non-trivial runbook is usually a rule that should not page.
If you find yourself writing "investigate the logs" as the entire mitigation section, delete
the alert or downgrade it to a ticket. See [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md).

## Conventions used by every runbook here

| Convention | Value |
|---|---|
| Runbook URL base | `https://github.com/fakhfakhahmed/k8s-observability-stack/blob/main/runbooks/` |
| Dashboard URL base | `http://localhost:3000/d/<uid>` (via `make port-forward`) |
| App namespace | `demo` (deployment/service `orders-api`, port `8080`) |
| Platform namespace | `monitoring` (Prometheus, Alertmanager, Grafana, Loki, Promtail, Tempo) |
| Prometheus `job` label for the app | `orders-api` |
| Teams | `platform` (infrastructure) and `orders` (application and SLO) |
| Critical / `page=true` | Ack within 5 minutes, 24x7 |
| Warning / `page=false` | Ticket, ack within one business day |

Before anything else, open the port-forwards:

```bash
# Grafana :3000, Prometheus :9090, Alertmanager :9093, orders-api :8080
make port-forward
```

## Alert index

All alerts, including the ones that do not have a dedicated runbook.

| Alert name | Severity | Fires when (one line) | Runbook | Defined in |
|---|---|---|---|---|
| `ErrorBudgetBurn` | critical / warning | A multi-window burn-rate rung (14.4x/6x/3x/1x) trips for the `availability` or `latency` SLO | [ErrorBudgetBurn.md](ErrorBudgetBurn.md) | [`slo-alerts.yaml`](../stack/prometheus/rules/slo-alerts.yaml) |
| `HighErrorRate` | warning | 5xx ratio for `orders-api` exceeds 5% of requests for 10m | [HighErrorRate.md](HighErrorRate.md) | [`alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml) |
| `HighLatencyP99` | warning | p99 request duration for `orders-api` exceeds 500ms for 10m | [HighLatencyP99.md](HighLatencyP99.md) | [`alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml) |
| `PodCrashLooping` | critical | A container in `demo` restarts more than 3 times in 15m | [PodCrashLooping.md](PodCrashLooping.md) | [`alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml) |
| `PodNotReady` | warning | An `orders-api` pod has not reached `Ready` for 10m | No dedicated runbook — start with [PodCrashLooping.md](PodCrashLooping.md) (probe and image-pull sections apply) | [`alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml) |
| `QueueDepthGrowing` | warning | `queue_depth` stays above 100 and keeps rising for 15m | No dedicated runbook — see rule comments; drain path is the scale-out step in [HighLatencyP99.md](HighLatencyP99.md) | [`alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml) |
| `NoTrafficReceived` | warning | `orders-api` serves fewer than 0.01 req/s for 15m | No dedicated runbook — this is usually a scrape or ingress problem, see [TargetDown.md](TargetDown.md) | [`alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml) |
| `TargetDown` | critical | A Prometheus target in `demo` or `monitoring` reports `up == 0` for 5m | [TargetDown.md](TargetDown.md) | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `ContainerOOMKilled` | critical | A container's last termination reason is `OOMKilled` | [ContainerOOMKilled.md](ContainerOOMKilled.md) | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `NodeMemoryPressure` | warning | Node memory utilisation above 85% for 10m | [NodeMemoryPressure.md](NodeMemoryPressure.md) | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `PVCNearlyFull` | warning | A PVC has less than 15% of its capacity available for 15m | [PVCNearlyFull.md](PVCNearlyFull.md) | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `NodeDiskSpaceLow` | critical | Node root filesystem has less than 10% available for 10m | No dedicated runbook — the eviction and cleanup steps in [NodeMemoryPressure.md](NodeMemoryPressure.md) and the growth analysis in [PVCNearlyFull.md](PVCNearlyFull.md) apply | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `KubePodNotReady` | warning | Any pod in `demo` or `monitoring` is `Pending`/`Unknown` for 15m | No dedicated runbook — see rule comments; use [PodCrashLooping.md](PodCrashLooping.md) section 5 | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `HPAMaxedOut` | warning | An HPA has sat at `maxReplicas` for 15m | No dedicated runbook — see rule comments; raising `maxReplicas` is the mitigation in [HighLatencyP99.md](HighLatencyP99.md) | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `CertificateExpiringSoon` | warning | A tracked TLS certificate is within 21 days of expiry | No dedicated runbook — see rule comments; rotate the secret and restart the consuming workload | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |
| `Watchdog` | none | Always firing — the deadman's switch that proves the pipeline is alive | No runbook. If `Watchdog` stops arriving at the receiver, the monitoring stack is down: see [TargetDown.md](TargetDown.md) | [`alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml) |

`ErrorBudgetBurn` is one alert name with eight firing combinations
(`slo` x four burn-rate rungs). Read the `slo`, `long_window`, `short_window` and `burn_rate`
labels before you do anything else — they tell you how urgent it is.

## The first 60 seconds, for any alert

1. Read the `description` annotation. It already contains the offending label set and value.
2. Open the `dashboard_url` from the annotation; do not go hunting in the dashboard list.
3. Check whether `ErrorBudgetBurn` is also firing. If it is, user impact is real and measured,
   not theoretical.
4. Check for a concurrent deploy:

   ```bash
   kubectl -n demo rollout history deployment/orders-api
   ```

5. If this cluster was deliberately broken for a demo (`make break` /
   `scripts/trigger-incident.ps1`), the fastest mitigation is `make heal`.

```bash
# Is anything else firing right now?
curl -s http://localhost:9093/api/v2/alerts \
  | jq -r '.[] | select(.status.state=="active")
           | [.labels.alertname, .labels.severity, .labels.slo // "-"] | @tsv'
```

## Runbook template

Copy this skeleton when you add a runbook. Keep the numbering and the headings identical —
tooling and muscle memory both depend on it.

```markdown
# Runbook: <AlertName>

| Field | Value |
|---|---|
| Alert name | `<AlertName>` |
| Severity | `critical` / `warning` |
| Team | `platform` / `orders` |
| Dashboard | http://localhost:3000/d/<uid> |
| SLO impact | Direct / Indirect / None |
| Typical time-to-mitigate | <n> minutes |

## 1. What this alert means
## 2. Impact
## 3. Severity and response expectation
## 4. Dashboards and queries to open first
## 5. Diagnosis
## 6. Mitigation
## 7. If it does not resolve — escalation
## 8. Prevention and follow-up
## Related
```

Rules for a good runbook in this repo:

- Every command must be runnable as written. No placeholders, no `<your-pod>` where a
  selector would do.
- Every query must say what a *bad* answer looks like, not just what it returns.
- Mitigations are ordered by blast radius: the smallest, most reversible action first.
- The escalation section contains a single copy-pasteable evidence block, because nobody
  composes a good handover at 03:00.

## Reference docs

- [`../docs/slo-guide.md`](../docs/slo-guide.md) — SLO definitions, error-budget maths, burn-rate ladder
- [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md) — symptom alerts, why cause alerts are tickets
- [`../docs/promql-cookbook.md`](../docs/promql-cookbook.md) — the queries used throughout these runbooks
- [`../LEARN.md`](../LEARN.md) — guided tour of the whole stack
- [`../stack/prometheus/rules/recording-rules.yaml`](../stack/prometheus/rules/recording-rules.yaml) — the `level:metric:operations` series every runbook queries

Ahmed Fakhfakh — DevOps / SRE

# Runbook: TargetDown

| Field | Value |
|---|---|
| Alert name | `TargetDown` |
| Severity | `critical` |
| Team | `platform` |
| Dashboard | http://localhost:3000/d/obs-k8s-cluster |
| SLO impact | Direct on measurement — a missing target means the SLO is computed from incomplete data |
| Typical time-to-mitigate | 10–20 minutes |

## 1. What this alert means

Prometheus cannot scrape a target in `demo` or `monitoring`, and has not been able to for
five minutes. Either the thing being scraped is down, or the scrape path between Prometheus
and a perfectly healthy thing is broken.

```promql
up{namespace=~"demo|monitoring"} == 0
```

`for: 5m`. The `up` series is synthetic: Prometheus writes `1` on a successful scrape and `0`
on a failed one, per target, every scrape interval. If the series disappears entirely rather
than going to zero, the target is no longer *discovered* at all — a different and more common
failure, covered in section 5 step 3 onwards.

This distinction is the whole runbook:

| Symptom | Meaning |
|---|---|
| `up == 0` | Target is discovered but the scrape fails: connection refused, timeout, 404, TLS error. |
| `up` series absent | Target is not discovered: ServiceMonitor not selected, label missing, Service selector wrong. |

## 2. Impact

- Metrics for that target stop. Gaps appear in every dashboard panel that uses them.
- Rules evaluated over the missing series produce no data. Alerts that depend on them stop
  firing — **silently**. A down target can hide an outage.
- If the down target is `orders-api`, the SLO recording rules
  (`job:slo_availability_errors:ratio_rate*`) receive no samples, and `ErrorBudgetBurn`
  cannot fire no matter how badly the service is doing.
- `NoTrafficReceived` typically fires alongside this, for the same reason.

The error budget is not burned by this alert, but trust in the budget number is.

## 3. Severity and response expectation

`critical`, pages the on-call, ack within 5 minutes, 24x7. Blind monitoring is treated as an
outage in this repository, because every other alert's reliability depends on it. The
`Watchdog` alert exists for the same reason one level up: if `Watchdog` stops arriving at the
receiver, Prometheus or Alertmanager itself is gone.

## 4. Dashboards and queries to open first

- http://localhost:9090/targets — the Prometheus targets page. Read the "Last Error" column
  before anything else; it usually contains the whole answer.
- http://localhost:9090/service-discovery — shows discovered targets and, crucially, the ones
  that were **dropped** by relabelling
- http://localhost:3000/d/obs-k8s-cluster — pod health for the same workload

```promql
# Everything currently down.
up{namespace=~"demo|monitoring"} == 0
```
Bad answer: more than one job. That points at Prometheus or the network, not at one app.

```promql
# Is the app target discovered at all?
up{job="orders-api"}
```
Bad answer: empty result. Not "down" — *absent*. Go to section 5 step 3.

```promql
# How long has each target been failing?
time() - max by (job, instance) (timestamp(up == 1))
```
Bad answer: a value larger than the time since the last deploy — this did not start with your
change.

```promql
# Is Prometheus itself healthy enough to scrape?
scrape_duration_seconds{namespace=~"demo|monitoring"}
```
Bad answer: values near the scrape timeout (default 10s). Prometheus is timing out, not being
refused, which points at a slow `/metrics` handler or an overloaded node.

## 5. Diagnosis

1. **Read the scrape error.** The targets page or the API gives you the exact failure string.

   ```bash
   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | select(.health!="up")
              | [.labels.job, .labels.namespace, .scrapeUrl, .lastError] | @tsv'
   ```

   | Last error | Meaning | Next step |
   |---|---|---|
   | `connection refused` | Nothing listening on that port in the pod | step 2 |
   | `i/o timeout` / `context deadline exceeded` | Reachable but no reply — usually a NetworkPolicy or a hung handler | step 6 |
   | `server returned HTTP status 404` | Wrong `path`; `/metrics` is not where you asked | step 4 |
   | `no such host` | Service or endpoint gone | step 2 |
   | (target absent entirely) | Not discovered | step 3 |

2. **Is the workload actually running and serving metrics?**

   ```bash
   kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide
   kubectl -n demo get endpoints orders-api
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s http://localhost:8080/metrics | head -20
   ```

   Empty `ENDPOINTS` means the Service's selector matches no ready pods — the Service, not
   Prometheus, is the problem. If `/metrics` responds on 8080 but Prometheus cannot reach it,
   the app is fine and the path is broken.

3. **Gotcha 1 — `serviceMonitorSelectorNilUsesHelmValues`.** This is the single most common
   reason a ServiceMonitor is ignored in a kube-prometheus-stack install.

   When the Prometheus CR's `serviceMonitorSelector` is left nil, the chart defaults to
   selecting **only** ServiceMonitors carrying `release: kube-prometheus-stack`. Your
   perfectly valid ServiceMonitor is simply never looked at, and there is no error anywhere.

   ```bash
   # What is the operator actually selecting?
   kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
     -o jsonpath='{.spec.serviceMonitorSelector}{"\n"}{.spec.serviceMonitorNamespaceSelector}{"\n"}'
   ```

   `{}` (empty object) means "select everything". A `matchLabels` block means only matching
   ServiceMonitors count. The fix is one of two things, both in `stack/prometheus/values.yaml`:

   ```yaml
   # Option A: let Prometheus pick up every ServiceMonitor in every namespace.
   prometheus:
     prometheusSpec:
       serviceMonitorSelectorNilUsesHelmValues: false
       serviceMonitorNamespaceSelector: {}
       podMonitorSelectorNilUsesHelmValues: false
       ruleSelectorNilUsesHelmValues: false
   ```

   ```yaml
   # Option B: keep the selector and label the ServiceMonitor to match.
   metadata:
     labels:
       release: kube-prometheus-stack
   ```

   This repo uses Option A plus the label, belt and braces.

4. **Gotcha 2 — the missing `release` label and the wrong port name.** Check both in one pass.

   ```bash
   kubectl -n demo get servicemonitor orders-api -o yaml
   kubectl -n demo get servicemonitor orders-api -o jsonpath='{.metadata.labels}{"\n"}'
   kubectl -n demo get svc orders-api -o jsonpath='{.spec.ports}{"\n"}'
   ```

   Three things must line up exactly:

   | ServiceMonitor field | Must match |
   |---|---|
   | `metadata.labels.release` | `kube-prometheus-stack` (if the selector is not empty) |
   | `spec.selector.matchLabels` | the labels on the **Service** `orders-api`, not on the pods |
   | `spec.endpoints[].port` | the **name** of the Service port — `http`, not the number `8080` |

   `spec.endpoints[].port` taking a port *name* is the trap. Writing `port: 8080` silently
   matches nothing; use `port: http`, or switch to `targetPort: 8080`. The Service in this
   repo names its port `http` and serves metrics on the same port at `/metrics`.

   Also confirm the namespace scoping:

   ```bash
   kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
     -o jsonpath='{.spec.serviceMonitorNamespaceSelector}{"\n"}'
   ```

   A non-empty namespace selector that does not match `demo` means the ServiceMonitor is
   invisible regardless of its own labels.

5. **Confirm what service discovery produced.** This separates "not selected" from "selected
   and then dropped by relabelling".

   ```bash
   curl -s http://localhost:9090/api/v1/targets?state=dropped \
     | jq -r '.data.droppedTargets[] | .discoveredLabels["__meta_kubernetes_service_name"]' \
     | sort -u | head -20

   # and the operator's own view
   kubectl -n monitoring logs statefulset/prometheus-kube-prometheus-stack-prometheus -c config-reloader --tail=50
   kubectl -n monitoring logs deployment/kube-prometheus-stack-operator --tail=100 | grep -i 'orders-api\|servicemonitor'
   ```

   Appearing under dropped targets means it *was* discovered and a relabel rule removed it.
   Absent from both active and dropped means it was never selected — back to step 3.

6. **Gotcha 3 — NetworkPolicy blocking the scrape.** A default-deny policy in `demo` blocks
   Prometheus just as effectively as it blocks an attacker, and the symptom is a timeout
   rather than a refusal.

   ```bash
   kubectl -n demo get networkpolicy
   kubectl -n demo describe networkpolicy
   ```

   Any policy with `policyTypes: [Ingress]` and no rule allowing the `monitoring` namespace
   will break scraping. Test reachability from inside the monitoring namespace:

   ```bash
   kubectl -n monitoring run scrape-test --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
     curl -sv --max-time 5 http://orders-api.demo.svc.cluster.local:8080/metrics
   ```

   Success from `monitoring` but failure from Prometheus means the policy allows the
   namespace but not the Prometheus pod labels. The allow rule needs a `namespaceSelector`
   matching `monitoring`:

   ```yaml
   ingress:
     - from:
         - namespaceSelector:
             matchLabels:
               kubernetes.io/metadata.name: monitoring
       ports:
         - port: 8080
           protocol: TCP
   ```

7. **Validate the generated scrape config.** The operator renders ServiceMonitors into
   Prometheus's config; read what it actually produced.

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     sh -c 'grep -A15 "job_name.*orders-api" /etc/prometheus/config_out/prometheus.env.yaml'
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool check config /etc/prometheus/config_out/prometheus.env.yaml
   ```

   No matching `job_name` means the ServiceMonitor never made it into the config — this is
   the definitive confirmation of a selector problem (steps 3 and 4).

8. **Rule out Prometheus itself.** If many targets are down at once, stop debugging the app.

   ```bash
   kubectl -n monitoring get pods
   kubectl -n monitoring top pods --containers | grep prometheus
   kubectl -n monitoring logs statefulset/prometheus-kube-prometheus-stack-prometheus -c prometheus --tail=100 \
     | grep -i 'error\|no space\|out of memory'
   ```

   A full TSDB volume or an OOM-killed Prometheus produces exactly this alert across every
   job — see [PVCNearlyFull.md](PVCNearlyFull.md) and [ContainerOOMKilled.md](ContainerOOMKilled.md).

## 6. Mitigation

1. **Restart the workload** — smallest action, fixes a wedged `/metrics` handler:

   ```bash
   kubectl -n demo rollout restart deployment/orders-api
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

2. **Fix the ServiceMonitor label** — no restart needed; the operator reconciles in seconds:

   ```bash
   kubectl -n demo label servicemonitor orders-api release=kube-prometheus-stack --overwrite
   ```

3. **Fix the port name** — the other half of step 4:

   ```bash
   kubectl -n demo patch servicemonitor orders-api --type=json \
     -p='[{"op":"replace","path":"/spec/endpoints/0/port","value":"http"}]'
   ```

4. **Relax the selectors** — apply via Helm so the change is in source control, not a patch:

   ```bash
   helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     -n monitoring -f stack/prometheus/values.yaml
   kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=300s
   ```

5. **Allow the scrape through the NetworkPolicy** — edit the policy in
   `stack/` or `k8s/` and reapply. Deleting the policy outright is faster but removes a
   security control; do it only to confirm the hypothesis, and restore it immediately:

   ```bash
   kubectl -n demo delete networkpolicy <name>   # diagnostic only
   ```

6. **Force a Prometheus config reload** — when the operator has rendered the right config but
   Prometheus has not picked it up:

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     curl -s -X POST http://localhost:9090/-/reload
   ```

7. **Restart Prometheus** — largest blast radius: it drops the in-memory head block window
   that has not been written to disk and creates a real metrics gap:

   ```bash
   kubectl -n monitoring rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus
   ```

Verify:

```promql
up{job="orders-api"} == 1
```
and confirm the targets page shows `UP` with a recent "Last Scrape".

## 7. If it does not resolve — escalation

`platform` owns Prometheus and the ServiceMonitor plumbing (Ahmed Fakhfakh). Involve `orders`
only if the `/metrics` endpoint itself is broken in application code.

```bash
{
  echo "=== unhealthy targets and their errors ==="
  curl -s http://localhost:9090/api/v1/targets \
    | jq -r '.data.activeTargets[] | select(.health!="up")
             | [.labels.job, .labels.namespace, .scrapeUrl, .health, .lastError] | @tsv'

  echo "=== up series ==="
  curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up' \
    | jq -r '.data.result[] | [.metric.job, .metric.namespace, .metric.instance, .value[1]] | @tsv'

  echo "=== prometheus selectors ==="
  kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
    -o jsonpath='SM selector: {.spec.serviceMonitorSelector}{"\n"}NS selector: {.spec.serviceMonitorNamespaceSelector}{"\n"}'

  echo "=== servicemonitor ==="
  kubectl -n demo get servicemonitor -o yaml

  echo "=== service, endpoints, pods ==="
  kubectl -n demo get svc orders-api -o yaml
  kubectl -n demo get endpoints orders-api -o yaml
  kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide

  echo "=== networkpolicies ==="
  kubectl -n demo get networkpolicy -o yaml

  echo "=== rendered scrape config ==="
  kubectl -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    sh -c 'grep -A20 "orders-api" /etc/prometheus/config_out/prometheus.env.yaml'

  echo "=== operator logs ==="
  kubectl -n monitoring logs deployment/kube-prometheus-stack-operator --tail=100
} > target-down-evidence.txt 2>&1
```

## 8. Prevention and follow-up

- Keep `serviceMonitorSelectorNilUsesHelmValues: false` (and the Pod/Probe/Rule equivalents)
  in `stack/prometheus/values.yaml`, and also label every ServiceMonitor with
  `release: kube-prometheus-stack`. Either alone works; both together survive a values
  refactor.
- Add a CI check that every Service with a `/metrics` endpoint has a matching ServiceMonitor
  whose `port` is a name present on that Service.
- Keep `Watchdog` routed to a receiver that someone notices. A deadman's switch nobody
  monitors is decoration.
- Write NetworkPolicies with an explicit allow for the `monitoring` namespace from the start,
  as part of the same manifest that introduces the deny.
- Add the `up == 1` assertion to the smoke test in `scripts/deploy-app.ps1` so a broken
  ServiceMonitor fails the deploy instead of silently producing a blind spot.
- Review whether `absent(up{job="orders-api"})` deserves its own rule — `up == 0` cannot
  catch a target that was never discovered.

Docs: [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md) (why blind monitoring
is an outage), [`../docs/promql-cookbook.md`](../docs/promql-cookbook.md) (`up`, `absent`,
staleness), [`../docs/slo-guide.md`](../docs/slo-guide.md), [`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml)
- [PodCrashLooping.md](PodCrashLooping.md) — a looping pod is also a missing target
- [ContainerOOMKilled.md](ContainerOOMKilled.md) — an OOM-killed Prometheus takes every target down
- [PVCNearlyFull.md](PVCNearlyFull.md) — a full TSDB stops scraping
- [ErrorBudgetBurn.md](ErrorBudgetBurn.md) — why a missing target invalidates the budget
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

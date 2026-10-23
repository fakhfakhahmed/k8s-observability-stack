# Runbook: PVCNearlyFull

| Field | Value |
|---|---|
| Alert name | `PVCNearlyFull` |
| Severity | `warning` |
| Team | `platform` |
| Dashboard | http://localhost:3000/d/obs-k8s-cluster |
| SLO impact | Indirect — a full Prometheus or Loki volume blinds the SLO measurement itself |
| Typical time-to-mitigate | 20–40 minutes |

## 1. What this alert means

A PersistentVolumeClaim has less than 15% of its capacity available and has stayed there for
fifteen minutes. The 15% threshold is chosen to leave time to act: Prometheus and Loki both
degrade badly when the volume fills, and a full TSDB volume can corrupt the head block.

```promql
(
  kubelet_volume_stats_available_bytes{namespace=~"monitoring|demo"}
    /
  kubelet_volume_stats_capacity_bytes{namespace=~"monitoring|demo"}
) < 0.15
```

`for: 15m`. These two series come from the kubelet, not from node-exporter, and they carry
the `persistentvolumeclaim` label — which is what makes the alert actionable rather than
just "a disk somewhere is full".

The usual culprit in this stack is **Prometheus TSDB retention**. The chart default keeps
more history than a demo volume can hold, and the volume fills on a predictable schedule.

## 2. Impact

| PVC | What breaks when it fills |
|---|---|
| Prometheus TSDB | Writes fail, the head block cannot be compacted, metrics stop. All SLO numbers freeze and every other alert becomes untrustworthy. |
| Loki | Log ingestion stops. Promtail backs up, then drops. The metric-to-trace-to-log workflow loses its last leg. |
| Tempo | Trace ingestion stops. Exemplar links from Grafana resolve to nothing. |
| Any app PVC in `demo` | Writes fail; the app's behaviour depends on how it handles ENOSPC, usually badly. |

No direct error-budget burn, but a full Prometheus volume means you stop *measuring* the
error budget — which is strictly worse than burning it, because you no longer know.

## 3. Severity and response expectation

`warning`, ticketed to `platform`, ack within one business day. Escalate to incident handling
when `predict_linear` says the volume fills within 4 hours, when availability is already
below 5%, or when the affected PVC belongs to Prometheus.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-k8s-cluster — PVC usage panels, per-claim
- http://localhost:3000/d/obs-logs-explorer — ingestion errors from Loki or Promtail
- http://localhost:3000/d/obs-slo-budget — confirm SLO series are still being recorded

```promql
# Used fraction per PVC, worst first.
1 - (
  kubelet_volume_stats_available_bytes
    / kubelet_volume_stats_capacity_bytes
)
```
Bad answer: above `0.85` on a Prometheus or Loki claim.

```promql
# Free bytes in absolute terms — percentages lie on small volumes.
kubelet_volume_stats_available_bytes{namespace="monitoring"}
```
Bad answer: under 1GB on the Prometheus TSDB claim. A compaction needs scratch space roughly
the size of the blocks being merged.

```promql
# Hours until full, extrapolating the last 6 hours of growth.
predict_linear(kubelet_volume_stats_available_bytes[6h], 4 * 3600) < 0
```
Any series returned means that PVC is predicted to hit zero within 4 hours. Change the
`4 * 3600` to `24 * 3600` for a one-day horizon. `predict_linear` uses simple linear
regression over the range — it is honest about steady growth and useless for bursty growth,
so sanity-check it against the graph.

```promql
# Growth rate in bytes per hour (negative available = filling).
- deriv(kubelet_volume_stats_available_bytes{namespace="monitoring"}[6h]) * 3600
```
Bad answer: a rate that, divided into current free space, gives fewer hours than your
response time.

## 5. Diagnosis

1. **Identify the claim, its size and its consumer.**

   ```bash
   kubectl get pvc -A
   kubectl -n monitoring get pvc -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.storage,SC:.spec.storageClassName,VOLUME:.spec.volumeName'
   kubectl -n monitoring describe pvc prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
   ```

   The `Used By` line in `describe` names the pod. On minikube the StorageClass is
   `standard`, backed by the `storage-provisioner` addon writing to the node's filesystem —
   so a full PVC and a full node disk are closely related.

2. **Get the exact numbers from the kubelet metrics, not from `df` guesses.**

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'sort(1 - (kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes))'
   ```

   The `persistentvolumeclaim` label on each result tells you exactly which claim to fix.

3. **Project the time to full.**

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'predict_linear(kubelet_volume_stats_available_bytes{namespace="monitoring"}[6h], 24 * 3600)'
   ```

   A negative value means that claim is predicted to be full within 24 hours. A large positive
   value means growth is slow and you can fix this properly rather than urgently.

4. **Check Prometheus retention — the default suspect.**

   ```bash
   kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
     -o jsonpath='{.spec.retention}{"\t"}{.spec.retentionSize}{"\n"}'
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     df -h /prometheus
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     du -sh /prometheus/* 2>/dev/null | sort -h | tail -10
   ```

   `retention: 10d` on a 10GB volume with this stack's series count will fill it. If
   `retentionSize` is empty, Prometheus has no size-based safety net at all — set one.
   `wal/` growing without bound means compaction is failing, usually for lack of scratch space.

5. **Check series growth, which is what actually drives TSDB size.**

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 'prometheus_tsdb_head_series'
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'topk(10, count by (__name__) ({__name__=~".+"}))'
   ```

   A metric name with a disproportionate series count is a cardinality bug. Disk is the
   symptom; the label is the cause. Fixing retention without fixing cardinality buys days,
   not months.

6. **Check Loki and Tempo if the claim is theirs.**

   ```bash
   kubectl -n monitoring get pvc | grep -E 'loki|tempo'
   kubectl -n monitoring exec -it deploy/loki -- df -h /var/loki 2>/dev/null \
     || kubectl -n monitoring exec -it statefulset/loki -- df -h /var/loki
   kubectl -n monitoring logs deployment/promtail --tail=100 | grep -i 'error\|429\|full'
   ```

   `429` from Loki in Promtail's logs means ingestion limits, not disk. ENOSPC in Loki's own
   logs means the volume.

7. **Check the node's own disk, because the PV lives on it.**

   ```bash
   minikube ssh -- df -h /
   kubectl describe node | grep -A8 'Conditions:'
   ```

   `DiskPressure  True` means `NodeDiskSpaceLow` is also firing and the node will start
   garbage-collecting images and evicting pods. Fix the node first; PVC resizing will not
   help if the underlying filesystem is full.

## 6. Mitigation

1. **Reduce Prometheus retention** — fastest reclaim, costs only query history. Set both a
   time and a size bound; the size bound is the one that actually protects the volume:

   ```bash
   kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge \
     -p '{"spec":{"retention":"3d","retentionSize":"4GB"}}'
   kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=180s
   ```

   Deletion is not instant — Prometheus removes whole blocks on the next compaction cycle.
   Expect reclaim within one to two hours, not seconds.

2. **Reduce Loki retention** — same idea on the logs side:

   ```bash
   kubectl -n monitoring get configmap loki -o yaml | grep -A6 'retention_period\|compactor'
   helm upgrade loki grafana/loki -n monitoring -f stack/loki/values.yaml \
     --set loki.limits_config.retention_period=72h
   ```

3. **Delete obviously disposable data** — larger blast radius, irreversible. Only on a
   non-production claim, and only when you know what you are deleting:

   ```bash
   kubectl -n monitoring exec -it deploy/tempo -- sh -c 'du -sh /var/tempo/* | sort -h'
   ```

4. **Expand the PVC** — the proper fix if the data is legitimately needed. Requires a
   StorageClass with `allowVolumeExpansion: true`:

   ```bash
   kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}{"\n"}'
   # enable it if false (minikube's default provisioner supports expansion)
   kubectl patch storageclass standard --type=merge -p '{"allowVolumeExpansion":true}'

   # request more space
   kubectl -n monitoring patch pvc \
     prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
     --type=merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

   # watch the resize condition
   kubectl -n monitoring describe pvc \
     prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
     | sed -n '/Conditions:/,/Events:/p'
   ```

   If the condition sticks on `FileSystemResizePending`, the filesystem grows only when the
   pod restarts:

   ```bash
   kubectl -n monitoring rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus
   ```

   PVCs can only grow, never shrink. Choose the new size deliberately.

5. **Grow the node disk** — minikube only, recreates the cluster. Use when every claim is
   constrained by the same underlying filesystem:

   ```bash
   minikube stop
   minikube start --cpus=4 --memory=8192 --disk-size=40g --driver=docker
   ```

6. **Fix the cardinality** — the only mitigation that actually ends the problem. Drop the
   offending series at scrape time in `stack/prometheus/values.yaml` via `metricRelabelings`,
   then redeploy:

   ```bash
   helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     -n monitoring -f stack/prometheus/values.yaml
   ```

Verify:

```promql
1 - (kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes)
```
Should drop below `0.80`, and `predict_linear(...[6h], 24*3600)` should return no negative
series.

## 7. If it does not resolve — escalation

`platform` owns storage (Ahmed Fakhfakh). If the growth is driven by application metrics or
log volume, bring in `orders` to reduce what is being emitted.

```bash
{
  echo "=== PVC inventory ==="
  kubectl get pvc -A -o wide
  kubectl get pv

  echo "=== used fraction per claim ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sort(1 - (kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes))' \
    | jq -r '.data.result[] | [.metric.namespace, .metric.persistentvolumeclaim, .value[1]] | @tsv'

  echo "=== free bytes ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=kubelet_volume_stats_available_bytes' \
    | jq -r '.data.result[] | [.metric.persistentvolumeclaim, .value[1]] | @tsv'

  echo "=== 24h fill prediction (negative = will be full) ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=predict_linear(kubelet_volume_stats_available_bytes[6h], 24*3600)' \
    | jq -r '.data.result[] | [.metric.persistentvolumeclaim, .value[1]] | @tsv'

  echo "=== prometheus retention and series ==="
  kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o jsonpath='{.spec.retention}{"\t"}{.spec.retentionSize}{"\n"}'
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=prometheus_tsdb_head_series' | jq -r '.data.result[].value[1]'

  echo "=== node disk ==="
  minikube ssh -- df -h /
  kubectl describe node | grep -A8 'Conditions:'
} > pvc-nearly-full-evidence.txt 2>&1
```

## 8. Prevention and follow-up

- Always set `retentionSize` alongside `retention` on Prometheus. Time-based retention alone
  gives no protection when series count grows.
- Set a Loki `retention_period` and enable the compactor with retention deletion; the default
  configuration keeps chunks indefinitely.
- Enable `allowVolumeExpansion` on the StorageClass before you need it. Discovering it is
  disabled during an incident costs a cluster rebuild.
- Add a `predict_linear` based forecast panel to the cluster dashboard so the team sees the
  trend a week out, not the threshold crossing on the day.
- Treat cardinality as a capacity metric. Keep `route`, `status` and `level` label values
  bounded; they are the three in this stack with any real growth potential.
- Size `--disk-size=40g` at cluster creation, per the documented minimum.

Docs: [`../docs/promql-cookbook.md`](../docs/promql-cookbook.md) (`predict_linear` and
capacity-forecasting recipes), [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md),
[`../docs/slo-guide.md`](../docs/slo-guide.md), [`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml)
- [NodeMemoryPressure.md](NodeMemoryPressure.md) — same minikube sizing root cause
- [TargetDown.md](TargetDown.md) — what you see when a full Prometheus stops working
- [ContainerOOMKilled.md](ContainerOOMKilled.md) — cardinality costs memory before it costs disk
- [ErrorBudgetBurn.md](ErrorBudgetBurn.md) — budget cannot be measured without the TSDB
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

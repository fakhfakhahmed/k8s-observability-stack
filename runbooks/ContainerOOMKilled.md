# Runbook: ContainerOOMKilled

| Field | Value |
|---|---|
| Alert name | `ContainerOOMKilled` |
| Severity | `critical` |
| Team | `platform` |
| Dashboard | http://localhost:3000/d/obs-k8s-cluster |
| SLO impact | Indirect — a killed container drops in-flight requests and burns availability budget |
| Typical time-to-mitigate | 10–15 minutes |

## 1. What this alert means

The kernel's OOM killer sent SIGKILL to a container because it exceeded its cgroup memory
limit. There is no graceful shutdown, no draining, no SIGTERM — every in-flight request on
that container is lost. Kubernetes restarts it and, unless the cause is fixed, it will happen
again.

```promql
(
    increase(kube_pod_container_status_restarts_total{namespace=~"demo|monitoring"}[10m]) > 0
  and on (namespace, pod, container)
    kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
)
```

The `and on (...)` join is what makes this specific: a restart alone is `PodCrashLooping`;
a restart *whose last termination reason was OOMKilled* is this alert. Exit code is `137`
(128 + SIGKILL 9).

Important distinction: this is a **container limit** kill, enforced by the cgroup. It is not
the same as node-level memory exhaustion, which evicts pods instead —
see [NodeMemoryPressure.md](NodeMemoryPressure.md).

## 2. Impact

- Every request in flight on that container fails, with no 5xx recorded by the app itself
  (the process died before it could respond). The client sees a connection reset.
- Repeated OOM kills become a crash loop, and capacity drops.
- Burns availability error budget: the dropped connections never reach
  `http_requests_total`, so the damage is under-counted by our own metrics — another reason
  to take this seriously even when the RED dashboard looks calm.
- If the OOM-killed container is in `monitoring` (Prometheus, Loki, Tempo), observability
  itself is degraded and the other alerts become unreliable.

## 3. Severity and response expectation

`critical`, pages the on-call, ack within 5 minutes, 24x7. A single OOM kill is data loss;
a repeated one is an outage. Raising the limit is an acceptable immediate mitigation, but it
is not the fix — section 8 is not optional for this alert.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-k8s-cluster — container memory working set vs limit, restarts
- http://localhost:3000/d/obs-app-red — whether user traffic noticed
- http://localhost:3000/d/obs-logs-explorer — the last log lines before the kill

```promql
# Memory headroom per container, as a fraction of its limit.
container_memory_working_set_bytes{namespace="demo", container="orders-api"}
  / on (namespace, pod, container)
kube_pod_container_resource_limits{namespace="demo", container="orders-api", resource="memory"}
```
Bad answer: above `0.9`. The container is one allocation away from being killed.
`container_memory_working_set_bytes` is what the kernel compares against the limit —
not RSS, not cache, not `container_memory_usage_bytes`.

```promql
# Who has been OOM-killed recently, across both namespaces.
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```
Bad answer: more than one distinct pod. That is a node-wide pattern, not an app bug.

```promql
# Growth rate — is this a leak or a spike?
deriv(container_memory_working_set_bytes{namespace="demo", container="orders-api"}[30m])
```
Bad answer: a steady positive slope that never returns to baseline. That is a leak, and
raising the limit only buys time proportional to the increase.

```promql
# Hours until the next kill at the current growth rate.
(
  kube_pod_container_resource_limits{namespace="demo", container="orders-api", resource="memory"}
    - on (namespace, pod, container) container_memory_working_set_bytes{namespace="demo", container="orders-api"}
) / on (namespace, pod, container) (
  deriv(container_memory_working_set_bytes{namespace="demo", container="orders-api"}[30m]) * 3600
)
```
Bad answer: a small positive number. That is your deadline.

## 5. Diagnosis

1. **Confirm it was an OOM kill and not something else wearing the same costume.**

   ```bash
   kubectl -n demo get pod -l app.kubernetes.io/name=orders-api \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\t"}{.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}{end}'
   ```

   Expected on a hit: `orders-api-xxxx  OOMKilled  137  2026-10-17T10:14:22Z`.
   `Error 1` means an application crash, not an OOM — go to [PodCrashLooping.md](PodCrashLooping.md).
   An empty `lastState` means the container has not terminated yet and this alert is stale.

2. **Compare the working set against the limit at the moment of death.**

   ```bash
   kubectl -n demo describe pod -l app.kubernetes.io/name=orders-api | grep -A6 'Limits:\|Requests:'
   kubectl -n demo top pods -l app.kubernetes.io/name=orders-api --containers
   ```

   `kubectl top` shows the *current* container, which has just restarted and looks healthy.
   Use the Prometheus query from section 4 with a 1-hour range to see the shape before the kill.

3. **Decide: leak, spike, or simply under-provisioned.**

   ```bash
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 \
     'max_over_time(container_memory_working_set_bytes{namespace="demo", container="orders-api"}[6h])'
   ```

   - Sawtooth that climbs linearly between restarts: **leak**.
   - Flat baseline with a single sharp spike correlated with a traffic burst: **spike** —
     correlate with `sum(job:http_requests:rate5m{job="orders-api"})`.
   - Flat and permanently near the limit: **under-provisioned**. Raise the limit and move on.

4. **Check whether chaos caused it.** This repo ships a deliberate leak endpoint, and it is
   the intended way to reproduce this alert:

   ```bash
   kubectl -n demo get deployment orders-api \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHAOS_ENABLED")].value}{"\n"}'
   kubectl -n demo logs deployment/orders-api --since=1h | grep -i 'chaos\|leak' | tail -20
   ```

   To reproduce this alert on purpose (for testing the rule, the routing and this runbook):

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   # allocate 64 MiB that is never released; repeat until the limit is crossed
   curl -s "http://localhost:8080/chaos/leak?mb=64"
   # watch it climb
   watch -n5 'kubectl -n demo top pods -l app.kubernetes.io/name=orders-api --containers'
   # stop and release
   curl -s "http://localhost:8080/chaos/reset"
   ```

5. **Check the Go runtime's view of its own budget.** `orders-api` is a Go 1.23 service, and
   the Go GC has no idea what the cgroup limit is unless you tell it. Without `GOMEMLIMIT`
   the runtime sizes the heap against `GOGC` (default 100 — collect when the heap doubles),
   happily grows past the container limit, and gets SIGKILLed mid-collection.

   ```bash
   kubectl -n demo get deployment orders-api \
     -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
     | grep -E 'GOMEMLIMIT|GOGC|GOMAXPROCS'
   ```

   Nothing returned means the Go runtime is unconstrained. Set `GOMEMLIMIT` to roughly
   **80–90% of the container memory limit** — it is a soft limit, so the GC works harder as
   it approaches instead of the kernel killing the process outright. Leave headroom for
   goroutine stacks and off-heap allocations, which `GOMEMLIMIT` does not cover.

6. **Rule out the node.** A container killed at its own limit is an app problem; a container
   killed while the node is out of memory is a capacity problem.

   ```bash
   kubectl top nodes
   kubectl describe node | grep -A8 'Conditions:\|Allocated resources'
   kubectl get events -A --sort-by=.lastTimestamp | grep -Ei 'oom|evict' | tail -20
   ```

   `MemoryPressure=True`, or allocated memory requests near 100% of allocatable, means go to
   [NodeMemoryPressure.md](NodeMemoryPressure.md) first.

7. **Check the `monitoring` namespace too.** Prometheus is usually the largest memory consumer
   in this cluster, and an OOM-killed Prometheus loses the in-memory head block.

   ```bash
   kubectl -n monitoring get pods -o wide
   kubectl -n monitoring get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' | grep OOM
   ```

## 6. Mitigation

1. **Reset chaos** — if `/chaos/leak` is the cause, this releases the memory with no restart:

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s "http://localhost:8080/chaos/reset"
   ```

2. **Set `GOMEMLIMIT`** — no limit change, no extra node memory, and it converts a hard kill
   into GC pressure you can observe. With a 512Mi limit, use roughly 440MiB:

   ```bash
   kubectl -n demo set env deployment/orders-api GOMEMLIMIT=440MiB
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

3. **Raise the memory limit** — buys time; only valid if the node has headroom
   (check `kubectl describe node` first):

   ```bash
   kubectl -n demo set resources deployment/orders-api \
     --containers=orders-api --limits=memory=512Mi --requests=memory=256Mi
   ```

   Keep request below limit so the pod lands in the `Burstable` QoS class rather than
   `Guaranteed`, unless you specifically want eviction protection.

4. **Restart to reclaim immediately** — a leak is cleared by a fresh process:

   ```bash
   kubectl -n demo rollout restart deployment/orders-api
   ```

5. **Roll back** — if the memory profile changed with a deploy, the new code is the leak:

   ```bash
   kubectl rollout undo deployment/orders-api -n demo
   ```

6. **Scale out and shrink per-pod footprint** — spreads the working set across more pods,
   each with a lower limit. Larger blast radius because it changes scheduling:

   ```bash
   kubectl -n demo scale deployment/orders-api --replicas=4
   ```

7. **Give the node more memory** — minikube only, recreates the cluster. Last resort:
   see [NodeMemoryPressure.md](NodeMemoryPressure.md).

Verify:

```promql
container_memory_working_set_bytes{namespace="demo", container="orders-api"}
  / on (namespace, pod, container)
kube_pod_container_resource_limits{namespace="demo", container="orders-api", resource="memory"}
```
Should settle below `0.8` and stay flat across at least two GC cycles.

## 7. If it does not resolve — escalation

Escalate to `platform` for node capacity and limits, to `orders` (Ahmed Fakhfakh) for an
application leak. If a `monitoring` component was killed, `platform` owns it outright.

```bash
{
  echo "=== last terminated state, all demo pods ==="
  kubectl -n demo get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

  echo "=== same for monitoring ==="
  kubectl -n monitoring get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

  echo "=== working set vs limit ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=container_memory_working_set_bytes{namespace="demo",container="orders-api"} / on(namespace,pod,container) kube_pod_container_resource_limits{namespace="demo",container="orders-api",resource="memory"}' \
    | jq -r '.data.result[] | [.metric.pod, .value[1]] | @tsv'

  echo "=== 6h peak working set ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=max_over_time(container_memory_working_set_bytes{namespace="demo",container="orders-api"}[6h])' \
    | jq -r '.data.result[] | [.metric.pod, .value[1]] | @tsv'

  echo "=== limits, env, node ==="
  kubectl -n demo describe deployment orders-api | grep -A10 'Limits\|Environment'
  kubectl top nodes
  kubectl describe node | grep -A10 'Allocated resources'

  echo "=== logs before the kill ==="
  kubectl -n demo logs deployment/orders-api --previous --tail=200
} > container-oomkilled-evidence.txt 2>&1
```

## 8. Prevention and follow-up

- Always set `GOMEMLIMIT` on Go services running under a cgroup memory limit. This is the
  single highest-value change on this page.
- Size the memory request from the observed p95 of `container_memory_working_set_bytes` over
  a week, and the limit at roughly 1.5x the request.
- Add a heap profile capture to the incident process. A leak that cannot be reproduced is a
  leak that will recur.
- If `/chaos/leak` reproduced this cleanly, keep that in the demo script — a tested alert
  path is worth more than an untested one. See `make break` and `scripts/trigger-incident.ps1`.
- Consider a warning-severity companion rule on the working-set-to-limit ratio above 85%,
  so the team gets a ticket before the kernel gets involved.
- Check that Prometheus retention and `monitoring` resource limits leave room on the node;
  see [PVCNearlyFull.md](PVCNearlyFull.md).

Docs: [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md),
[`../docs/slo-guide.md`](../docs/slo-guide.md),
[`../docs/promql-cookbook.md`](../docs/promql-cookbook.md),
[`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml)
- [PodCrashLooping.md](PodCrashLooping.md) — exit code 137 lands here
- [NodeMemoryPressure.md](NodeMemoryPressure.md) — node-level memory exhaustion
- [HighLatencyP99.md](HighLatencyP99.md) — GC pressure shows up as tail latency first
- [ErrorBudgetBurn.md](ErrorBudgetBurn.md) — what the dropped requests cost
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

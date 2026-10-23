# Runbook: NodeMemoryPressure

| Field | Value |
|---|---|
| Alert name | `NodeMemoryPressure` |
| Severity | `warning` |
| Team | `platform` |
| Dashboard | http://localhost:3000/d/obs-k8s-cluster |
| SLO impact | Indirect — evictions and throttling degrade `orders-api` before anything 5xxs |
| Typical time-to-mitigate | 15–30 minutes |

## 1. What this alert means

Memory utilisation on a cluster node has been above 85% for ten minutes. Below the eviction
threshold the kubelet does nothing; above it, the kubelet starts reclaiming — first page
cache, then by evicting pods in reverse QoS order. This alert is the window between
"comfortable" and "the kubelet starts making decisions for you".

```promql
(
  1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
) > 0.85
```

`for: 10m`. `MemAvailable` is the right numerator source: it already accounts for reclaimable
page cache, so it does not fire every time the kernel caches a file. Using
`MemFree` instead would page constantly on a healthy node.

On minikube the "node" is a Docker container (or a VM) on your Windows host, sized at
`minikube start` time. It cannot grow. Whatever you gave it is all there is.

## 2. Impact

- The kubelet's soft eviction threshold (default `memory.available<100Mi`) triggers pod
  eviction. `BestEffort` pods go first, then `Burstable` pods that exceed their requests,
  then `Guaranteed` pods.
- Evicted `orders-api` pods mean capacity loss and dropped requests; evicted `monitoring`
  pods mean you lose the ability to see what is happening, which is worse.
- Memory pressure also slows everything: page-cache thrashing shows up as tail latency long
  before it shows up as errors. Expect `HighLatencyP99` to fire first.
- Burns availability budget indirectly, via evictions and failed requests.

## 3. Severity and response expectation

`warning`, ticketed to `platform`, ack within one business day. Escalate to an incident if
any of these is true: `kubectl describe node` shows `MemoryPressure=True`, eviction events
are present, `ContainerOOMKilled` is firing concurrently, or utilisation is above 95%.

In a single-node minikube cluster this alert is effectively cluster-wide — there is nowhere
for the scheduler to move work to.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-k8s-cluster — node memory, allocatable vs allocated, pod count
- http://localhost:3000/d/obs-app-red — whether the app has started to suffer
- http://localhost:3000/d/obs-slo-budget — whether it has cost anything yet

```promql
# Node memory utilisation.
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```
Bad answer: above `0.95`. The kubelet is about to evict.

```promql
# Available bytes in absolute terms — this is what the eviction threshold compares against.
node_memory_MemAvailable_bytes
```
Bad answer: under 300MB. The default soft threshold is 100Mi; you are minutes away.

```promql
# Who is using it. Top memory consumers across the cluster.
topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{container!=""}))
```
Bad answer: a single `monitoring` pod holding more than a third of node memory — usually
Prometheus with too much retention or too many series.

```promql
# Are we over-committed on requests?
sum(kube_pod_container_resource_requests{resource="memory"})
  / sum(kube_node_status_allocatable{resource="memory"})
```
Bad answer: above `0.9`. The scheduler has no room left and new pods will stay `Pending`.

## 5. Diagnosis

1. **Confirm the node's own view.** Node conditions are authoritative; the metric is a proxy.

   ```bash
   kubectl top nodes
   kubectl describe node | grep -A8 'Conditions:'
   ```

   `MemoryPressure  True` means the kubelet has already crossed its threshold and reclaim is
   under way. `False` with 90% utilisation means you still have a margin.

2. **Read the allocation picture.** Requests reserve; working set consumes. They diverge.

   ```bash
   kubectl describe node | sed -n '/Allocated resources/,/Events/p'
   ```

   Memory requests near 100% of allocatable means the scheduler is full even if actual usage
   is lower. Memory *limits* far above allocatable means the node is over-committed and a
   simultaneous spike will OOM something.

3. **Find the consumers, ranked.**

   ```bash
   kubectl top pods -A --sort-by=memory | head -20
   ```

   In this stack the usual order is: Prometheus, Loki, Tempo, Grafana, then `orders-api`.
   If `orders-api` is at the top, the problem is the app — go to
   [ContainerOOMKilled.md](ContainerOOMKilled.md) section 5.

4. **Check for evictions and OOM events.** These are the consequences you are trying to avoid.

   ```bash
   kubectl get events -A --sort-by=.lastTimestamp | grep -Ei 'evict|oom|systemoom|nodehasmemorypressure' | tail -20
   kubectl get pods -A --field-selector=status.phase=Failed
   ```

   Pods in `Failed` with reason `Evicted` confirm the kubelet acted. They stay around as
   tombstones and need cleaning up (section 6 step 1).

5. **Check the minikube sizing — this is the root cause more often than anything inside the
   cluster.** The node is a container on the Windows host with a fixed memory allocation.

   ```bash
   minikube config view
   minikube node list
   kubectl get node -o jsonpath='{.items[0].status.capacity.memory}{"\n"}'
   kubectl get node -o jsonpath='{.items[0].status.allocatable.memory}{"\n"}'
   minikube ssh -- free -m
   ```

   The documented minimum for this stack is `--memory=8192`. If capacity reports ~4GB, the
   cluster was started with defaults and the whole observability stack does not fit.
   Note the gap between `capacity` and `allocatable`: the kubelet reserves memory for the
   system and for eviction headroom, so you never get the full number.

6. **Check the kubelet's eviction thresholds.** Defaults are not always what you assume.

   ```bash
   minikube ssh -- cat /var/lib/kubelet/config.yaml | grep -A10 'evictionHard\|evictionSoft'
   ```

   Default hard threshold is `memory.available<100Mi`. There is no grace period on a hard
   threshold — the kubelet evicts immediately, which is why this alert fires at 85% rather
   than at 99%.

7. **Check Prometheus specifically.** It is the largest and most elastic consumer, and its
   memory scales with active series.

   ```bash
   kubectl -n monitoring top pods --containers | grep prometheus
   kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     promtool query instant http://localhost:9090 'prometheus_tsdb_head_series'
   ```

   A head-series count growing without bound means a label cardinality explosion. The `route`
   label on `http_requests_total` is templated precisely to prevent this — verify nothing has
   started emitting raw paths.

## 6. Mitigation

1. **Clean up evicted pod tombstones** — zero risk, frees nothing but clarifies the picture:

   ```bash
   kubectl get pods -A --field-selector=status.phase=Failed -o json \
     | jq -r '.items[] | select(.status.reason=="Evicted") | "\(.metadata.namespace) \(.metadata.name)"' \
     | xargs -n2 sh -c 'kubectl -n $0 delete pod $1'
   ```

2. **Reset chaos** — `/chaos/leak` holds node memory for as long as the process lives:

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s "http://localhost:8080/chaos/reset"
   ```

3. **Shrink Prometheus retention** — the fastest meaningful reclaim in this stack, affects
   only historical query range:

   ```bash
   kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge \
     -p '{"spec":{"retention":"3d","retentionSize":"4GB"}}'
   kubectl -n monitoring rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus
   ```

4. **Scale down what you are not using** — Tempo and Loki can be scaled to zero temporarily
   if the incident is about keeping `orders-api` alive:

   ```bash
   kubectl -n monitoring scale deployment/tempo --replicas=0
   kubectl -n demo scale deployment/orders-api --replicas=2
   ```

5. **Set or lower memory limits on the biggest consumer** — stops one workload from taking
   the node down with it, at the cost of possibly OOM-killing it:

   ```bash
   kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge \
     -p '{"spec":{"resources":{"limits":{"memory":"2Gi"},"requests":{"memory":"1Gi"}}}}'
   ```

6. **Give the node more memory** — the real fix on minikube. Largest blast radius: it stops
   and recreates the cluster VM, so everything restarts. Persistent volumes survive a
   `minikube stop`/`start`; a `minikube delete` destroys them.

   ```bash
   minikube stop
   minikube start --cpus=4 --memory=8192 --disk-size=40g --driver=docker
   kubectl get nodes
   kubectl -n monitoring get pods
   ```

   Also check Docker Desktop's own resource allocation on the Windows host — minikube cannot
   be given more memory than Docker Desktop has.

Verify:

```promql
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```
Should settle below `0.80` and `kubectl describe node` should show `MemoryPressure  False`.

## 7. If it does not resolve — escalation

`platform` owns this (Ahmed Fakhfakh). There is no second tier on a local cluster: the
decision is between reducing what runs and increasing what the host provides.

```bash
{
  echo "=== node capacity, allocatable, conditions ==="
  kubectl get nodes -o wide
  kubectl describe node

  echo "=== top consumers ==="
  kubectl top nodes
  kubectl top pods -A --sort-by=memory | head -25

  echo "=== utilisation and availability ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)' \
    | jq -r '.data.result[].value[1]'
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=node_memory_MemAvailable_bytes' \
    | jq -r '.data.result[].value[1]'

  echo "=== request commitment ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sum(kube_pod_container_resource_requests{resource="memory"}) / sum(kube_node_status_allocatable{resource="memory"})' \
    | jq -r '.data.result[].value[1]'

  echo "=== evictions and OOM events ==="
  kubectl get events -A --sort-by=.lastTimestamp | grep -Ei 'evict|oom' | tail -30

  echo "=== minikube sizing ==="
  minikube config view
  minikube ssh -- free -m

  echo "=== prometheus series count ==="
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=prometheus_tsdb_head_series' | jq -r '.data.result[].value[1]'
} > node-memory-pressure-evidence.txt 2>&1
```

## 8. Prevention and follow-up

- Start the cluster at the documented size every time:
  `minikube start --cpus=4 --memory=8192 --disk-size=40g --driver=docker`. Put it in the
  `cluster-up` script so nobody has to remember — see `scripts/cluster-up.ps1`.
- Set memory requests and limits on every workload in `monitoring`. An unbounded Prometheus
  will consume whatever the node has.
- Keep Prometheus retention aligned with what the SLO actually needs. The 30-day SLO windows
  are computed from recording rules, not raw data, so raw retention can be much shorter.
- Guard label cardinality. The `route` label is templated to seven values for exactly this
  reason; a regression there costs node memory before it costs anything else.
- Set `GOMEMLIMIT` on Go workloads so they cooperate with the limit rather than fighting it
  — see [ContainerOOMKilled.md](ContainerOOMKilled.md).
- Add a `PriorityClass` to `monitoring` components so the kubelet evicts the demo app before
  it evicts the thing that tells you the demo app was evicted.

Docs: [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md),
[`../docs/slo-guide.md`](../docs/slo-guide.md),
[`../docs/promql-cookbook.md`](../docs/promql-cookbook.md),
[`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-infra.yaml`](../stack/prometheus/rules/alerts-infra.yaml)
- [ContainerOOMKilled.md](ContainerOOMKilled.md) — container-level limit kills
- [PodCrashLooping.md](PodCrashLooping.md) — evictions look like crash loops
- [PVCNearlyFull.md](PVCNearlyFull.md) — the disk-side equivalent, same root causes
- [HighLatencyP99.md](HighLatencyP99.md) — the first user-visible symptom of node pressure
- [TargetDown.md](TargetDown.md) — if an evicted `monitoring` pod takes scraping with it
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

# Runbook: PodCrashLooping

| Field | Value |
|---|---|
| Alert name | `PodCrashLooping` |
| Severity | `critical` |
| Team | `orders` |
| Dashboard | http://localhost:3000/d/obs-k8s-cluster |
| SLO impact | Indirect — reduces capacity, usually triggers `ErrorBudgetBurn{slo="availability"}` |
| Typical time-to-mitigate | 10–15 minutes |

## 1. What this alert means

A container in the `demo` namespace has restarted more than three times in fifteen minutes.
Kubernetes is restarting it, it is dying again, and the back-off timer is growing
(10s, 20s, 40s ... capped at 5 minutes). The pod is not serving traffic for most of that time.

```promql
max by (namespace, pod, container) (
  increase(kube_pod_container_status_restarts_total{namespace="demo"}[15m])
) > 3
```

`for: 5m`. An equivalent, slightly more literal form that some operators prefer — it keys off
the kubelet's own back-off state rather than the restart counter:

```promql
max by (namespace, pod, container) (
  kube_pod_container_status_waiting_reason{namespace="demo", reason="CrashLoopBackOff"}
) > 0
```

A single restart is not an alert. Four restarts in fifteen minutes is a container that cannot
start, and no amount of waiting will fix it.

## 2. Impact

- Capacity loss proportional to the number of affected replicas. With `replicas=2` and one
  crash-looping, half of all requests go to a pod that may be failing readiness.
- If every replica is looping, `orders-api` is down: `NoTrafficReceived` and `TargetDown`
  will follow, and the availability error budget burns at full rate.
- Burns error budget whenever a crash-looping replica is still in the Service endpoints —
  which happens between the restart and the first failed readiness probe.

## 3. Severity and response expectation

`critical`, pages the on-call, ack within 5 minutes, 24x7. A crash loop never self-heals;
the back-off only slows the bleeding. Mitigate first (section 6 step 1 is a rollback),
then diagnose from the preserved logs.

## 4. Dashboards and queries to open first

- http://localhost:3000/d/obs-k8s-cluster — pod restarts, container states, node health
- http://localhost:3000/d/obs-app-red — whether the surviving replicas still serve traffic
- http://localhost:3000/d/obs-logs-explorer — the last lines before each death

```promql
# Restart rate per container, last 15 minutes.
increase(kube_pod_container_status_restarts_total{namespace="demo"}[15m])
```
Bad answer: a number that keeps rising on every evaluation. Flat and high means it crashed
and has now settled into a long back-off.

```promql
# Why is it waiting, exactly?
kube_pod_container_status_waiting_reason{namespace="demo"} == 1
```
Bad answer: `CrashLoopBackOff` (the app dies), `ImagePullBackOff` or `ErrImagePull`
(the image does not exist on the node), `CreateContainerConfigError` (a missing Secret or
ConfigMap key).

```promql
# How many replicas are actually ready?
kube_deployment_status_replicas_available{namespace="demo", deployment="orders-api"}
```
Bad answer: `0`. The service is down, not degraded.

```logql
{namespace="demo", app="orders-api", level="ERROR"}
```
Bad answer: a fatal message repeating at exactly the back-off interval — that is the startup
failure, and the line immediately before it names the cause.

## 5. Diagnosis

1. **Identify which pod, which container, and what state.**

   ```bash
   kubectl -n demo get pods -l app.kubernetes.io/name=orders-api \
     -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STATE:.status.containerStatuses[*].state'
   ```

   `READY=false` with a climbing `RESTARTS` confirms the loop. If `RESTARTS` is high but
   `READY=true`, the container recovered and this alert is about to resolve.

2. **Read the logs of the *previous* instance.** The current container may not have produced
   anything yet; the dead one did. This is the single most important command in this runbook.

   ```bash
   kubectl -n demo logs deployment/orders-api --previous --tail=200
   # or, for a specific pod when replicas differ:
   kubectl -n demo logs <pod-name> -c orders-api --previous --tail=200
   ```

   `Error from server (BadRequest): previous terminated container not found` means the
   container has never successfully started — go to step 4 (image and config).

3. **Read the exit code.** It classifies the failure in one number.

   ```bash
   kubectl -n demo get pod -l app.kubernetes.io/name=orders-api \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}'
   ```

   | Exit code | Reason | Meaning | Go to |
   |---|---|---|---|
   | `137` | `OOMKilled` | SIGKILL from the kernel OOM killer — the container exceeded its memory limit | [ContainerOOMKilled.md](ContainerOOMKilled.md) |
   | `143` | `Error` | SIGTERM — something asked it to stop; usually an eviction or a failed liveness probe | step 5 |
   | `1` | `Error` | Generic application error — an unhandled panic or a failed dependency at startup | step 2 logs |
   | `2` | `Error` | Misuse of a shell builtin or bad arguments — a malformed command, flag, or env var | step 4 |
   | `0` | `Completed` | The process exited cleanly; a `Deployment` restarts it anyway. The entrypoint is wrong | step 4 |

4. **Check image, config and secrets.** This is where "never started at all" lives.

   ```bash
   kubectl -n demo describe pod -l app.kubernetes.io/name=orders-api | sed -n '/Events:/,$p'
   kubectl -n demo get deployment orders-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   kubectl -n demo get deployment orders-api -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}{"\n"}'
   ```

   Expected: image `orders-api:0.1.0`, policy `IfNotPresent`. The image is built directly
   into minikube's Docker daemon, so `ErrImagePull` almost always means the build happened
   against the host daemon instead. Verify it exists inside the node:

   ```bash
   minikube ssh -- docker images | grep orders-api
   # if absent, rebuild inside minikube's daemon:
   #   eval $(minikube docker-env)   # PowerShell: minikube docker-env | Invoke-Expression
   #   docker build -t orders-api:0.1.0 ./app
   ```

   `CreateContainerConfigError` in the events means a referenced ConfigMap or Secret key does
   not exist. The event text names it.

5. **Check the probes.** A liveness probe that fails kills a healthy-but-slow container,
   which looks exactly like a crash loop.

   ```bash
   kubectl -n demo get deployment orders-api -o yaml \
     | grep -A10 -E 'livenessProbe|readinessProbe|startupProbe'
   kubectl -n demo describe pod -l app.kubernetes.io/name=orders-api | grep -i 'probe failed'
   ```

   The probes must hit `/healthz` (liveness) and `/readyz` (readiness) on port `8080`.
   `initialDelaySeconds` shorter than the app's real startup time is the classic cause:
   the container is killed before it ever finishes booting. Test the endpoint by hand from
   inside the cluster:

   ```bash
   kubectl -n demo run probe-check --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
     curl -sv --max-time 3 http://orders-api.demo.svc.cluster.local:8080/healthz
   ```

6. **Check whether the node pushed it out.** Evictions look like crashes from the pod side.

   ```bash
   kubectl -n demo get events --sort-by=.lastTimestamp | grep -Ei 'evict|preempt|killing|unhealthy'
   kubectl describe node | grep -A6 'Conditions:'
   kubectl top nodes
   ```

   `MemoryPressure=True` or eviction events mean this is a node problem —
   see [NodeMemoryPressure.md](NodeMemoryPressure.md).

7. **Confirm the scope.** One pod or all of them?

   ```bash
   kubectl -n demo get pods -o wide
   kubectl -n demo get deployment orders-api
   ```

   One of three looping is a bad replica, likely node-local. Three of three looping is a bad
   image, bad config, or bad code — and a rollback fixes it.

## 6. Mitigation

1. **Roll back** — smallest safe action that fixes a bad image or bad config, and the right
   first move whenever the loop started after a deploy:

   ```bash
   kubectl rollout undo deployment/orders-api -n demo
   kubectl -n demo rollout status deployment/orders-api --timeout=120s
   ```

2. **Delete the single bad pod** — when only one replica is affected and the others are
   healthy. Capture `--previous` logs first (section 5 step 2), because deleting destroys them:

   ```bash
   kubectl -n demo logs <pod-name> --previous --tail=500 > crashloop-previous.log
   kubectl -n demo delete pod <pod-name>
   ```

3. **Relax or disable the liveness probe** — when section 5 step 5 showed a probe timeout on
   a container that is otherwise fine. Buys time to fix the real startup latency:

   ```bash
   kubectl -n demo patch deployment orders-api --type=json -p='[
     {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":30},
     {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":6}
   ]'
   ```

4. **Raise the memory limit** — if the exit code was `137`:

   ```bash
   kubectl -n demo set resources deployment/orders-api \
     --containers=orders-api --limits=memory=512Mi --requests=memory=256Mi
   ```

   Then follow [ContainerOOMKilled.md](ContainerOOMKilled.md) to find out why it needed it.

5. **Fix the image** — rebuild into minikube's daemon and restart:

   ```bash
   minikube docker-env | Invoke-Expression        # PowerShell
   docker build -t orders-api:0.1.0 ./app
   kubectl -n demo rollout restart deployment/orders-api
   ```

6. **Scale up the survivors** — restores capacity while you debug, if the loop is node-local:

   ```bash
   kubectl -n demo scale deployment/orders-api --replicas=4
   ```

7. **Reset chaos** — `/chaos/leak` left running will OOM a container repeatedly:

   ```bash
   kubectl -n demo port-forward svc/orders-api 8080:8080 &
   curl -s "http://localhost:8080/chaos/reset"
   ```

## 7. If it does not resolve — escalation

Escalate to the `orders` service owner (Ahmed Fakhfakh). Escalate to `platform` instead if
step 6 of diagnosis showed node pressure or evictions.

```bash
{
  echo "=== pod state ==="
  kubectl -n demo get pods -l app.kubernetes.io/name=orders-api -o wide

  echo "=== last terminated state (reason + exit code) ==="
  kubectl -n demo get pod -l app.kubernetes.io/name=orders-api -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

  echo "=== previous container logs ==="
  kubectl -n demo logs deployment/orders-api --previous --tail=300

  echo "=== current container logs ==="
  kubectl -n demo logs deployment/orders-api --tail=100

  echo "=== describe (events, probes, image) ==="
  kubectl -n demo describe pod -l app.kubernetes.io/name=orders-api

  echo "=== node conditions ==="
  kubectl describe node | grep -A8 'Conditions:'
  kubectl top nodes
} > pod-crashlooping-evidence.txt 2>&1
```

## 8. Prevention and follow-up

- Add a `startupProbe` so slow boots do not trip the liveness probe. Liveness should test
  "is the process wedged", never "has it finished starting".
- Validate configuration at startup and fail with a clear message naming the missing key,
  so exit code `2` cases are self-diagnosing from the logs.
- Pin `imagePullPolicy: IfNotPresent` and keep the image tag immutable (`orders-api:0.1.0`),
  so a restart never silently pulls something different.
- Set memory requests equal to the realistic working set and the limit above it; see
  [ContainerOOMKilled.md](ContainerOOMKilled.md) for sizing.
- Add a `PodDisruptionBudget` so rolling operations cannot take the last healthy replica.
- If this alert fired without `ErrorBudgetBurn` following it, the deployment absorbed the
  loss correctly. Record that — it is evidence the replica count is right.

Docs: [`../docs/alerting-philosophy.md`](../docs/alerting-philosophy.md),
[`../docs/slo-guide.md`](../docs/slo-guide.md),
[`../docs/promql-cookbook.md`](../docs/promql-cookbook.md),
[`../LEARN.md`](../LEARN.md).

## Related

- Rule file: [`../stack/prometheus/rules/alerts-app.yaml`](../stack/prometheus/rules/alerts-app.yaml)
- [ContainerOOMKilled.md](ContainerOOMKilled.md) — exit code 137
- [NodeMemoryPressure.md](NodeMemoryPressure.md) — eviction-driven restarts
- [HighErrorRate.md](HighErrorRate.md) — the user-visible consequence
- [ErrorBudgetBurn.md](ErrorBudgetBurn.md) — what it costs
- [TargetDown.md](TargetDown.md) — a looping pod is also a missing scrape target
- [README.md](README.md) — alert index

Ahmed Fakhfakh — DevOps / SRE

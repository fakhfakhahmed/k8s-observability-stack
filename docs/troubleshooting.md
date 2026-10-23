# Troubleshooting

A symptom-first index. Find your symptom, follow the checklist in order — each one is ordered
from "most likely and cheapest to check" to "least likely".

## ServiceMonitor not discovered / target missing from Prometheus

The single most common failure in this entire stack, and it fails SILENTLY — no error, no event,
no log line anywhere.

1. **Selector mismatch (the classic gotcha).** The `Prometheus` CR's `serviceMonitorSelector` and
   `serviceMonitorNamespaceSelector` decide which ServiceMonitors get adopted at all.
   ```bash
   kubectl get prometheus -n monitoring -o yaml | grep -A5 serviceMonitorSelector
   ```
   If this shows `matchLabels: {release: kube-prometheus-stack}` and your ServiceMonitor lacks
   that label, it is invisible. This repo defends against it twice: `stack/prometheus/values.yaml`
   sets `serviceMonitorSelectorNilUsesHelmValues: false` (making the selector permissive), AND
   `app/k8s/servicemonitor.yaml` carries the label anyway. If you've overridden the values file,
   check both halves of the defense are still in place.
2. **Port name vs. port number.** `endpoints[].port` in a ServiceMonitor refers to the Service
   port's NAME field, never a number. `app/k8s/servicemonitor.yaml` uses `port: http` — confirm
   `app/k8s/service.yaml` has a port actually named `http`:
   ```bash
   kubectl get svc orders-api -n demo -o jsonpath='{.spec.ports[*].name}'
   ```
3. **Service selector vs. Pod labels mismatch.** The Service needs real Endpoints:
   ```bash
   kubectl get endpoints orders-api -n demo
   ```
   `<none>` means the Service's `spec.selector` doesn't match any running Pod's labels — compare
   `service.yaml`'s `spec.selector` against `deployment.yaml`'s `template.metadata.labels`.
4. **ServiceMonitor's own namespace selector.** `namespaceSelector.matchNames` in
   `servicemonitor.yaml` must include the namespace the Service actually lives in (`demo`).
5. **Confirm in the UI, last.** `kubectl get servicemonitor -A`, then
   `scripts/port-forward` -> http://localhost:9090/targets. A target that's present but shows
   `DOWN` is a DIFFERENT problem — see the next section.

## Targets showing as DOWN (present, but failing)

1. Click the target in Prometheus's Targets page and read the actual error string — "connection
   refused" (app not listening / crashed), "context deadline exceeded" (scrape timeout too short,
   or the app is overloaded), and a TLS error (scheme mismatch — `scheme: http` vs `https` in the
   ServiceMonitor) all point in different directions.
2. **`scrapeTimeout` >= `interval`.** `servicemonitor.yaml` sets `interval: 15s`,
   `scrapeTimeout: 10s` — timeout must stay strictly less than the interval, or a slow scrape
   overlaps the next one.
3. Confirm the app actually serves `/metrics` from inside the cluster:
   ```bash
   kubectl exec -n demo deploy/orders-api -- wget -qO- localhost:8080/metrics | head
   ```
4. For the etcd/controller-manager/scheduler/kube-proxy targets specifically: these are
   DISABLED in `stack/prometheus/values.yaml` on purpose (default bind-address hardening on
   recent Kubernetes makes them unreachable via Service/Endpoints scraping on minikube and most
   kubeadm clusters) — see that file's big comment block. If you've re-enabled them and they're
   red, that's expected without also rebinding their `--bind-address`.

## Grafana datasource errors ("bad gateway", empty panels, "no data")

1. **Wrong Service DNS.** `stack/grafana/datasources/datasources.yaml` hardcodes
   `*.monitoring.svc.cluster.local` hostnames assuming the Helm release name
   `kube-prometheus-stack`. If you installed under a different release name, the Prometheus
   Service name changes — `kubectl get svc -n monitoring` and update the datasource `url`.
2. **Datasource `uid` mismatch.** Every dashboard JSON in `stack/grafana/dashboards/json/`
   references datasources by the literal uid `prometheus` / `loki` / `tempo`. If the provisioned
   datasource was created with a DIFFERENT uid (e.g. auto-generated instead of pinned, which
   happens if `datasources.yaml`'s explicit `uid:` fields were dropped), every panel shows "no
   data" with no error — check Grafana's Connections > Data sources page for the actual uid in
   use and compare.
3. **Datasource provisioned but not picked up.** Confirm the sidecar actually found the
   ConfigMap: `kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana -c
   grafana-sc-datasources`. Confirm the ConfigMap carries the exact label
   `grafana_datasource: "1"` that `stack/prometheus/values.yaml`'s
   `grafana.sidecar.datasources.label`/`labelValue` expect.
4. **Query itself is wrong**, not the datasource — test the same PromQL/LogQL directly in
   Prometheus's or Loki's own UI (via `logcli`/`promtool`, or Grafana's Explore view) before
   assuming the datasource connection is broken.

## Loki ingestion failures / out-of-order errors

1. **"entry out of order"** — Loki rejects a line whose timestamp is older than the most recent
   one already ingested FOR THAT STREAM. Usually caused by Promtail restarting and re-reading a
   log file from an earlier position, or by `stack/loki/promtail-values.yaml`'s `timestamp` stage
   pointing at a field that isn't monotonic. Confirm the `time` field in the app's own JSON logs
   is strictly increasing per pod — `newLogger()` in `app/main.go` always formats it from
   `time.Now()`, so this is almost always a Promtail-side replay, not an app bug.
2. **Lines silently missing from a query.** Check `stack/loki/promtail-values.yaml`'s `drop`
   stages — a regex that's too broad (matching more than intended) will drop real lines with no
   visible error. Test the regex in isolation against a sample line.
3. **High cardinality rejection / `max_streams_per_user` hit.** If a code change accidentally
   promotes a high-cardinality field (e.g. `order_id`) to a Loki LABEL (via an over-broad
   `extraRelabelConfigs` or `pipelineStages` `labels` block), Loki will reject new streams once
   `limits_config.max_streams_per_user` (`stack/loki/values.yaml`) is hit. Check Promtail's logs
   for `429`/`ingester.max-streams` errors and review which fields are actually promoted to
   labels — should be exactly `level`, `service`, `namespace`, `pod`, `container`, `app`.
4. **Nothing arriving at all.** Confirm Promtail's `clients[].url` points at the right Loki
   Service and port (`http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`) and that
   the DaemonSet pod is actually running on the node hosting `orders-api`
   (`kubectl get pods -n monitoring -o wide | grep promtail`).

## Tempo not receiving spans

1. **Port mismatch — the #1 cause.** `4317` is OTLP/gRPC, `4318` is OTLP/HTTP. `app/main.go`'s
   `otlptracegrpc` exporter MUST point at 4317. Using 4318 with a gRPC exporter (or vice versa)
   fails with no spans exported and, depending on SDK version, no obvious error logged either —
   check `OTEL_EXPORTER_OTLP_ENDPOINT` in `app/k8s/deployment.yaml` against
   `stack/tempo/values.yaml`'s `receivers.otlp.protocols` block.
2. **Scheme left in the endpoint.** `initTracing()` in `app/main.go` explicitly strips a
   `http://`/`grpc://` scheme from `OTEL_EXPORTER_OTLP_ENDPOINT` because the gRPC exporter's
   `WithEndpoint` wants a bare `host:port`. If you've modified this logic, a leftover scheme is a
   common silent-failure cause.
3. **Service DNS.** `tempo.monitoring.svc.cluster.local:4317` assumes the Tempo Service is named
   `tempo` in the `monitoring` namespace — `kubectl get svc -n monitoring | grep tempo` to
   confirm after a Helm install under a different release name.
4. **Sampling ratio.** `OTEL_TRACES_SAMPLER_RATIO` defaults to `1.0` in this repo (sample
   everything) — if it's been lowered, a short manual test might simply not get sampled. Check
   with several requests, not one.
5. **Service graph / span metrics panels empty even though traces appear in Tempo's own
   search.** This means traces ARE arriving but the metrics-generator's remote-write to
   Prometheus is failing — see the next entry.

## Tempo metrics-generator not populating Prometheus (service graph / RED-from-traces empty)

1. Confirm `stack/prometheus/values.yaml` has `prometheusSpec.enableRemoteWriteReceiver: true` —
   without it, Prometheus returns 404 to every remote-write attempt and the service-graph /
   span-metrics panels stay empty with no visible error on the Tempo side either.
2. Confirm `stack/tempo/values.yaml`'s `metricsGenerator.remoteWriteUrl` resolves to the actual
   Prometheus Service and includes the `/api/v1/write` path.
3. Check Tempo's own logs for remote-write errors:
   `kubectl logs -n monitoring deploy/tempo | grep -i remote_write`.

## minikube resource exhaustion

1. **Start with real headroom.** `minikube start --cpus=4 --memory=8192` is the floor this repo
   is sized against (`scripts/preflight` checks for it). Running the full stack (Prometheus,
   Grafana, Loki, Promtail, Tempo, Alertmanager, orders-api x2) below that will manifest as pods
   stuck `Pending` (insufficient allocatable CPU/memory on the single node) rather than any error
   message pointing at "not enough resources" directly.
2. **Check allocatable vs. requested**, not raw node capacity — minikube itself, the kubelet, and
   system pods consume some of the node's resources before your workloads get a share:
   ```bash
   kubectl describe node minikube | grep -A10 "Allocated resources"
   ```
3. **A pod Pending with `FailedScheduling: Insufficient cpu/memory`** in its events means exactly
   this — either raise minikube's `--memory`/`--cpus`, or reduce a `resources.requests` value in
   the relevant `values.yaml`/`deployment.yaml` (never remove requests entirely; see
   `app/k8s/deployment.yaml`'s comment on why requests matter for scheduling honesty).
4. **Watch for the disk filling up**, not just CPU/memory — minikube's own VM/container disk is
   finite; `docker system df` (if using the Docker driver) or `minikube ssh -- df -h` shows
   actual usage. `stack/prometheus/values.yaml`'s `retentionSize: 4GB` guard exists specifically
   so Prometheus's own data doesn't consume the whole thing.

## Scrape timeouts under load

If `scripts/trigger-incident` (which also burns CPU via `/chaos/cpu`) causes Prometheus's OWN
scrape of `orders-api` to start timing out (visible as a flapping target or a
`context deadline exceeded` error on the Targets page), that is a REALISTIC side effect, not a
bug — a CPU-starved pod genuinely responds to everything slower, including its own `/metrics`
endpoint. If it's disruptive during a demo, either raise `servicemonitor.yaml`'s
`scrapeTimeout`/`interval` slightly, or reduce the chaos CPU burn's `workers`/`seconds` query
parameters.

## See also

- [`alerting-philosophy.md`](alerting-philosophy.md) — why `TargetDown` exists as its own alert
  separate from the SLO ladder
- [`../runbooks/TargetDown.md`](../runbooks/TargetDown.md) — the on-call runbook for a target
  that's confirmed down, assuming the checklist above didn't resolve it first
- [`architecture.md`](architecture.md) — the full data-flow diagram referenced throughout this
  document

Ahmed Fakhfakh — DevOps / SRE

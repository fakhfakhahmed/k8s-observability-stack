# LEARN.md — observability from first principles

A from-scratch teaching document. If `README.md` is the showpiece, this is the textbook behind
it — written so that someone who has never run Prometheus could read it end to end and then
correctly answer "why did you build it this way" about every file in this repo. It ends with
interview questions and model answers, because that is the actual test of whether any of this
stuck.

---

## 1. Observability vs. monitoring

**Monitoring** answers questions you thought of in advance. You decide ahead of time "I should
watch CPU, memory, and 500-error-count", build a dashboard for exactly those things, and an alert
fires when one of them crosses a line you also decided in advance. Monitoring is good at known
failure modes.

**Observability** is the property of a system that lets you answer questions you did **not**
think of in advance, by exploring the telemetry it already emits. The test is: when something
genuinely novel breaks — a combination of conditions nobody wrote a dashboard for — can you find
the answer by slicing existing data, or do you have to ship new instrumentation and wait for the
bug to recur? A system is observable to the degree the answer is "yes, slice the existing data".

This repo tries to be observable, not just monitored: `orders-api` emits high-cardinality-safe
but richly-labelled metrics, full traces with real attributes, and structured logs — so that an
unanticipated question ("did this only affect checkout requests over €500, during the payment
slow-path, on pod B?") is answerable by composing existing signals, not by redeploying with new
print statements.

## 2. The three pillars, and why none of them alone is enough

| Pillar | Strength | Blind spot |
|---|---|---|
| **Metrics** | Cheap, aggregatable, perfect for "is it broken / how broken / since when" | No detail about any single request — a metric cannot tell you WHICH order failed |
| **Logs** | Full detail about one specific event, in free text | Expensive to query broadly; no built-in sense of causality across services |
| **Traces** | The only pillar with causality: this span caused that span, across process/network boundaries | Sampling means you often don't have the exact trace you want; traces alone don't aggregate into a clean "is my SLO being met" ratio |

The real power is in the SEAMS between them. This repo's entire datasource configuration
(`stack/grafana/datasources/datasources.yaml`) exists to turn those seams into one click: a
latency spike in a metric panel has an exemplar pointing at a real trace; that trace's span has a
`tracesToLogsV2` link to the exact log lines from that request; those log lines carry the
`trace_id` that got you there in the first place. See "Correlation" below for the mechanics.

## 3. Cardinality — the one concept that will bite you hardest

A **time series** in Prometheus is uniquely identified by its metric name plus the full set of
its label key/value pairs. `http_requests_total{method="GET", route="/api/orders", status="200"}`
is one series. Every DISTINCT combination of label values is a SEPARATE series, stored
independently in memory (the "head block") and on disk.

**Cardinality** is the number of distinct series a metric produces. It multiplies:

```
cardinality = (values of label A) x (values of label B) x (values of label C) x ...
```

`http_requests_total` in this repo has `method` (~5 values), `route` (~7, because
`routeLabel()` in `app/main.go` collapses every URL into a bounded template), and `status`
(~8). That's roughly `5 x 7 x 8 = 280` series per pod — trivial.

**The concrete disaster example.** Suppose someone "helpfully" adds a `user_id` label to that
same counter, intending to debug per-user issues. With 50,000 users, cardinality becomes
`280 x 50,000 = 14,000,000` series — for ONE counter, on ONE pod. Each series costs roughly 1-2KB
of resident memory in Prometheus's head block regardless of how often it's actually scraped with
a new value, so that single label addition can cost multiple GB of RAM and push a previously
healthy Prometheus into OOM-death. Worse, each of those 50,000 series is "cold" (touched once,
then abandoned when that user stops making requests), which is exactly the access pattern that
makes TSDB compaction expensive too. This is why `app/main.go`'s comment block calls out
`trace_id`, `order_id`, `user_id`, and `session_id` by name as labels that must NEVER appear on a
metric — and why the ServiceMonitor's `metricRelabelings` in `app/k8s/servicemonitor.yaml` has a
`labeldrop` safety net for exactly those names, in case a future code change adds one by
accident.

The fix when you need per-entity detail is: put the entity ID in a **trace attribute** (free —
traces are per-request already) or a **log field** (cheap — Loki indexes the label, not the
content, see section 9), never a metric label. Metrics answer "how many / how fast / in
aggregate"; traces and logs answer "which specific one".

Loki has the identical rule in a different shape: a LABEL in Loki defines a **stream** (a
physically separate chunk of storage), and the index is built over label combinations, not log
content. A per-request label (like `trace_id`) would create a new stream per request and wreck
the index exactly like a per-user Prometheus label wrecks the head block — see
`stack/loki/promtail-values.yaml`'s comment on why `trace_id` stays a log-body field, extracted
by the `json` pipeline stage, and is deliberately never promoted to a Loki label.

## 4. Prometheus architecture

- **Pull model.** Prometheus initiates every scrape — it reaches out to a target's `/metrics`
  endpoint on a schedule, rather than the target pushing samples to Prometheus. This means: a
  target that is reachable can always be verified ("is there even a listener on that port"), a
  dead target is detectable as a scrape failure (`up == 0`) rather than silence, and Prometheus
  itself controls load (it decides the scrape rate, not N independent clients pushing at
  whatever rate they choose). The trade-off: short-lived jobs (a batch job that runs for 3
  seconds) can finish before a scrape ever happens — solved with the Pushgateway, not used in
  this repo because `orders-api` is a long-running service.
- **Service discovery.** Prometheus doesn't hardcode target IPs; in Kubernetes it discovers them
  via the API server (Endpoints/EndpointSlices behind a Service). The Prometheus **Operator**
  wraps this in a CRD: you write a `ServiceMonitor` (see `app/k8s/servicemonitor.yaml`) describing
  which Service to watch and how to scrape it, and the Operator translates that into the
  low-level `kubernetes_sd_config` + `relabel_configs` Prometheus actually understands.
- **CRDs and selectors — the gotcha.** The `Prometheus` custom resource has
  `serviceMonitorSelector` (which ServiceMonitors it adopts) and
  `serviceMonitorNamespaceSelector` (which namespaces it even looks in). A ServiceMonitor that
  doesn't match BOTH is silently invisible — no event, no log, no error. This repo's
  `stack/prometheus/values.yaml` sets `serviceMonitorSelectorNilUsesHelmValues: false`
  specifically to make this permissive by default; see that file and
  `docs/troubleshooting.md` for the full debugging checklist.
- **TSDB.** Prometheus's storage engine writes samples to an in-memory head block, periodically
  flushing to immutable 2-hour blocks on disk, later compacted into larger blocks. Retention
  (`stack/prometheus/values.yaml`'s `retention: 7d`) decides how far back those blocks are kept
  before deletion.
- **Scrape interval vs. evaluation interval.** The scrape interval (15s here) controls how often
  Prometheus asks each target for data. The evaluation interval (30s here) controls how often
  recording rules and alert rules are RE-COMPUTED. These are independent knobs: you can scrape
  fast and evaluate slow, or vice versa — just know that an evaluation interval shorter than the
  scrape interval gains you nothing, since there's no new data to evaluate against yet.
- **Staleness.** If a series stops being scraped (the pod died, or dropped that label
  combination), Prometheus marks it "stale" after roughly 5 minutes and querying it returns
  nothing rather than a frozen last value. This is why `NoTrafficReceived` in
  `stack/prometheus/rules/alerts-app.yaml` uses `absent_over_time` rather than trusting a ratio
  to go to zero — a ratio's components go *stale*, not to *zero*, and `0/0` is `NaN`, not `0`.

## 5. PromQL from scratch

- **Instant vector vs. range vector.** `http_requests_total` alone is an **instant vector**: one
  value per series, at one point in time (the query's evaluation time). `http_requests_total[5m]`
  is a **range vector**: for each series, every sample from the last 5 minutes, as a matrix.
  Range vectors exist almost exclusively to be fed into functions like `rate()` — you essentially
  never graph a bare range vector.
- **Counters and `rate()`.** A counter (`http_requests_total`) only ever goes up (it resets to 0
  only when the process restarts). Querying it directly tells you "total requests since the
  process started", which is useless for "how busy is it right now". `rate(metric[5m])` computes
  the **per-second average rate of increase** over the window, correctly handling counter resets
  (if it sees the counter drop, it assumes a restart and compensates rather than reporting a
  negative rate). Rule of thumb: **never graph a raw counter**; always wrap it in `rate()` or
  `increase()`.
- **`rate()` vs `irate()` vs `increase()`.**
  - `rate(c[5m])` — average per-second rate over the whole 5m window. Smooth, good for
    alerting and dashboards; this is what every recording rule in
    `stack/prometheus/rules/recording-rules.yaml` uses.
  - `irate(c[5m])` — **instant** rate, computed from only the LAST TWO samples in the window.
    Extremely spiky and reactive; good for a live "what is happening right this second" graph,
    terrible for alerting (a single noisy sample pair can trigger it) — this repo does not use
    `irate` anywhere for exactly that reason.
  - `increase(c[5m])` — the total increase over the window (`rate() x window seconds`,
    extrapolated). Use it when you want a COUNT, not a per-second rate — e.g.
    `PodCrashLooping`'s `increase(... restarts_total[15m]) > 2` asks "did it restart more than
    twice", not "what's its restart rate".
- **Histograms and `histogram_quantile`.** A histogram metric like
  `http_request_duration_seconds` is actually several series: `_bucket{le="0.1"}`,
  `_bucket{le="0.3"}`, ... `_bucket{le="+Inf"}` (cumulative counts of observations ≤ that
  boundary), plus `_sum` and `_count`. `histogram_quantile(0.99, sum by (le) (rate(..._bucket[5m])))`
  estimates the 99th percentile by finding which bucket the 99th-percentile-ranked observation
  falls into, then **linearly interpolating** between that bucket's lower and upper boundary. The
  interpolation is an estimate, not an exact value — its precision is bounded by how close
  together your bucket boundaries are near the percentile you care about. **The classic pitfall**:
  forgetting `le` in the `by()`/`without()` clause of the inner aggregation. Without it, the
  bucket boundary information is summed away before `histogram_quantile` ever sees it, and the
  function either errors or silently returns garbage. See `docs/promql-cookbook.md` entry #7 for
  a worked example of getting this wrong and right.
- **Why this repo's SLO avoids `histogram_quantile` entirely.** An SLO threshold needs to answer
  "what FRACTION of requests were under 300ms", which `histogram_quantile` cannot answer exactly
  — it answers "what VALUE is the 99th percentile", a different question that happens to be
  correlated. `docs/slo-guide.md` section 5 and `stack/prometheus/rules/recording-rules.yaml`
  instead count the exact `le="0.3"` bucket's rate against `_count`'s rate — exact, not
  interpolated, PROVIDED `0.3` is an actual bucket boundary (which is why the buckets in
  `app/main.go` are chosen around the SLO thresholds, not the other way round).
- **Aggregation: `by` vs `without`.** `sum by (route) (metric)` keeps only the `route` label,
  collapsing everything else. `sum without (pod, instance) (metric)` keeps every label EXCEPT the
  ones named, collapsing just those. Use `by` when you know exactly which dimension you want to
  keep (most dashboards); use `without` when you want to collapse per-replica noise (`pod`,
  `instance`) while keeping everything else you haven't thought of yet.
- **`absent()` / `absent_over_time()`.** Both answer "does this series not exist" — the only tool
  for detecting the complete ABSENCE of data, which a `> threshold` comparison can never do
  (a missing series simply doesn't produce a result for the comparison to evaluate, firing
  nothing). `absent_over_time(m[10m])` is the range version, tolerant of a scrape or two being
  missed; this repo's `NoTrafficReceived` and `TargetDown` alerts both depend on this distinction.
- **`predict_linear()`.** Fits a linear regression to a range vector and extrapolates `t` seconds
  into the future — `predict_linear(disk_avail[1h], 4*3600) < 0` asks "at the current trend, will
  this be negative (i.e., full) in 4 hours", which is how `NodeDiskSpaceLow`
  (`stack/prometheus/rules/alerts-infra.yaml`) pages BEFORE the disk is actually full rather than
  after.

## 6. RED vs. USE vs. the Four Golden Signals

| Method | Dimensions | Best for |
|---|---|---|
| **RED** (Rate, Errors, Duration) | Requests/sec, error ratio, latency distribution | Request-driven SERVICES — this is what `app-red-metrics.json` implements for orders-api |
| **USE** (Utilization, Saturation, Errors) | % time busy, queue/backlog depth, error count | RESOURCES — CPU, disk, a connection pool, `queue_depth` |
| **Four Golden Signals** (Google SRE book) | Latency, Traffic, Errors, Saturation | A superset — essentially RED plus an explicit Saturation axis |

This repo uses RED for `orders-api`'s HTTP surface (`http_requests_total`,
`http_request_duration_seconds`) and layers Saturation on top via `http_requests_in_flight` —
which is exactly why `app/main.go`'s comment calls saturation "the signal everybody forgets": RED
alone tells you how the service is performing, but says nothing about how close it is to falling
over. USE is used for the infrastructure layer — node CPU/memory/disk in
`stack/prometheus/rules/alerts-infra.yaml` and `kubernetes-cluster.json`.

## 7. SLI / SLO / SLA and error budgets

Covered in full, with worked derivations, in `docs/slo-guide.md` and `slo/README.md`. The
compressed version:

- **SLI**: a measured ratio of good events to valid events (never a raw percentile — see
  `docs/slo-guide.md` section 1 for why percentiles don't aggregate and ratios do).
- **SLO**: an internal target for that ratio, with a window (this repo: 99.9% availability /
  99% latency-under-300ms, both rolling 30 days).
- **SLA**: an external, contractual promise — always looser than the SLO, so you breach your own
  internal target and have time to fix it before you ever breach what you promised a customer.
- **Error budget** = `(1 - SLO target) x window`. For 99.9% over 30 days:
  `0.001 x 43,200 minutes = 43.2 minutes`.

### Burn rate, derived step by step

Burn rate is "how many times faster than sustainable are we spending the budget right now":

```
burn rate = observed error ratio / (1 - SLO target)
```

**Why 14.4, derived, not copied.** Start from a policy: *"page when 2% of the 30-day budget is
spent within 1 hour."* The identity connecting burn rate to budget consumed is
`consumed = burn_rate x (alerting_window / SLO_period)`, because burn rate 1 means "spend the
whole budget in exactly one SLO period" by definition. Solve for burn rate:

```
0.02 = burn_rate x (1h / 720h)
burn_rate = 0.02 x 720 = 14.4
```

Sanity check: burning at 14.4x exhausts the full 30-day budget in `720/14.4 = 50` hours; one hour
of that is `1/50 = 2%` — consistent. The other three rungs (6x/6h, 3x/1d, 1x/3d) are the same
arithmetic against different policy statements ("5% in 6h", "10% in 1d", "10% in 3d") — see
`stack/prometheus/rules/slo-alerts.yaml`'s header comment for all four worked out, and
`docs/slo-guide.md` section 7 for a minute-by-minute simulation proving the multi-window design.

**Why multi-window.** A single window forces a trade between noise (short window) and a long
"stuck firing after the fix" tail (long window). ANDing a long window (precision) with a short
window (fast reset) gives both: the long window won't fire on a 30-second blip, and the moment
the short window drops back under threshold — roughly `short_window / 2` after the incident ends,
not `long_window` after it — the alert resolves. This is the single most important idea in this
entire repository; see `docs/slo-guide.md` section 7 step 6 for the full table.

## 8. Alertmanager: routing, grouping, inhibition, silences

- **Routing** (`route.routes` in `stack/alertmanager/alertmanager-config.yaml`) is a tree
  evaluated top-down by label matchers; the first matching route claims the alert unless it sets
  `continue: true` to also fall through to later routes (used here so a page ALSO lands in Slack).
- **Grouping** (`group_by`) decides which alerts get bundled into ONE notification. Grouping by
  `alertname, service, slo` means all four `ErrorBudgetBurn` rungs firing for the same incident
  arrive as one Slack message, not four.
- **`group_wait`** is how long Alertmanager waits after the FIRST alert in a brand-new group
  before sending anything — giving related alerts (a second rung, a correlated PodCrashLooping)
  time to join the same notification. **`group_interval`** is the equivalent wait before sending
  an UPDATE to an already-notified group. **`repeat_interval`** is how long a still-firing,
  unchanged group goes before Alertmanager reminds you — short for pages, long for tickets.
- **Inhibition** suppresses a lower-priority alert while a related higher-priority one fires —
  e.g. a critical `ErrorBudgetBurn` rung inhibits the warning rungs for the SAME service+slo,
  because the ladder is strictly ordered (if you're burning at 14.4x you are, by construction,
  also over the 3x and 1x thresholds) and three extra pings add zero information.
- **Silences** (not stored in this repo's config — they're created at runtime via the
  Alertmanager UI/API) temporarily mute a matching alert, typically during planned maintenance.
  They are NOT the same as inhibition: a silence is a manual, time-boxed human decision; an
  inhibition rule is an always-on structural relationship between two alert types.

## 9. Logs: structured logging and label cardinality

Every log line `orders-api` writes is JSON (`log/slog` with a custom handler — see
`app/main.go`'s `traceHandler`), not a free-text sentence. Structured logs are machine-parseable
without regex gymnastics: `| json | duration_ms > 100` in LogQL just works because `duration_ms`
is already a typed field, not buried in a sentence.

**Why Loki indexes labels, not content.** Unlike Elasticsearch (which builds a full-text index
over every log's content), Loki only indexes the LABEL set of a stream; the actual log content is
stored compressed in chunks and is only grep'd (via LogQL's line filters, `|= "text"`) at query
time, over whatever time range and label selector you specify. This is why Loki is so much
cheaper to run than a full-text search engine at the same volume — and why pushing a
high-cardinality value (like `trace_id`, or anything per-request) into a LABEL rather than the
log body defeats that economy model exactly the way an unbounded Prometheus label does: it turns
one cheap stream into millions of expensive, mostly-empty ones. See section 3 above — the rule is
identical in both systems, applied to a different storage shape.

## 10. Traces: spans, propagation, sampling

- A **span** represents one unit of work with a start time, duration, and attributes — a single
  HTTP handler invocation, a database query, a downstream RPC call. A **trace** is a tree of
  spans sharing one `trace_id`, representing one end-to-end request as it moves across process
  and network boundaries. See `handleCheckout` in `app/main.go` for a trace with real depth: a
  server span, nested "inventory.reserve" and "payment-gateway.authorize" client spans, each with
  its own attributes.
- **Context propagation** is how a `trace_id` survives a network hop: the W3C `traceparent`
  header carries it from caller to callee, and the callee's OTel SDK reads it to continue the
  SAME trace rather than starting a new, disconnected one. `otelhttp.NewHandler` in
  `app/main.go` does this automatically for every inbound request; without a propagator
  configured (`otel.SetTextMapPropagator(...)`), every hop would silently start its own
  single-span "trace", which is the classic "my traces only ever have one span" symptom.
- **Sampling: head-based vs. tail-based.** Head-based sampling decides whether to keep a trace
  AT ITS START, before anyone knows if it will be interesting (slow, or erroring) — cheap, but
  you systematically under-sample the rare events you most want, unless you sample at 100% (which
  this repo does, deliberately, at demo traffic levels — see `initTracing()`'s comment in
  `app/main.go`). Tail-based sampling buffers spans until a trace completes, THEN decides —
  letting you keep 100% of errors and slow traces while discarding most of the boring, fast ones
  — but it requires a stateful collector in the path (an OTel Collector), which is exactly the
  "what I'd do next in production" item in `README.md`.
- **What OpenTelemetry standardises.** Before OTel, every vendor (Jaeger, Zipkin, each APM
  vendor) had its own SDK, its own wire format, its own span attribute names. OTel standardises
  the API (how application code creates spans), the SDK (sampling, batching, export), the
  protocol (OTLP, over gRPC or HTTP), and semantic conventions (`service.name`, `http.route`,
  `db.system` — the exact attribute names `app/main.go` uses) — so a backend (Tempo here, but
  equally Jaeger, Honeycomb, Datadog) is a swappable implementation detail, not a rewrite.

## 11. Interview questions you can now answer

**1. What's the difference between observability and monitoring?**
Monitoring answers pre-defined questions with pre-built dashboards/alerts. Observability is the
property that lets you answer NEW, unanticipated questions by exploring existing telemetry
without shipping new code. You want both — monitoring for known failure modes, observability for
the ones you haven't thought of yet.

**2. How do you set an SLO for a new service?**
Pick an SLI that's a ratio of good to valid events (never a raw percentile). Decide what counts
as "good" per status class, explicitly — don't let `4xx` or rate-limiting ride along for free.
Set the target from observed user tolerance, historical achieved performance, or a downstream
contract — never a round number because it sounds impressive. State the budget in minutes, not
just a percentage, because "43 minutes a month" gets a straight answer from a stakeholder and
"99.9%" gets a meaningless nod.

**3. Why alert on burn rate instead of raw error rate?**
A raw error-rate alert has no sense of urgency proportional to actual impact, and no natural way
to distinguish "ticket, not urgent" from "page now" without an arbitrary extra threshold. Burn
rate IS that proportional, principled signal: it's literally "how many times faster than
sustainable", derived from a paging policy you can defend, and it composes cleanly with a
multi-window design that avoids both false pages on noise and a stuck-firing tail after the fix.

**4. Why does a single-window alert flap or stay stuck?**
A short window is noisy (a brief blip crosses any sensible threshold); a long window has a long
MEMORY (bad events linger in the rolling average for the full window length even after the
incident ends, so the alert stays red long after the fix). ANDing a long and short window gets
precision from the long one and a fast reset from the short one.

**5. Why is my ServiceMonitor not being scraped?**
Check, in order: (a) does the `Prometheus` CR's `serviceMonitorSelector`/
`serviceMonitorNamespaceSelector` actually match this object's labels and namespace — a mismatch
is SILENT, no error anywhere; (b) does `endpoints[].port` name a port that actually exists on the
Service (by NAME, not number); (c) does the ServiceMonitor's `selector.matchLabels` actually
match the Service's labels; (d) does the Service have any Endpoints at all (`kubectl get
endpoints`) — a Service/Pod label mismatch produces zero endpoints with no error either. Full
checklist: `docs/troubleshooting.md`.

**6. `rate()` vs `increase()` vs `irate()`?**
`rate()` is the smoothed average per-second rate over a window — the default choice for
dashboards and alerts. `increase()` is the total count over the window (useful when you want "how
many times did X happen", e.g. restart counts). `irate()` uses only the last two samples —
reactive and spiky, good for a live graph, bad for alerting because one noisy sample pair can
trigger it.

**7. How do you reduce Prometheus cardinality?**
Never put an unbounded value (user ID, order ID, trace ID, raw URL path) in a label — collapse it
to a bounded template first (see `routeLabel()` in `app/main.go`). Use `metricRelabelings` as a
defensive backstop to drop/labeldrop known-dangerous label names at ingestion. Push per-entity
detail into traces or logs instead, where it's cheap. Audit with
`topk(10, count by (__name__)(count by (__name__, <suspect_label>)({__name__=~".+"})))`-style
queries or `mimirtool`/`promtool` cardinality analysis in CI before it ships, not after an OOM.

**8. How do you correlate a slow request with its logs?**
The request's trace carries a `trace_id`; the application logs that SAME `trace_id` as a
structured field on every log line written inside that request's span context (see
`traceHandler` in `app/main.go`). Grafana's Loki datasource has a `derivedFields` regex that
matches `trace_id` in the raw log line and renders it as a clickable link into the Tempo
datasource (`stack/grafana/datasources/datasources.yaml`) — click the trace link on the log line,
or use Tempo's `tracesToLogsV2` to go the other direction from an open trace.

**9. What do you do when the error budget is exhausted?**
Follow the written policy (`slo/README.md`), not an ad hoc judgment call: freeze non-essential
releases to the service, put engineering capacity on reliability work, and don't lift the freeze
until the trailing ratio is back under target — which, because the window is rolling, can happen
mid-month as old bad minutes age out, not just at a calendar boundary.

**10. Why exclude health checks and chaos endpoints from an SLO's denominator?**
Because they're not events a USER would be upset about losing. Health checks run at a fixed,
probe-driven rate regardless of real traffic — during an outage, user traffic drops toward zero
while probe traffic stays constant, DILUTING the error ratio exactly when you need it sharpest.
Chaos endpoints exist to be deliberately broken; including them would mean testing your own
alerting burns your real error budget. Full argument: `docs/slo-guide.md` section 1.

**11. What's the difference between a liveness and a readiness probe?**
Liveness answers "is this process wedged and does it need a hard restart" and must check NOTHING
beyond the process itself — a liveness probe that checks a downstream dependency turns a
dependency blip into a cluster-wide restart storm. Readiness answers "should traffic be sent here
right now" and SHOULD consider dependencies and graceful-shutdown state; `handleReadyz` in
`app/main.go` flips to unready the instant SIGTERM arrives, specifically so the Endpoints
controller has time to remove the pod before the process stops accepting connections.

**12. How does Tempo's metrics-generator work, and why does it matter?**
It sits in Tempo's ingestion path and derives Prometheus-shaped RED metrics and service-graph
edges directly from the spans it receives, remote-writing them into Prometheus. The payoff: a
downstream dependency with NO Prometheus client library at all (a vendor API, a legacy service)
still gets RED metrics and shows up on the service graph, purely because something traced a call
to it. See `stack/tempo/values.yaml`.

**13. Why does your histogram have buckets at exactly 0.3 and 0.5 seconds?**
Because the availability-adjacent latency SLO threshold is 300ms and the secondary
HighLatencyP99 alert threshold is 500ms, and an SLO/alert based on a bucket boundary
(`le="0.3"`) is EXACT, while one based on `histogram_quantile`'s linear interpolation between
whatever boundaries happen to exist nearby is an estimate. Buckets are chosen to straddle the
thresholds that matter, not picked from a generic default list.

**14. What's the difference between inhibition and a silence in Alertmanager?**
A silence is a manual, time-boxed human action muting alerts matching some labels — typically
during planned maintenance. Inhibition is an always-on STRUCTURAL rule: alert type A firing
automatically suppresses alert type B firing, with no human in the loop, based on a logical
relationship you've encoded in advance (e.g. a critical SLO rung implies the warning rungs are
also true and therefore redundant).

**15. Why single-binary Loki/Tempo instead of microservices mode?**
Microservices mode exists to scale ingestion, storage and query independently at real production
volume. A demo generating a trickle of traffic from one app on a 4-CPU laptop has no such scaling
need — running a dozen tiny pods instead of one would spend more of the node's limited memory on
per-process overhead than on actually storing data. The RIGHT answer scales with actual load, not
with "what does a 'serious' deployment look like" cargo-culting.

**16. Why does the demo app simulate a queue depth metric and what's it for?**
`queue_depth` is a leading-indicator gauge: it grows the moment errors start being injected
(`runQueueSimulator` in `app/main.go`) because failed work piles up faster than it drains.
`QueueDepthGrowing` watches its SLOPE via `deriv()` (the correct tool for trending a gauge, as
opposed to `rate()`/`increase()` which only apply to counters) and often fires BEFORE the SLO
burn-rate ladder's short window has even accumulated enough bad samples — demonstrating that a
good observability design catches problems from more than one signal, not just the primary SLI.

## Common failure modes (the short version — full detail in `docs/troubleshooting.md`)

| Symptom | Usual cause |
|---|---|
| Target missing from Prometheus, no error anywhere | ServiceMonitor label/namespace selector mismatch |
| `histogram_quantile` returns nothing or garbage | Missing `le` in the inner `by()`/`without()` clause |
| Traces never arrive, no error logged | OTLP endpoint using the wrong port (4318 HTTP vs 4317 gRPC) or scheme left in `WithEndpoint` |
| Loki -> Tempo link doesn't appear on a log line | `trace_id` missing from the log line, or the `derivedFields` regex doesn't match the actual JSON shape |
| Grafana dashboard panel shows "no data" | Datasource `uid` in the dashboard JSON doesn't match the provisioned datasource's `uid` |
| Alert fires correctly but nobody gets paged | `page` or `severity` label missing, or the Alertmanager route's matcher doesn't actually match it |
| SLO burn-rate alert goes SILENT during a total outage | The ratio's denominator went to zero (`NaN`), not 100% bad — covered by `NoTrafficReceived`, not the ladder itself |

---

Ahmed Fakhfakh — DevOps / SRE

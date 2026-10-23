# LogQL cookbook

LogQL looks like PromQL because it was deliberately designed to — a log QUERY always starts with
a **label selector** (cheap: narrows to a stream using the index) and then, optionally, pipes
through **line/label filters** (more expensive: actually reads chunk content). Every query below
matches the real log shape `orders-api` produces: JSON lines with `level`, `service` (promoted to
Loki labels by `stack/loki/promtail-values.yaml`), plus body fields `msg`, `route`, `status`,
`trace_id`, `span_id`, `order_id`, `duration_ms` (see `app/main.go`'s `newLogger`/handlers for the
exact fields each log call attaches).

### 1. The label selector — always start here

```logql
{service="orders-api"}
```
This alone is the cheapest possible query: Loki finds the matching STREAM(S) via its label index
and returns every line, unfiltered. Every query below builds on top of this.

### 2. Filter by level

```logql
{service="orders-api", level="error"}
```
`level` is a genuine Loki LABEL (small, bounded set of values: debug/info/warn/error) — filtering
on it is index-based and cheap, unlike filtering on `route` or `status`, which live in the log
body (see entry 4).

### 3. Line filter — substring match

```logql
{service="orders-api"} |= "checkout failed"
```
`|=` is a raw substring match against the line text, evaluated AFTER the label selector narrows
which streams to read. `!=` is the negated form ("does not contain").

### 4. Parse JSON and filter on a body field

```logql
{service="orders-api"} | json | route="/api/checkout" | status="500"
```
`| json` parses the line's JSON into fields usable by later pipeline stages — `route` and
`status` are NOT Loki labels (deliberately: they'd be low-enough cardinality to be safe, but
keeping the label set minimal keeps the index smaller and the set of labels stable regardless of
future field additions), so they must be extracted with `| json` before you can filter on them.

### 5. Correlate to one exact trace

```logql
{service="orders-api"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
```
The direct LogQL equivalent of clicking a trace link from Grafana's Loki datasource
`derivedFields` — useful when you already have a `trace_id` from a Tempo trace view or an alert
annotation and want every log line from that exact request without leaving a terminal/CLI
context (`logcli query '{service="orders-api"} | json | trace_id="..."'`).

### 6. Numeric filtering on an extracted field

```logql
{service="orders-api"} | json | duration_ms > 200
```
After `| json`, `duration_ms` is available as a typed number, not a string — comparison operators
work directly. This answers "show me only the slow requests' logs" without needing a metric or a
trace at all, though in this repo you'd usually START from the p99 panel's spike and arrive here
second, trace in hand.

### 7. Log volume as a Prometheus-shaped metric — `count_over_time` and `rate`

```logql
sum by (level) (count_over_time({service="orders-api"}[1m]))
sum(rate({service="orders-api", level="error"}[5m]))
```
LogQL can produce METRIC output from log streams using the same `_over_time` and `rate` functions
PromQL uses on range vectors — this is how `logs-explorer.json`'s "log volume by level" and
"error log rate" panels work: they are genuinely Prometheus-shaped time series, just computed
from Loki's log data instead of Prometheus's own TSDB.

### 8. Top error messages — grouping extracted fields

```logql
topk(10, sum by (msg) (count_over_time({service="orders-api", level="error"} | json | __error__="" [1h])))
```
`__error__=""` filters out lines where the `| json` parse itself failed (malformed JSON, or a
line that isn't JSON at all) — without it, a single noisy non-JSON line can show up as its own
spurious "message" group. This is `logs-explorer.json`'s "Top error messages" table query.

### 9. Unwrap a numeric field for a histogram/quantile over logs

```logql
quantile_over_time(0.99, {service="orders-api"} | json | unwrap duration_ms [5m]) by (route)
```
`unwrap` treats an extracted field's VALUE as the sample itself (rather than counting lines) —
this lets LogQL compute a percentile directly from a log-body field, which is useful as a
cross-check against the Prometheus histogram's `histogram_quantile` for the exact same requests,
or for a latency distribution on a field that was never instrumented as a metric at all.

### 10. Multi-stream correlation — compare two services' error volume side by side

```logql
sum by (service) (rate({service=~"orders-api|inventory-service", level="error"}[5m]))
```
A regex label matcher (`=~`) against the `service` label selects MULTIPLE streams in one query —
useful once a second real service exists in the cluster (this repo's `inventory-service` and
`payment-gateway` are currently simulated spans, not separate deployments — see
`handleCheckout` in `app/main.go`).

### 11. Line format — reshaping output for readability

```logql
{service="orders-api"} | json | line_format "{{.route}} [{{.status}}] {{.duration_ms}}ms trace={{.trace_id}}"
```
`line_format` rewrites each returned line using Go template syntax over the already-extracted
fields — useful when scanning a live tail in a terminal and the full raw JSON is more noise than
signal.

### 12. Excluding noisy routes at query time (vs. at ingestion)

```logql
{service="orders-api"} | json | route != "/healthz" and route != "/readyz"
```
`stack/loki/promtail-values.yaml`'s pipeline already DROPS health/readiness probe lines before
they ever reach Loki (cheaper — they never consume ingestion volume or storage at all); this
query-time filter is the fallback for excluding a route you've decided is noisy AFTER logs are
already ingested, without needing a Promtail config change and redeploy.

## See also

- [`../stack/loki/promtail-values.yaml`](../stack/loki/promtail-values.yaml) — the pipeline stages
  that produce the labels and body fields every query above depends on
- [`../stack/grafana/datasources/datasources.yaml`](../stack/grafana/datasources/datasources.yaml) —
  the `derivedFields` config that turns entry 5's correlation into a clickable link
- [`../LEARN.md`](../LEARN.md) section 9 — why Loki indexes labels, not content, and what that
  means for cardinality

Ahmed Fakhfakh — DevOps / SRE

# Screenshot list

The shots to take while running `scripts/trigger-incident` (and `scripts/heal` afterwards) for a
LinkedIn post or a CV portfolio page. Take them in this order — it follows the actual incident
timeline and tells a coherent before/during/after story rather than a grab-bag of disconnected
panels.

Store the actual image files outside this repo (or in a `docs/screenshots/img/` directory you
`.gitignore`) — this file is the shot list and captioning guide, not an image store.

## 1. Baseline — RED dashboard, healthy

`obs-app-red` (orders-api / RED Metrics), BEFORE running `trigger-incident`. Shows a clean
error rate near 0%, p99 comfortably under 300ms, a stable in-flight gauge. This is your "before"
— without it, the "during" shots have no contrast to land.

## 2. RED dashboard under load

Same dashboard, a minute or two into `trigger-incident`. The error rate panel should show a
visible red stat, the latency panel's p99 line should be elevated, and the status-code pie chart
should show a slice of 5xx. Caption idea: *"Injected a 25% error rate + latency fault via the
app's own chaos endpoints — no external tooling needed to prove the alerting works."*

## 3. Error-budget dashboard mid-burn

`obs-slo-budget` (orders-api / SLO Error Budget), same window. The burn-rate ladder panel should
show the 1h/5m lines crossing above the 14.4 threshold line. This is the single most impressive
screenshot in the repo — it's the direct visual proof of the maths documented in
`docs/slo-guide.md`. Caption idea: *"Burn rate crossing 14.4x — at this rate the 30-day budget
(43m12s) is gone in about 50 hours. This is what triggers a page, not a raw error count."*

## 4. Firing alert in Alertmanager

Open Alertmanager (`scripts/port-forward` prints the URL) and screenshot the `ErrorBudgetBurn`
alert in the firing list, expanded to show its labels (`severity=critical`, `burn_rate="14.4"`)
and annotations (`summary`, `runbook_url`, `dashboard_url` all visible). Caption idea: *"Every
alert carries its own runbook link — no 'check the logs' hand-waving."*

## 5. Trace waterfall in Tempo

From Grafana, open the Tempo datasource's search (or jump from an exemplar/service-graph edge),
find a trace captured during the incident, and screenshot the waterfall. If latency chaos is
armed, there should be a visible `chaos.inject_latency` child span; if error chaos is armed, look
for a trace with `chaos.error.injected` and a red/error-marked span. Caption idea: *"Full request
waterfall — app code, simulated inventory-service call, simulated payment-gateway call, and the
exact injected-fault span, all in one trace."*

## 6. Logs correlated to that trace

From the same trace view, click through `tracesToLogsV2` (or copy the `trace_id` and paste it
into the Logs Explorer dashboard's search), and screenshot the matching log line(s) — ideally
showing the `trace_id` field and the error-level log entry for that exact request. Caption idea:
*"One click from a slow trace to the exact log line that explains it — this is what trace_id in
every log line buys you."*

## 7. Prometheus targets page

`http://localhost:9090/targets` — all `orders-api`, `kube-state-metrics`, `node-exporter`, `loki`,
`tempo` targets green/UP. A boring screenshot that matters: it proves the whole stack is actually
wired together and scraping successfully, which is the prerequisite for every other screenshot
on this list meaning anything.

## 8. Resolution — alert resolved, budget recovering

After `scripts/heal`, wait roughly one short-window period (5 minutes for the 14.4x rung), then
screenshot Alertmanager showing the alert in its resolved/green state, and the RED dashboard back
to baseline. Caption idea: *"Resolved ~5 minutes after the fix, not 57 — this is the entire point
of the multi-window design over a single-window alert."*

## Posting checklist

- [ ] Redact or crop out anything you don't want public (local file paths, hostnames you'd rather
      not disclose, your actual Slack/PagerDuty webhook values — they're placeholders in this
      repo already, but double-check a screenshot from your own fork doesn't leak a real one).
- [ ] Caption each image with WHAT it shows and WHY it matters, not just "dashboard screenshot" —
      the captions above are a starting point.
- [ ] Link back to the repo (`https://github.com/fakhfakhahmed/k8s-observability-stack`) in the
      post, and specifically call out `README.md`'s "Key capabilities" table — that's the
      35-second version of the whole project for someone scrolling past.

Ahmed Fakhfakh — DevOps / SRE

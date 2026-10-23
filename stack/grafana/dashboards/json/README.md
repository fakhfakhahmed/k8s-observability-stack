# Dashboards as code

Every dashboard in this directory is a plain Grafana JSON model, checked into git, loaded by a
Kubernetes Sidecar container rather than clicked together in the Grafana UI. This document is
the "how does that actually work, and what do I do when I want to change one" reference.

## How it gets from this file to your screen

```
stack/grafana/dashboards/json/*.json
        |  wrapped into a ConfigMap, one per file, each labelled
        |  grafana_dashboard: "1"   (scripts/install-stack.ps1 / .sh do this)
        v
kubectl apply -f <generated ConfigMaps> -n monitoring
        |
        v
the Grafana pod's SIDECAR container (grafana-sc-dashboards, enabled by
stack/prometheus/values.yaml's grafana.sidecar.dashboards block) watches
every namespace for ConfigMaps carrying that label
        |  copies the ConfigMap's JSON data into a file under /tmp/dashboards
        v
stack/grafana/dashboards/dashboards-provider.yaml's file provider
(updateIntervalSeconds: 30) notices the new/changed file and tells
Grafana's own provisioning API to load it
        |
        v
Dashboard appears in Grafana, in the folder named by the ConfigMap's
grafana_folder annotation (or "General" if absent) — no restart, no click
```

The effect: edit a `.json` file in this directory, re-apply the ConfigMap (or just re-run
`scripts/install-stack`, which is idempotent), and the dashboard updates in Grafana within 30
seconds. Nobody imports a dashboard by pasting an ID into a text box.

## Why not just build these in the UI?

You can — and should, while iterating on a new panel; the Grafana UI's query editor and panel
preview are a much faster feedback loop than editing raw JSON. The discipline is in what happens
**after** you're happy with it:

1. Build/tweak the panel in Grafana's UI against the live datasource.
2. **Export it**: dashboard settings (gear icon) → JSON Model → copy the JSON, or use
   `Share → Export → Save to file`.
3. Paste that JSON back into the matching file here, reformat for readability, and replace any
   environment-specific values the exporter baked in (see the next section).
4. Re-apply, verify the dashboard still renders correctly from the file-provisioned copy, commit.

A dashboard that only exists inside Grafana's own database is one `helm uninstall` away from
gone forever, cannot be code-reviewed, and cannot be diffed to see what actually changed between
an incident and the fix. Every dashboard in a portfolio or production repo should survive
`kubectl delete namespace monitoring`.

## What the Grafana UI exporter gets wrong, and what to fix by hand

Exported JSON is **not** ready to commit as-is. Specifically:

- **`id`**: the exporter includes a numeric `id` tied to that specific Grafana instance's
  database row. Delete it (or set it to `null`) — provisioning uses `uid`, not `id`, to decide
  whether it's creating or updating a dashboard. Leaving a stale `id` in can cause Grafana to
  silently refuse to update an existing dashboard.
- **`uid`**: KEEP this one, and keep it stable forever once chosen — alert `dashboard_url`
  annotations across `stack/prometheus/rules/*.yaml` hardcode URLs like
  `http://localhost:3000/d/obs-slo-budget`. Changing a uid breaks every link pointing at it.
- **Datasource references**: the exporter sometimes bakes in a datasource's internal numeric ID
  or a machine-specific UID picked up from the instance you exported from. Every datasource
  reference in this repo's dashboards uses the explicit, stable form
  `{"type": "prometheus", "uid": "prometheus"}` (or `loki` / `tempo`) — these UIDs are fixed in
  `stack/grafana/datasources/datasources.yaml` and will match on any fresh install of this repo.
  Replace any numeric or auto-generated UID the exporter leaves behind with the matching name
  from that file.
- **`version`**: the exporter's `version` field is Grafana's internal edit-counter for that
  dashboard. Reset it to `1` (or just leave it as checked in) — it does not need to track
  anything meaningful in git; git history is the real version log.
- **Absolute time ranges**: if you were looking at a specific incident window while building the
  panel, `"time": {"from": "...", "to": "..."}` may have an absolute timestamp baked in. Put it
  back to a relative range (`now-1h`, `now-6h`) before committing, or every future viewer opens
  the dashboard looking at a dead window from whenever you built it.

## Conventions used across every dashboard here

- `schemaVersion: 39`, explicit `uid`, a `description`, and `tags` including
  `k8s-observability-stack` so they're easy to find/filter in a larger Grafana instance.
- Every `$__tags`/templating variable follows the PromQL label names the app actually
  exposes — see `app/main.go` and `docs/promql-cookbook.md`, never an invented label.
- Dashboard UIDs are deliberately short and stable: `obs-app-red`, `obs-slo-budget`,
  `obs-k8s-cluster`, `obs-logs-explorer`. If you add a new dashboard, give it an `obs-*` uid and
  update any alert `dashboard_url` annotations that should point at it.
- Panels prefer recording rules (`route:http_requests:rate5m`, `job:slo_availability_errors:*`,
  etc., from `stack/prometheus/rules/recording-rules.yaml`) over re-deriving the same ratio
  inline, for the same consistency reason the recording rules themselves exist.

## Adding a new dashboard

1. Build it in the Grafana UI against the running stack (`scripts/port-forward` to reach it).
2. Export, clean up per the checklist above, save as `stack/grafana/dashboards/json/<name>.json`.
3. Validate it parses: `python -c "import json; json.load(open('stack/grafana/dashboards/json/<name>.json'))"`.
4. Re-run `scripts/install-stack` (idempotent) to regenerate and re-apply the ConfigMaps.
5. If any alert should link to it, add/update its `dashboard_url` annotation in
   `stack/prometheus/rules/*.yaml`.

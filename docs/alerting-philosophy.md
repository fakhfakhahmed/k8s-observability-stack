# Alerting philosophy

Why this repo's alerts are shaped the way they are, and the rules we apply before adding a new
one. The maths behind the SLO ladder specifically lives in `slo-guide.md`; this document is about
the surrounding judgment calls.

## Symptom-based vs. cause-based alerting

A **symptom** alert fires on something a USER would notice: elevated error rate, slow responses,
no traffic at all. A **cause** alert fires on something that MIGHT eventually produce a symptom:
high CPU, a full disk, a restarting pod.

This repo pages almost exclusively on symptoms (`ErrorBudgetBurn`, `HighErrorRate`,
`HighLatencyP99`) and uses cause alerts for lower-urgency tickets (`NodeMemoryPressure`,
`NodeDiskSpaceLow`, `PVCNearlyFull`). The reasoning:

- **A cause does not always produce a symptom.** A node at 85% memory that stays there forever
  never hurts a single user. Paging on it trains people to ignore pages.
- **A symptom can have a cause you never anticipated.** If you only alert on known causes, a
  genuinely novel failure mode (the one you didn't think to write a cause-alert for) produces
  silence, not an alert, right up until a symptom alert fires — which is when you actually
  needed to know.
- **Symptoms are what you promised.** The SLO describes a promise to users. Burning the error
  budget IS breaking that promise, in progress, measurably. A CPU percentage is not a promise to
  anyone.

Cause alerts earn a place when they are a reliable, well-understood LEADING INDICATOR of an
imminent symptom with enough lead time to act — `NodeDiskSpaceLow`'s `predict_linear` forecast is
exactly this: it pages before the disk is full, which is meaningfully earlier than any symptom
alert could fire, and a full disk is an unambiguous, well-understood precursor to an outage.
`QueueDepthGrowing` sits in between: it is cause-adjacent (queue depth is not itself user-visible)
but is kept at `warning` severity specifically because it is a hypothesis about what's coming,
not a confirmed symptom — see its annotation in `stack/prometheus/rules/alerts-app.yaml`.

## Why page on SLO burn, not CPU

CPU usage has no natural threshold that means "users are hurting" — 90% CPU with headroom and
good p99 latency is a non-event; 40% CPU with a misbehaving noisy-neighbor process starving the
one thread handling requests is a genuine incident. CPU is a RESOURCE number; it says nothing
about outcome. The error budget burn rate, by contrast, is defined in terms of the actual user
contract (the SLO) and is dimensionless and comparable across services — "burning at 14.4x" means
exactly the same thing for `orders-api` as it would for any other service with any other SLO
target, which is what lets one Alertmanager routing/inhibition configuration generalize across an
entire fleet of services without per-service tuning. See `slo-guide.md` section 7 for the full
derivation of the thresholds this repo pages on.

## Alert fatigue, and the design choices that fight it

Alert fatigue is not caused by having "too many alerts" in the abstract — it's caused by a high
rate of alerts that do not require a distinct action. Every design choice below exists to keep
that rate low without ALSO making the important stuff slower to detect:

- **Multi-window burn-rate alerting** (see `slo-guide.md`) avoids the single most common cause of
  fatigue: an alert that stays red for an hour after the problem is already fixed, teaching
  on-call to distrust it.
- **Inhibition** (`stack/alertmanager/alertmanager-config.yaml`) collapses a cascade from one root
  cause into one notification — a crash-looping pod does not also need to separately tell you its
  error rate is high and its p99 is bad; those are consequences of the same fact.
- **Grouping** (`group_by: [alertname, service, slo]`) bundles the four burn-rate rungs for one
  incident into one Slack thread instead of four separate messages.
- **One alertname, many labels** for `ErrorBudgetBurn` means adding a new SLO (see
  `slo-guide.md` section 9) requires zero new Alertmanager configuration — consistency without
  per-alert tuning is itself an anti-fatigue property, because it means the routing behaviour you
  trust for alert #1 is guaranteed to also apply to alert #50.
- **Severity actually means something.** `critical`/`page: "true"` is reserved for things that
  warrant waking a human; `warning` alerts go to a ticket queue and are explicitly muted from
  REPEATING outside business hours (though still visible) — see the `mute_time_intervals` on the
  `slack-warning` receiver. A team that pages on everything "to be safe" ends up, in practice,
  paging on nothing, because the signal-to-noise ratio collapses and the page gets silenced on
  the phone instead of fixed.

## What makes an alert actionable

Every alert rule in this repo is required (see the SLO review checklist in `slo-guide.md` section
8, applied repo-wide) to answer, in its own annotations, three questions without the on-call
engineer leaving the notification:

1. **How bad, exactly, right now?** — the `description` is templated with `{{ $value }}`, not a
   generic sentence. "Error ratio is 3.2%" is actionable; "errors detected" is not.
2. **What do I do?** — `runbook_url` always points at a SPECIFIC file (`runbooks/*.md`), never a
   generic "check the logs". A runbook without numbered, falsifiable steps is not a runbook.
3. **Where do I look?** — `dashboard_url` jumps straight to the relevant panel, with template
   variables pre-filled where possible (e.g. `HighErrorRate`'s `dashboard_url` includes
   `var-route={{ $labels.route }}`).

An alert missing any of these three is, by this repo's standard, not finished — it is a half-built
alert that will be ignored under pressure exactly when it matters most.

## The Watchdog / dead man's switch pattern

`stack/alertmanager/alertmanager-config.yaml` routes an always-firing `Watchdog` alert (shipped
by kube-prometheus-stack's `defaultRules`) to a `null` receiver — it is never meant to notify
anyone directly. Its value is structural: an external monitor (a separate uptime check against
Alertmanager's own `/api/v2/alerts` endpoint, or a PagerDuty "heartbeat" feature) watches for
Watchdog's CONTINUED PRESENCE. If Watchdog ever stops appearing, that proves something in the
pipeline between Prometheus's rule evaluator and Alertmanager's receivers has broken — which is
the one failure mode in which every OTHER alert in this file would also be silently dead. A
monitoring system has no way to alert on its own total failure using its own alerting path; the
dead man's switch is the standard answer — "we require a constant heartbeat, and the ABSENCE of
the heartbeat is itself the alarm", borrowed from the literal railway dead-man's switch that stops
a train if the driver stops actively holding it down.

## See also

- [`slo-guide.md`](slo-guide.md) — the maths behind the burn-rate thresholds referenced above
- [`promql-cookbook.md`](promql-cookbook.md) — query patterns, including `absent_over_time` and
  `predict_linear`, used by the alerts discussed here
- [`../stack/alertmanager/alertmanager-config.yaml`](../stack/alertmanager/alertmanager-config.yaml) —
  the routing tree, grouping and inhibition rules implementing this philosophy
- [`../runbooks/README.md`](../runbooks/README.md) — the runbook index every alert links into

Ahmed Fakhfakh — DevOps / SRE

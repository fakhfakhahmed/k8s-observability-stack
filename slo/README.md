# SLOs — definitions, error budgets, and the policy for when they run out

This is the short, operational companion to `docs/slo-guide.md` (which has the full derivation
of every PromQL expression and the burn-rate maths). Read this one for "what do these terms mean
and what do we actually DO", and that one for "why is the query written exactly this way".

## SLI vs SLO vs SLA

| Term | What it is | Example in this repo |
|---|---|---|
| **SLI** (Service Level *Indicator*) | A measured ratio of good events to valid events. A number between 0 and 1, computed continuously. | `job:slo_availability_errors:ratio_rate5m` (stored as the *bad* fraction) |
| **SLO** (Service Level *Objective*) | An internal target for the SLI, with a window. Something the team commits to itself. | "99.9% of requests are non-5xx over a rolling 30 days" (`slo/availability.yaml`) |
| **SLA** (Service Level *Agreement*) | An external, usually contractual promise to a customer, typically looser than the internal SLO and backed by a penalty (credits, refunds) if missed. | Not defined in this repo — a demo app has no paying customers. In a real org the SLA is deliberately looser than the SLO: you want to breach your own internal objective and fix it BEFORE you ever breach what you promised a customer. |

The SLO is always the tighter, internal number. If your SLO and your SLA are the same number,
you have no margin to detect and fix a problem before you owe someone money.

## Error budgets

An error budget is just the SLO restated as an allowance instead of a percentage:

```
error budget = (1 - SLO target) x SLO window
```

Thinking in minutes-of-allowed-badness rather than "nines" is what makes the number actionable —
see `docs/slo-guide.md` section 3 for the full argument. The table below is the reference most
people reach for first.

### Error budget maths table (30-day rolling window)

| SLO target | Allowed failure | Budget per 30 days | Budget per 7 days | Budget per day |
|---|---|---|---|---|
| 99% | 1% | 7h 12m 00s | 1h 40m 48s | 14m 24s |
| 99.5% | 0.5% | 3h 36m 00s | 50m 24s | 7m 12s |
| 99.9% | 0.1% | 43m 12s | 10m 05s | 1m 26s |
| 99.95% | 0.05% | 21m 36s | 5m 02s | 43.2s |
| 99.99% | 0.01% | 4m 19s | 1h 00.5s *(≈1m)* | 8.6s |
| 99.999% | 0.001% | 25.9s | 6.0s | 0.86s |

(Numbers rounded to the second; "budget per day" = budget per 30 days ÷ 30, stated for intuition
only — the alerts in `stack/prometheus/rules/slo-alerts.yaml` always evaluate against the full
30-day rolling budget, never a daily slice, because a daily reset creates exactly the gaming
incentive `docs/slo-guide.md` section 4 warns about.)

`orders-api` targets **99.9%** (43m12s/month) for availability and **99%** (7h12m/month) of
`/api/orders` + `/api/checkout` requests under 300ms for latency. See `docs/slo-guide.md` section
3, "Why 99.9% here", for the justification specific to a single-node minikube demo.

## The error-budget policy

An SLO without a policy for what happens when the budget runs out is a number nobody acts on.
This is the policy this repo assumes (adapt the specifics, keep the shape):

| Budget remaining | What it means | What the team does |
|---|---|---|
| **> 50%** | Healthy margin | Ship normally. No extra process. |
| **20% – 50%** | Spending faster than sustainable, but not urgent | Flag it in the next team sync. Look for a recent trend (a slow regression, not a spike) before it compounds. |
| **0% – 20%** | Close to exhausted | **Freeze non-essential releases** to this service. Any change that ships must include a rollback plan and be reviewed with the SLO in mind. Prioritise reliability work over new features until the budget starts recovering. |
| **Exhausted (0% or negative)** | Promise already broken for this window | Full feature freeze. All engineering capacity on the service goes to reliability until the trailing 30-day ratio is back under target. A post-incident review is mandatory for whatever burned the budget, even if no single alert felt like "a big incident" — a slow bleed (the 1x burn-rate rung) counts. |

The freeze is the entire point of having an error budget instead of just "try to keep errors
low": it converts "reliability vs. velocity" from a permanent political argument into a
number everyone already agreed to in advance. Nobody has to personally decide "is now a bad time
to ship" — the budget decides, and it decided before anyone had a vested interest in the answer.

**Rolling window implication**: because this repo uses a rolling 30-day window (not a calendar
month — see `docs/slo-guide.md` section 4), an exhausted budget is not "wait until the 1st".
It recovers continuously as old bad minutes age out of the window. A freeze can lift mid-month
the moment the trailing ratio clears the target again — track it on `slo-error-budget.json`'s
burn-down panel rather than waiting for a calendar date.

## Files in this directory

- [`availability.yaml`](availability.yaml) — the availability SLO, in an OpenSLO/Sloth-compatible
  declarative shape: SLI query, target, window, and the burn-rate alert configuration.
- [`latency.yaml`](latency.yaml) — same shape, for the 300ms latency objective.
- [`sloth/`](sloth/) — the equivalent definitions expressed as native Sloth specs, plus a note on
  generating `PrometheusRule` objects from them instead of hand-writing
  `stack/prometheus/rules/recording-rules.yaml` and `slo-alerts.yaml` (which this repo does by
  hand, deliberately — see that directory's README for why).

## See also

- [`docs/slo-guide.md`](../docs/slo-guide.md) — the full worked derivation: SLI selection,
  exclusion-list rationale, recording rule design, and the burn-rate maths proven step by step.
- [`docs/alerting-philosophy.md`](../docs/alerting-philosophy.md) — why burn rate, specifically,
  is the thing to page on instead of a raw error count or CPU.
- [`stack/prometheus/rules/slo-alerts.yaml`](../stack/prometheus/rules/slo-alerts.yaml) — the
  actual `PrometheusRule` implementing the four-rung ladder described above.
- [`runbooks/ErrorBudgetBurn.md`](../runbooks/ErrorBudgetBurn.md) — what an on-call engineer does
  when one of these alerts actually fires.

Ahmed Fakhfakh — DevOps / SRE

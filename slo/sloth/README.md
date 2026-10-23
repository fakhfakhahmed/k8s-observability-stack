# Sloth specs

[`orders-api.sloth.yaml`](orders-api.sloth.yaml) defines both orders-api SLOs (availability,
latency) in native [Sloth](https://sloth.dev) format. Feed it to the `sloth` CLI to generate a
`PrometheusRule` equivalent to the one this repo hand-writes and ships at
[`stack/prometheus/rules/slo-alerts.yaml`](../../stack/prometheus/rules/slo-alerts.yaml):

```bash
sloth generate -i slo/sloth/orders-api.sloth.yaml -o /tmp/generated-slo-rules.yaml
```

Nothing in this repo's scripts runs this command — it is here as a reference, not a build step.
See the long comment at the top of `orders-api.sloth.yaml` for why this repo hand-writes and
heavily comments its PrometheusRules instead of generating them: the generated file would be
correct but silent about *why* 14.4 is the page threshold, which defeats the point of a
portfolio repo built to demonstrate the reasoning, not just the output. On a team running more
than a handful of services, that trade reverses and Sloth's consistency wins — see that same
comment block for the full argument either way.

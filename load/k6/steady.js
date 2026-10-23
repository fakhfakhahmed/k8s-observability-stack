// =============================================================================
// load/k6/steady.js — baseline ("steady state") traffic generator for orders-api
// -----------------------------------------------------------------------------
// Part of: k8s-observability-stack
// Author:  Ahmed Fakhfakh — DevOps / SRE
//
// WHY THIS FILE EXISTS
// --------------------
// An observability stack with no traffic is a set of empty dashboards. This
// script produces *boring, representative* traffic so that:
//   1. the RED dashboard (uid `obs-app-red`) has a signal to draw,
//   2. the SLO/error-budget dashboard (uid `obs-slo-budget`) has a denominator,
//   3. the `NoTrafficReceived` alert stays silent,
//   4. the recording rules (`route:http_requests:rate5m` et al.) evaluate to
//      something other than NaN.
//
// It is the control group. `spike.js` and `failure-scenario.js` are the
// experiments. You cannot interpret an experiment without a control.
//
// -----------------------------------------------------------------------------
// K6 CONCEPTS — read this once if you have never used k6
// -----------------------------------------------------------------------------
// VU ("virtual user")
//     One concurrent, independent worker running your `export default` function
//     in a loop. A VU is NOT a thread and NOT a browser — it is a goroutine
//     running a JavaScript runtime. 10 VUs means 10 requests can be in flight
//     at once, not "10 requests per second".
//
// ITERATION
//     One complete execution of the `export default function ()`. A VU runs
//     iteration after iteration until the test stage ends. Throughput is
//     therefore (VUs / iteration_duration), which is why `sleep()` directly
//     controls your request rate in this executor.
//
// STAGES (the `ramping-vus` executor, selected implicitly by `options.stages`)
//     A list of {duration, target} steps. k6 linearly interpolates the VU count
//     from the previous target to the new one. Ramping matters: slamming a cold
//     JVM/Go process with full load conflates "cold start" with "overload".
//
// THRESHOLDS
//     Pass/fail criteria evaluated over the WHOLE test run. If a threshold is
//     breached, k6 exits non-zero. This is the bit that makes k6 a CI gate
//     rather than a toy. Thresholds are the test's contract.
//
// CHECKS
//     Per-response assertions. A failing check does NOT fail the test by itself
//     — it only increments the `checks` metric. That is the whole distinction:
//       - a check says "this one response was wrong",
//       - a threshold says "too many of them were wrong, fail the build".
//     We bridge the two with the `checks: ['rate>0.99']` threshold below.
//
// GROUPS
//     Named blocks that tag every metric emitted inside them with
//     `group:"::<name>"`. Lets you read p99 per user journey instead of one
//     undifferentiated blob. Cheap to add, expensive to retrofit.
//
// TAGS
//     Key/value labels attached to samples. k6 adds `name`, `status`, `method`
//     automatically; we add `scenario` and `route` so the summary is sliceable.
// =============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import exec from 'k6/execution';

// -----------------------------------------------------------------------------
// Target. Defaults to the in-cluster DNS name because the recommended way to run
// this is as a Kubernetes Job inside the `demo` namespace (see
// load/k8s/k6-job.yaml) — k6 is not installed on the Windows host.
//
// Running from the host instead? Port-forward first (scripts/port-forward) and
// then: k6 run -e BASE_URL=http://localhost:8080 load/k6/steady.js
// -----------------------------------------------------------------------------
const BASE_URL = __ENV.BASE_URL || 'http://orders-api.demo.svc.cluster.local:8080';

// Tunables, all overridable with `-e NAME=value` / Job env vars.
const VUS = Number(__ENV.VUS || 10);          // plateau concurrency
const HOLD = __ENV.DURATION || '8m';          // plateau duration
const THINK_MIN = Number(__ENV.THINK_MIN || 0.4); // seconds, lower think-time bound
const THINK_MAX = Number(__ENV.THINK_MAX || 1.2); // seconds, upper think-time bound

// =============================================================================
// CUSTOM METRICS
// -----------------------------------------------------------------------------
// k6 gives you four metric types, and they map 1:1 onto Prometheus concepts:
//   Counter — monotonically increasing total          (Prometheus counter)
//   Gauge   — last observed value                     (Prometheus gauge)
//   Rate    — proportion of non-zero/true observations (a ratio, like our SLI)
//   Trend   — a distribution; k6 computes avg/min/max/p(90)/p(95)/p(99)
//             (the moral equivalent of a Prometheus histogram, except k6
//              keeps exact samples rather than fixed buckets)
// =============================================================================

// Checkout is the money path. We track it separately from the global
// `http_req_duration` so that a slow checkout cannot hide behind fast
// GET /api/orders calls — exactly the aggregation trap the RED dashboard
// avoids by breaking p99 down per `route`.
const checkoutLatency = new Trend('checkout_latency_ms', true);

// Business-level success counter. Mirrors the app's own
// `orders_processed_total{status="success"}` counter. Comparing the two is a
// genuinely useful cross-check: if k6 says it created 4,000 orders and
// Prometheus says 3,200, you have found either a dropped-request bug or a
// scrape/counter-reset problem.
const ordersCreated = new Counter('orders_created_total');

// Business errors are NOT the same as transport errors. A 200 OK carrying
// `{"status":"rejected"}` is a business error and a transport success. Keeping
// them apart is the difference between "the HTTP layer is fine" and
// "the product is fine".
const businessErrors = new Rate('business_errors');

// =============================================================================
// OPTIONS
// =============================================================================
export const options = {
  // ---------------------------------------------------------------------------
  // STAGES — 0 -> 10 VUs over 1m, hold 10 VUs for 8m, ramp down over 1m.
  // Total wall clock: 10 minutes. That is deliberate: it is two full 5m
  // recording-rule windows plus slack, so `route:http_requests:rate5m` and
  // `job:slo_availability_errors:ratio_rate5m` both reach a stable value and
  // you can actually read the dashboard instead of watching a transient.
  // ---------------------------------------------------------------------------
  stages: [
    { duration: '1m', target: VUS }, // ramp up — lets Go's scheduler, the HTTP
                                     // connection pool and the HPA settle
    { duration: HOLD, target: VUS }, // plateau — THIS is the measurement window
    { duration: '1m', target: 0 },   // ramp down — graceful, avoids a cliff that
                                     // would look like an outage on the dashboard
  ],

  // ---------------------------------------------------------------------------
  // THRESHOLDS — THE IMPORTANT PART
  // ---------------------------------------------------------------------------
  // These numbers are DELIBERATELY IDENTICAL to the Prometheus SLOs defined in
  // slo/availability.yaml and slo/latency.yaml:
  //
  //   | SLO            | Prometheus (production)         | k6 (pre-production)        |
  //   |----------------|---------------------------------|----------------------------|
  //   | Availability   | 99.9% non-5xx over 30d rolling  | http_req_failed rate<0.001 |
  //   | Latency        | 99% of requests < 300 ms        | http_req_duration p(99)<300|
  //
  // The point is not that one number is 30 days and the other is 10 minutes.
  // The point is that the *contract* is the same contract. If a change cannot
  // hold the SLO for ten minutes under 10 VUs on a laptop, it has no business
  // being given a 30-day budget in production. This is "shifting SLO
  // verification left": the same threshold that pages you at 03:00 fails the
  // pull request at 14:00, where it is three orders of magnitude cheaper.
  //
  // Threshold syntax note: `p(99)<300` is in MILLISECONDS because k6's
  // `http_req_duration` is milliseconds, whereas Prometheus'
  // `http_request_duration_seconds` is seconds. 300 ms == 0.3 s == the
  // `le="0.3"` histogram bucket in the contract. Same threshold, different unit.
  // ---------------------------------------------------------------------------
  thresholds: {
    // 99.9% availability SLO. `http_req_failed` is a Rate of requests that were
    // transport failures or (by k6's default) HTTP >= 400.
    http_req_failed: ['rate<0.001'],

    // 99th percentile latency SLO, 300 ms, matching the contract exactly.
    // A second, looser rung at 500 ms mirrors the `HighLatencyP99` alert's
    // secondary threshold mentioned in the contract — it tells you whether you
    // missed by a hair or by a mile.
    http_req_duration: ['p(99)<300', 'p(99.9)<500'],

    // Bridge from checks to pass/fail. >99% of assertions must hold.
    checks: ['rate>0.99'],

    // The money path gets its own, explicitly scoped budget.
    checkout_latency_ms: ['p(99)<300'],

    // Business-level correctness. Rejections happen in real life (stock,
    // fraud, validation) so this is not zero — but it must stay small.
    business_errors: ['rate<0.02'],

    // Per-group latency. Threshold keys can be sub-metric selectors using
    // `metric{tag:value}` syntax; this is how you assert per-journey SLOs.
    'http_req_duration{group:::browse orders}': ['p(99)<300'],
    'http_req_duration{group:::checkout}': ['p(99)<300'],
  },

  // Tags applied to every single sample this test emits. If you later ship k6
  // metrics to Prometheus (see the README's remote-write section) these become
  // Prometheus labels, which is how you tell a steady run from a spike run in
  // the same TSDB.
  tags: {
    scenario: 'steady',
    testid: __ENV.TESTID || 'steady-local',
  },

  // Don't let a single pathological request hold a VU hostage for a minute.
  // 10 s is ~33x our SLO, so anything hitting it is genuinely broken.
  // k6's `timeout` is per-request; see also `http.setResponseCallback` below.
  // (Set here as a default; individual calls can override.)
  noConnectionReuse: false, // keep-alive ON — matches how a real client behaves
                            // behind a Service/kube-proxy. Turning this off
                            // measures TCP+TLS setup, not your application.

  // Which percentiles the end-of-test summary prints for every Trend metric.
  // p(99) is here because p(99) is the SLO; if your summary does not print the
  // statistic your SLO is written in, your summary is decoration.
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// Tell k6 that only 2xx and 3xx are "expected responses"; everything else
// increments `http_req_failed`. Declared at module scope so it applies to every
// request in the file.
//
// Note this makes k6 STRICTER than the Prometheus availability SLI on purpose:
// the SLI counts only 5xx as "bad" (a client sending garbage is not an outage),
// whereas here a 404 or 400 also fails the run. In a load test every request is
// one we wrote, so a 4xx means the test or the API contract is wrong — and that
// should fail the build. See load/k6/README.md for the full rationale.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }));

// =============================================================================
// HELPERS
// =============================================================================

/**
 * Pseudo-unique request id. Real clients send one; it makes a single request
 * traceable across the app log line, Loki, and the k6 output.
 *
 * NOTE ON TRACING — deliberate design decision:
 * We do NOT send a W3C `traceparent` header here. The orders-api service is
 * instrumented with the OpenTelemetry Go SDK and *generates* the root span
 * itself (OTEL_SERVICE_NAME=orders-api, exporting OTLP/gRPC to
 * tempo.monitoring.svc.cluster.local:4317). Letting the server own the root
 * span keeps the Tempo trace tree clean and avoids k6 synthesising thousands
 * of orphan client spans that nobody will ever look at.
 *
 * If you DID want client-initiated traces — for example to measure the network
 * leg between the load generator and the Service — you would generate a
 * `traceparent` of the form:
 *
 *     00-<32 hex trace id>-<16 hex span id>-01
 *
 * and send it as a header; the Go otelhttp middleware would then adopt it as
 * the parent and the Tempo trace would start at k6. k6 also ships a native
 * `k6/experimental/tracing` module that does exactly this automatically.
 * We keep it off: server-generated traces are the correct default, and the
 * app already stamps `trace_id` into every slog JSON line so Grafana's
 * derivedFields can pivot from a Loki log straight into the Tempo trace.
 */
function requestId() {
  // Date.now() gives wall-clock ordering; the random suffix avoids collisions
  // between VUs that start an iteration in the same millisecond.
  return `k6-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * Standard headers for every request. `User-Agent` is set so that these
 * requests are trivially identifiable in Loki:
 *
 *     {namespace="demo", app="orders-api"} |= "k6-steady"
 */
function headers(extra) {
  return Object.assign(
    {
      'User-Agent': 'k6-steady/1.0',
      'X-Request-Id': requestId(),
      Accept: 'application/json',
    },
    extra || {}
  );
}

/**
 * Think time with jitter. Real users do not arrive on a metronome, and a
 * metronome is actively harmful here: perfectly synchronised VUs produce a
 * sawtooth request rate that aliases against Prometheus' 15 s scrape interval
 * and makes `rate()` look like it is oscillating when it is not.
 * Uniform jitter decorrelates the VUs.
 */
function think() {
  sleep(THINK_MIN + Math.random() * (THINK_MAX - THINK_MIN));
}

// =============================================================================
// SETUP — runs ONCE, before any VU starts.
// -----------------------------------------------------------------------------
// Its return value is passed as an argument to the default function and to
// teardown(). It must be JSON-serialisable (it crosses a process boundary).
// =============================================================================
export function setup() {
  console.log(`[setup] target BASE_URL = ${BASE_URL}`);
  console.log('[setup] probing /healthz before generating load ...');

  // A short timeout: if the app is up, /healthz answers in single-digit ms.
  // If it is not up, we want to know in 5 seconds, not after a 10 minute test
  // that produced 100% errors and a dashboard full of noise.
  const res = http.get(`${BASE_URL}/healthz`, {
    headers: headers(),
    timeout: '5s',
    tags: { name: 'healthz' },
  });

  if (res.status !== 200) {
    // exec.test.abort() stops the whole test immediately with exit code 108
    // and a single clear message. Far better than letting 10 VUs hammer a dead
    // endpoint for ten minutes and then reading 40,000 failures.
    exec.test.abort(
      [
        '',
        '  ABORT: orders-api is not reachable.',
        `    GET ${BASE_URL}/healthz -> status ${res.status} (${res.error || 'no transport error'})`,
        '',
        '  Likely causes and fixes:',
        '    1. The app is not deployed.      -> make deploy-app',
        '    2. Pods are not Ready yet.       -> kubectl get pods -n demo -w',
        '    3. Wrong BASE_URL for where you are running from:',
        '         inside the cluster : http://orders-api.demo.svc.cluster.local:8080',
        '         from the host      : http://localhost:8080 (run scripts/port-forward first)',
        '    4. Running as a Job in the wrong namespace — it must be `demo`.',
        '',
      ].join('\n')
    );
  }

  console.log(`[setup] healthz OK in ${res.timings.duration.toFixed(1)} ms — starting load`);

  // Returned object is handed to every VU iteration. Keep it small.
  return { startedAt: new Date().toISOString(), baseUrl: BASE_URL };
}

// =============================================================================
// DEFAULT FUNCTION — one iteration = one simulated user session.
// -----------------------------------------------------------------------------
// TRAFFIC MIX (roughly): 60% /api/orders, 30% /api/checkout, 10% /
// This is a weighted random draw per iteration, not a strict round-robin.
// Random draw is correct: it produces Poisson-ish arrivals per endpoint, which
// is what real traffic looks like, and it keeps the VUs decorrelated.
// =============================================================================
export default function (data) {
  const roll = Math.random();

  if (roll < 0.6) {
    // ------------------------------------------------------------------ 60%
    browseOrders();
  } else if (roll < 0.9) {
    // ------------------------------------------------------------------ 30%
    checkout();
  } else {
    // ------------------------------------------------------------------ 10%
    landingPage();
  }

  // Think time is OUTSIDE the group blocks on purpose: sleep() inside a group
  // inflates that group's reported duration and tells you nothing useful.
  think();
}

// -----------------------------------------------------------------------------
// 60% — GET /api/orders : the read path, the bulk of real traffic.
// -----------------------------------------------------------------------------
function browseOrders() {
  group('browse orders', function () {
    const res = http.get(`${BASE_URL}/api/orders`, {
      headers: headers(),
      // `name` tag collapses URLs into a single metric series. Critical if you
      // ever add path parameters (/api/orders/1234) — without it you get one
      // metric series per order id and k6's summary becomes unreadable. Same
      // low-cardinality discipline the contract applies to the `route` label.
      tags: { name: '/api/orders', route: '/api/orders' },
      timeout: '10s',
    });

    // check() returns a boolean (AND of all assertions) and increments the
    // `checks` metric. It never throws and never aborts the iteration.
    const ok = check(res, {
      'orders: status is 200': (r) => r.status === 200,
      'orders: body is non-empty': (r) => !!r.body && r.body.length > 0,
      'orders: content-type is JSON': (r) =>
        (r.headers['Content-Type'] || '').includes('application/json'),
      'orders: served under 300ms': (r) => r.timings.duration < 300,
    });

    // A 200 whose payload is wrong is a business error even though the
    // transport succeeded.
    businessErrors.add(!ok);
  });
}

// -----------------------------------------------------------------------------
// 30% — POST /api/checkout : the write path, the money path.
// -----------------------------------------------------------------------------
function checkout() {
  group('checkout', function () {
    // A plausible, varied payload. Varying the amount exercises the app's
    // `order_value_euros` histogram so that dashboard panel is not a single
    // spike at one value.
    const payload = JSON.stringify({
      customer_id: `cust-${Math.floor(Math.random() * 10000)}`,
      items: 1 + Math.floor(Math.random() * 4),
      amount_euros: Number((5 + Math.random() * 295).toFixed(2)),
      currency: 'EUR',
    });

    const res = http.post(`${BASE_URL}/api/checkout`, payload, {
      headers: headers({ 'Content-Type': 'application/json' }),
      tags: { name: '/api/checkout', route: '/api/checkout' },
      timeout: '10s',
    });

    // Feed the dedicated Trend. `r.timings.duration` is
    // (sending + waiting + receiving) — i.e. everything after the connection
    // is established. See the README for the full timings breakdown.
    checkoutLatency.add(res.timings.duration);

    const ok = check(res, {
      'checkout: status is 200 or 201': (r) => r.status === 200 || r.status === 201,
      'checkout: body mentions an order': (r) => !!r.body && r.body.includes('order'),
      'checkout: no 5xx': (r) => r.status < 500,
      'checkout: served under 300ms': (r) => r.timings.duration < 300,
    });

    if (ok) {
      // Mirrors orders_processed_total{status="success"} on the app side.
      ordersCreated.add(1);
    }
    businessErrors.add(!ok);
  });
}

// -----------------------------------------------------------------------------
// 10% — GET / : the landing page. Cheap, static, and a useful control: if `/`
// is slow too, the problem is the process or the node, not the order logic.
// -----------------------------------------------------------------------------
function landingPage() {
  group('landing', function () {
    const res = http.get(`${BASE_URL}/`, {
      headers: headers({ Accept: 'text/html,application/json' }),
      tags: { name: '/', route: '/' },
      timeout: '10s',
    });

    const ok = check(res, {
      'landing: status is 200': (r) => r.status === 200,
      'landing: body is non-empty': (r) => !!r.body && r.body.length > 0,
      'landing: served under 300ms': (r) => r.timings.duration < 300,
    });

    businessErrors.add(!ok);
  });
}

// =============================================================================
// TEARDOWN — runs ONCE after all VUs have stopped.
// =============================================================================
export function teardown(data) {
  console.log(`[teardown] steady run started at ${data.startedAt}, finished at ${new Date().toISOString()}`);
  console.log('[teardown] steady.js changes no server state — nothing to clean up.');
  console.log('[teardown] Now look at Grafana: http://localhost:3000/d/obs-app-red');
}

// =============================================================================
// handleSummary — called once with the full end-of-test statistics object.
// -----------------------------------------------------------------------------
// Returning an object maps destinations -> content. The special key `stdout`
// writes to the terminal; any other key is treated as a file path. We emit a
// compact, human-readable block instead of k6's default wall of text, plus the
// raw JSON to disk for later diffing between runs.
// =============================================================================
export function handleSummary(data) {
  // Defensive accessors: a metric is absent from `data.metrics` if it never
  // received a sample (e.g. the test aborted in setup()).
  const m = (name, stat, fallback) => {
    const metric = data.metrics[name];
    if (!metric || metric.values[stat] === undefined) return fallback;
    return metric.values[stat];
  };
  const n = (v, digits = 2) => (typeof v === 'number' ? v.toFixed(digits) : String(v));
  const pct = (v) => `${(v * 100).toFixed(3)}%`;

  const reqs = m('http_reqs', 'count', 0);
  const rps = m('http_reqs', 'rate', 0);
  const failRate = m('http_req_failed', 'rate', 0);
  const checkRate = m('checks', 'rate', 0);
  const p99 = m('http_req_duration', 'p(99)', 0);
  const p95 = m('http_req_duration', 'p(95)', 0);
  const med = m('http_req_duration', 'med', 0);
  const waitP99 = m('http_req_waiting', 'p(99)', 0);
  const iterDur = m('iteration_duration', 'med', 0);
  const orders = m('orders_created_total', 'count', 0);
  const bizErr = m('business_errors', 'rate', 0);
  const coP99 = m('checkout_latency_ms', 'p(99)', 0);

  // Did we hold the contract? Re-derive it here so the summary states the
  // verdict in SLO language, not k6 language.
  const availOk = failRate < 0.001;
  const latencyOk = p99 < 300;
  const verdict = availOk && latencyOk ? 'PASS' : 'FAIL';

  const lines = [
    '',
    '================================================================',
    '  k6 steady.js — orders-api baseline load summary',
    '================================================================',
    `  target              : ${BASE_URL}`,
    `  plateau             : ${VUS} VUs for ${HOLD}`,
    '  ---------------------------------------------------------------',
    `  requests            : ${reqs} total  (${n(rps)} req/s)`,
    `  orders created      : ${orders}`,
    '  ---------------------------------------------------------------',
    `  http_req_duration   : med ${n(med)} ms | p95 ${n(p95)} ms | p99 ${n(p99)} ms`,
    `  http_req_waiting    : p99 ${n(waitP99)} ms   (server time, excludes connect)`,
    `  checkout p99        : ${n(coP99)} ms`,
    `  iteration_duration  : med ${n(iterDur)} ms  (INCLUDES sleep think-time)`,
    '  ---------------------------------------------------------------',
    `  http_req_failed     : ${pct(failRate)}   (SLO budget 0.100%)`,
    `  business_errors     : ${pct(bizErr)}`,
    `  checks passed       : ${pct(checkRate)}`,
    '  ---------------------------------------------------------------',
    `  SLO availability    : ${availOk ? 'HELD' : 'BREACHED'}  (target 99.9%, non-5xx)`,
    `  SLO latency         : ${latencyOk ? 'HELD' : 'BREACHED'}  (target p99 < 300 ms)`,
    `  VERDICT             : ${verdict}`,
    '================================================================',
    '  Next: Grafana -> http://localhost:3000/d/obs-app-red',
    '        Budget  -> http://localhost:3000/d/obs-slo-budget',
    '================================================================',
    '',
  ];

  return {
    stdout: lines.join('\n'),
    // Machine-readable artefact. In CI, archive this and diff p99 between the
    // base branch and the PR branch — that is how you catch a 40 ms regression
    // that no single threshold would have failed.
    'k6-steady-summary.json': JSON.stringify(data, null, 2),
  };
}

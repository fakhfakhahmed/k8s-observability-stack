// =============================================================================
// load/k6/spike.js — saturation / spike test for orders-api
// -----------------------------------------------------------------------------
// Part of: k8s-observability-stack
// Author:  Ahmed Fakhfakh — DevOps / SRE
//
// WHAT THIS IS
// ------------
// `steady.js` asks "does the service meet its SLO under normal load?".
// This script asks a completely different question:
//
//     "WHERE does the service break, HOW does it break, and does the
//      observability stack show me the break clearly enough to act on it?"
//
// Those are capacity and observability questions, not correctness questions.
// A spike test that passes every threshold has told you almost nothing — it
// means you did not push hard enough to find the knee in the curve.
//
// THE CENTRAL POINT: YOU EXPECT TO BREACH
// ---------------------------------------
// During a spike you *expect* the latency threshold to go red, and possibly the
// error threshold too. That is the experiment working, not the experiment
// failing. Hence every threshold below sets `abortOnFail: false`:
//
//     - abortOnFail: true  -> k6 kills the test the instant the threshold is
//                             crossed. Useless here: the interesting 90 seconds
//                             of saturation behaviour happen AFTER the first
//                             breach, and you would never see them.
//     - abortOnFail: false -> k6 records the breach, marks the run failed at
//                             the end, and keeps generating load so you can
//                             watch the system saturate, queue, shed, scale,
//                             and recover.
//
// k6 still exits non-zero at the end. Read that exit code as "the system was
// pushed past its limit", which is the whole point, and NOT as "the build is
// broken". Do not wire this script into a blocking CI gate — wire `steady.js`
// into the gate and run this one on a schedule or on demand.
//
// WHAT SATURATION ACTUALLY LOOKS LIKE (the USE method: Utilisation, Saturation,
// Errors). Utilisation saturates first and silently; saturation is the queue
// that forms once utilisation hits 100%; errors are what happens when the queue
// overflows. The app exposes exactly the two gauges that make this visible:
//
//     http_requests_in_flight   — concurrency currently being served.
//                                 Flat-topping = you have hit a hard
//                                 concurrency limit (worker pool, connection
//                                 pool, kube-proxy conntrack, GOMAXPROCS).
//     queue_depth               — work accepted but not yet done.
//                                 Monotonically rising = arrival rate exceeds
//                                 service rate. This is Little's Law being
//                                 violated in public: L = λW, so if λ outruns
//                                 1/W the queue grows without bound and
//                                 latency grows linearly with it.
//
// The signature of a healthy system under spike: in-flight rises, plateaus at a
// ceiling, latency rises proportionally, error rate stays near zero, queue
// drains after the spike. The signature of an unhealthy one: queue_depth never
// comes back down, or 5xx appears before the concurrency ceiling is reached
// (meaning something crashed rather than queued).
// =============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import exec from 'k6/execution';

// Same BASE_URL contract as every other script in this directory.
const BASE_URL = __ENV.BASE_URL || 'http://orders-api.demo.svc.cluster.local:8080';

// Spike shape is tunable so you can walk the load up across successive runs
// until you find the knee: 120 -> 200 -> 320 VUs, etc.
const PEAK_VUS = Number(__ENV.VUS || 120);      // spike plateau
const BASE_VUS = Number(__ENV.BASE_VUS || 5);   // the quiet background level
const PEAK_HOLD = __ENV.DURATION || '2m';       // how long we hold the peak

// =============================================================================
// CUSTOM METRICS
// =============================================================================

// Latency specifically during the peak phase. The global `http_req_duration`
// mixes the calm shoulders with the peak and therefore understates the damage;
// this Trend only receives samples while we are at or near peak VUs.
const peakLatency = new Trend('peak_latency_ms', true);

// Requests the server actively refused or dropped: 429/503, or a transport
// error. These are *load shedding*, which is a healthy failure mode and
// categorically different from a 500 (which is a crash).
const sheddedRequests = new Counter('shedded_requests_total');

// Rate of hard server errors (5xx excluding 503). This is the one that must
// stay near zero even under spike: shedding is fine, crashing is not.
const hardErrors = new Rate('hard_errors');

// How many VUs k6 believes are active, sampled per iteration. Correlate this
// against `http_requests_in_flight` from the app: a growing gap between
// "clients waiting" and "requests being served" is queueing.
const activeVus = new Gauge('observed_active_vus');

export const options = {
  // ---------------------------------------------------------------------------
  // STAGES — the spike profile.
  //   5 VUs (warm)  -> 120 VUs in 30 s  -> hold 2m -> back to 5 VUs -> hold 2m
  // Total: ~5m 10s.
  //
  // The 30-second ramp is deliberately violent. A gentle ramp lets the HPA,
  // the connection pool and the Go runtime adapt gracefully, which is exactly
  // what you do NOT want to test. Real spikes are a marketing email, a cache
  // stampede after a deploy, or a retry storm — all of them near-instant.
  //
  // The two-minute RECOVERY hold at the end is the most under-rated part of a
  // spike test. Plenty of systems survive the spike and then fail to recover:
  // the queue never drains, a connection pool stays exhausted, a circuit
  // breaker stays open, or the HPA scaled up and then thrashes. If you stop
  // the test at peak you will never see that.
  // ---------------------------------------------------------------------------
  stages: [
    { duration: '15s', target: BASE_VUS },  // warm-up: fill pools, JIT nothing
                                            // (it's Go), establish keep-alives
    { duration: '30s', target: PEAK_VUS },  // THE SPIKE: 5 -> 120 VUs, 24x in 30s
    { duration: PEAK_HOLD, target: PEAK_VUS }, // hold the peak — measure here
    { duration: '15s', target: BASE_VUS },  // sharp drop back to background
    { duration: '2m', target: BASE_VUS },   // RECOVERY window — does it drain?
  ],

  // ---------------------------------------------------------------------------
  // THRESHOLDS — all with abortOnFail: false.
  // ---------------------------------------------------------------------------
  // These are intentionally looser than the SLO thresholds in steady.js,
  // because the SLO describes normal operation and this is abnormal operation.
  // They are tripwires for "degraded in a way we did not predict", not a
  // contract. Reading them:
  //
  //   p(99) < 2000      We accept 6.6x the SLO latency during a spike. If we
  //                     cannot even hold 2 s, the system is not degrading, it
  //                     is collapsing.
  //   rate < 0.05       Up to 5% failures tolerated at peak. Above that the
  //                     spike is causing real user-visible loss rather than
  //                     queueing.
  //   hard_errors       < 1%. Shedding (503/429) is acceptable; crashing is not.
  //                     This is the threshold that actually matters.
  //   checks            > 0.90. Looser than steady's 0.99 for the same reason.
  // ---------------------------------------------------------------------------
  thresholds: {
    http_req_duration: [
      { threshold: 'p(99)<2000', abortOnFail: false },
      { threshold: 'p(95)<1000', abortOnFail: false },
    ],
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: false }],
    hard_errors: [{ threshold: 'rate<0.01', abortOnFail: false }],
    checks: [{ threshold: 'rate>0.90', abortOnFail: false }],
    peak_latency_ms: [{ threshold: 'p(99)<3000', abortOnFail: false }],
  },

  tags: {
    scenario: 'spike',
    testid: __ENV.TESTID || 'spike-local',
  },

  // Keep-alive on: a spike against a Service goes through kube-proxy/iptables,
  // and forcing a new TCP connection per request would measure conntrack table
  // behaviour rather than application behaviour. (Worth testing separately —
  // conntrack exhaustion is a real production failure mode — but not here.)
  noConnectionReuse: false,

  // Do not let k6 itself become the bottleneck by queuing VUs waiting for
  // sockets. 120 VUs on a laptop is fine; above ~500 you will need to raise
  // the Job's CPU limit and check `ulimit -n` in the container.
  discardResponseBodies: false, // we assert on bodies, so keep them

  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// Treat only 2xx/3xx as expected; 4xx/5xx increment http_req_failed.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }));

// =============================================================================
// =============================================================================
//
//   WHAT TO WATCH WHILE THIS RUNS
//   -----------------------------
//   Open BOTH dashboards before you start the Job. A spike test you did not
//   watch is a spike test you did not run.
//
//   Dashboard `obs-app-red` — "Orders API — RED Metrics"
//   http://localhost:3000/d/obs-app-red
//
//   | Panel                          | Backing series                              | What you are looking for                                                                 |
//   |--------------------------------|---------------------------------------------|------------------------------------------------------------------------------------------|
//   | Request Rate (RED: Rate)       | route:http_requests:rate5m                  | Does throughput keep climbing with VUs, or flat-top? The flat-top IS your capacity number. |
//   | Error Rate (RED: Errors)       | route:http_requests_errors:rate5m           | Errors should stay flat while latency rises. Errors rising FIRST means a crash, not a queue.|
//   | Latency p50 / p90 / p99 (RED)  | route:http_request_duration_seconds:p50/p90/p99 | Watch p99 detach from p50. Widening spread = queueing. Both rising together = genuinely slower work. |
//   | In-flight Requests             | http_requests_in_flight                     | THE saturation signal. A hard ceiling here is your concurrency limit.                       |
//   | Queue Depth                    | queue_depth                                 | Must come back to baseline in the recovery window. If it does not, you have found a bug.    |
//   | Orders Processed by status     | orders_processed_total{status}               | Watch `rejected` and `failed` appear. Graceful shedding shows up here first.                |
//   | Pod CPU / Memory               | container_cpu_usage_seconds_total, container_memory_working_set_bytes | CPU pinned at the limit means you are CPU-throttled, not slow. Check throttling. |
//   | Replica count / HPA            | kube_deployment_status_replicas              | Did the HPA react at all? What was the lag between saturation and the new pod being Ready?  |
//
//   Dashboard `obs-slo-budget` — "Orders API — SLO & Error Budget"
//   http://localhost:3000/d/obs-slo-budget
//     - `job:slo_latency_errors:ratio_rate5m` should visibly spike. This is the
//       latency SLI reacting in near-real-time.
//     - The fast burn-rate rung (14.4x, 1h/5m) may arm. If the spike is short
//       enough, the 5 m short window will clear it before the 1 h long window
//       crosses — which is precisely why the ladder uses two windows: it is
//       designed NOT to page for a two-minute blip.
//
//   Also worth having open:
//     - Alertmanager  http://localhost:9093  — see whether anything fired.
//     - `kubectl get hpa -n demo -w`
//     - `kubectl top pods -n demo`
//     - Loki, dashboard `obs-logs-explorer`: {namespace="demo", level="ERROR"}
//
//   THE QUESTIONS THIS TEST ANSWERS
//     1. What is the maximum sustainable request rate? (the throughput plateau)
//     2. At what concurrency does p99 exceed the 300 ms SLO?
//     3. Does the service shed load (503) or fall over (500)?
//     4. Does the HPA scale, and is it fast enough to matter?
//     5. Does queue_depth return to zero after the spike?
//     6. Did the alerts that *should* fire fire, and did the ones that should
//        stay quiet stay quiet? A spike test is also an alert-tuning test.
//
// =============================================================================
// =============================================================================

function headers() {
  return {
    'User-Agent': 'k6-spike/1.0',
    'X-Request-Id': `k6s-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`,
    Accept: 'application/json',
  };
}

export function setup() {
  console.log(`[setup] spike target BASE_URL = ${BASE_URL}`);
  const res = http.get(`${BASE_URL}/healthz`, {
    headers: headers(),
    timeout: '5s',
    tags: { name: 'healthz' },
  });

  if (res.status !== 200) {
    exec.test.abort(
      [
        '',
        '  ABORT: orders-api is not reachable — refusing to start a spike test.',
        `    GET ${BASE_URL}/healthz -> status ${res.status} (${res.error || 'no transport error'})`,
        '    In-cluster URL: http://orders-api.demo.svc.cluster.local:8080',
        '    From the host : http://localhost:8080 (run scripts/port-forward first)',
        '',
      ].join('\n')
    );
  }

  console.log('');
  console.log('  SPIKE PROFILE');
  console.log(`    warm  15s @ ${BASE_VUS} VUs`);
  console.log(`    SPIKE 30s ramp ${BASE_VUS} -> ${PEAK_VUS} VUs`);
  console.log(`    hold  ${PEAK_HOLD} @ ${PEAK_VUS} VUs      <-- measure here`);
  console.log(`    drop  15s -> ${BASE_VUS} VUs`);
  console.log(`    recovery 2m @ ${BASE_VUS} VUs  <-- does queue_depth drain?`);
  console.log('');
  console.log('  Open now: http://localhost:3000/d/obs-app-red');
  console.log('            http://localhost:3000/d/obs-slo-budget');
  console.log('  Threshold breaches below are EXPECTED. Read the dashboards, not the exit code.');
  console.log('');

  return { peakVus: PEAK_VUS, startedAt: new Date().toISOString() };
}

export default function (data) {
  // Record where we are in the ramp so `peak_latency_ms` only collects samples
  // from the saturated phase. `exec.instance.vusActive` is k6's live VU count.
  const vus = exec.instance.vusActive;
  activeVus.add(vus);
  const atPeak = vus >= data.peakVus * 0.9;

  // Same 60/30/10 traffic mix as steady.js. Keeping the mix identical between
  // the control and the experiment is the entire reason the comparison is
  // meaningful — change one variable (concurrency), not two.
  const roll = Math.random();
  if (roll < 0.6) {
    hit('/api/orders', 'GET', null, atPeak);
  } else if (roll < 0.9) {
    hit(
      '/api/checkout',
      'POST',
      JSON.stringify({
        customer_id: `cust-${Math.floor(Math.random() * 10000)}`,
        items: 1 + Math.floor(Math.random() * 4),
        amount_euros: Number((5 + Math.random() * 295).toFixed(2)),
        currency: 'EUR',
      }),
      atPeak
    );
  } else {
    hit('/', 'GET', null, atPeak);
  }

  // MUCH shorter think time than steady.js — a spike is defined by arrival
  // rate, and think time is the inverse of arrival rate. 50-200 ms of jitter
  // keeps the VUs decorrelated without throttling the spike.
  sleep(0.05 + Math.random() * 0.15);
}

/**
 * One request, fully instrumented. Kept generic so the traffic mix above reads
 * as a mix and not as three near-identical blocks.
 */
function hit(route, method, body, atPeak) {
  group(`spike ${route}`, function () {
    const params = {
      headers: Object.assign(headers(), body ? { 'Content-Type': 'application/json' } : {}),
      tags: { name: route, route: route, phase: atPeak ? 'peak' : 'shoulder' },
      // Generous timeout: under saturation we WANT to see a 4-second response
      // recorded as a slow success rather than discarded as a client timeout.
      // A client timeout destroys the latency distribution's tail, which is the
      // only part of the distribution a spike test is about.
      timeout: '30s',
    };

    const res = method === 'POST' ? http.post(`${BASE_URL}${route}`, body, params) : http.get(`${BASE_URL}${route}`, params);

    if (atPeak) {
      peakLatency.add(res.timings.duration);
    }

    // Load shedding — a deliberate, well-behaved refusal. Count it, do not
    // treat it as a crash.
    const shed = res.status === 429 || res.status === 503 || res.status === 0;
    if (shed) {
      sheddedRequests.add(1, { route: route, status: String(res.status) });
    }

    // A hard error is a 5xx that is NOT 503. 500/502/504 mean something broke
    // or a dependency timed out; 503 means "I am full, come back later".
    hardErrors.add(res.status >= 500 && res.status !== 503);

    check(res, {
      'spike: not a hard 5xx': (r) => !(r.status >= 500 && r.status !== 503),
      'spike: responded at all': (r) => r.status !== 0,
      'spike: body present on 2xx': (r) => r.status < 300 ? !!r.body : true,
    });
  });
}

export function teardown(data) {
  console.log('');
  console.log(`[teardown] spike started ${data.startedAt}, ended ${new Date().toISOString()}`);
  console.log('[teardown] spike.js enables NO chaos and mutates no server state.');
  console.log('[teardown] Checklist before you close the dashboards:');
  console.log('    1. Did http_requests_in_flight flat-top? At what value?');
  console.log('    2. Did queue_depth return to its pre-spike baseline?');
  console.log('    3. Did p99 recover, or is it still elevated?');
  console.log('    4. Did the HPA scale, and how long did the new pod take to be Ready?');
  console.log('    5. Did any alert fire? Was that correct?');
  console.log('');
}

export function handleSummary(data) {
  const m = (name, stat, fallback) => {
    const metric = data.metrics[name];
    if (!metric || metric.values[stat] === undefined) return fallback;
    return metric.values[stat];
  };
  const n = (v, d = 2) => (typeof v === 'number' ? v.toFixed(d) : String(v));
  const pct = (v) => `${(v * 100).toFixed(3)}%`;

  const lines = [
    '',
    '================================================================',
    '  k6 spike.js — orders-api saturation summary',
    '================================================================',
    `  target            : ${BASE_URL}`,
    `  spike             : ${BASE_VUS} -> ${PEAK_VUS} VUs in 30s, held ${PEAK_HOLD}`,
    '  ---------------------------------------------------------------',
    `  requests          : ${m('http_reqs', 'count', 0)} (${n(m('http_reqs', 'rate', 0))} req/s avg)`,
    `  overall p99       : ${n(m('http_req_duration', 'p(99)', 0))} ms`,
    `  AT-PEAK p99       : ${n(m('peak_latency_ms', 'p(99)', 0))} ms   <-- the number that matters`,
    `  AT-PEAK median    : ${n(m('peak_latency_ms', 'med', 0))} ms`,
    `  at-peak max       : ${n(m('peak_latency_ms', 'max', 0))} ms`,
    '  ---------------------------------------------------------------',
    `  http_req_failed   : ${pct(m('http_req_failed', 'rate', 0))}`,
    `  shed (429/503/0)  : ${m('shedded_requests_total', 'count', 0)}  (graceful — good)`,
    `  hard errors (5xx) : ${pct(m('hard_errors', 'rate', 0))}  (must stay < 1%)`,
    `  checks passed     : ${pct(m('checks', 'rate', 0))}`,
    '  ---------------------------------------------------------------',
    '  REMINDER: a FAILED threshold here is an expected result, not a bug.',
    '  The deliverable of a spike test is the dashboard, not the exit code.',
    '    http://localhost:3000/d/obs-app-red',
    '    http://localhost:3000/d/obs-slo-budget',
    '================================================================',
    '',
  ];

  return {
    stdout: lines.join('\n'),
    'k6-spike-summary.json': JSON.stringify(data, null, 2),
  };
}

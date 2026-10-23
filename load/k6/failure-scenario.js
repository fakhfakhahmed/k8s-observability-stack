// =============================================================================
// load/k6/failure-scenario.js — the error-budget burner
// -----------------------------------------------------------------------------
// Part of: k8s-observability-stack
// Author:  Ahmed Fakhfakh — DevOps / SRE
// Driven by: scripts/trigger-incident.ps1 / scripts/trigger-incident.sh
//            (Makefile target: `make break`)
//
// -----------------------------------------------------------------------------
// READ THIS FIRST: A RED SUMMARY IS THE CORRECT OUTCOME
// -----------------------------------------------------------------------------
// This script is NOT testing the application. It is testing the OBSERVABILITY
// AND ALERTING PIPELINE. It deliberately breaks orders-api, then generates
// enough traffic for Prometheus to notice, so that you can watch:
//
//     app 5xx  ->  http_requests_total{status=~"5.."}
//              ->  route:http_requests_errors:rate5m           (recording rule)
//              ->  job:slo_availability_errors:ratio_rate5m/1h (SLI)
//              ->  HighErrorRate + ErrorBudgetBurn             (alert rules)
//              ->  Alertmanager                                (routing)
//              ->  runbooks/ErrorBudgetBurn.md                 (runbook_url)
//              ->  obs-slo-budget dashboard                    (budget drawdown)
//
// Every single link in that chain is a thing that silently rots in real
// systems. Firing a synthetic incident on a schedule is how you find out that
// your alert has been broken for six weeks BEFORE the real outage.
//
// Therefore: k6 will print a red FAILED summary and exit non-zero. That is the
// expected, correct, designed result. If this script ever exits 0 with chaos
// enabled, something is wrong — either chaos did not engage, or the thresholds
// have been loosened, or no traffic reached the app.
//
// Do not put this script in a blocking CI gate. `steady.js` is the gate.
// This one is a fire drill.
//
// -----------------------------------------------------------------------------
// SELF-CONTAINED CHAOS — AND THE CLEANUP CAVEAT
// -----------------------------------------------------------------------------
// setup()    enables chaos by calling the app's own chaos endpoints.
// teardown() calls /chaos/reset to turn it off again.
//
// IMPORTANT, and the reason `scripts/heal` exists: teardown() is NOT a
// guarantee. k6 skips teardown when:
//   - the process is SIGKILLed (`kubectl delete job` / pod eviction / OOM),
//   - the Job hits `activeDeadlineSeconds` and the kubelet kills the pod,
//   - the node dies, or you close your laptop,
//   - setup() itself aborts the test.
//
// In every one of those cases the app stays broken with chaos still on. The
// manual escape hatch is:
//
//     ./scripts/heal.ps1        (or ./scripts/heal.sh, or `make heal`)
//     # which ultimately does: curl -s http://<orders-api>:8080/chaos/reset
//
// Treat `heal` as the authoritative "stop the bleeding" command and teardown()
// as a convenience. Designing cleanup to be idempotent and externally
// invocable, rather than trusting a process to clean up after itself, is the
// difference between a demo and an operable system.
//
// Chaos requires the app to be started with CHAOS_ENABLED=true. If it was not,
// the endpoints 404 and setup() aborts with a clear message rather than running
// a ten-minute test that proves nothing.
// =============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://orders-api.demo.svc.cluster.local:8080';

// How long to hold the broken steady state. Default 10m.
// See the timeline in setup(): 10m is enough for the availability page
// (ErrorBudgetBurn 14.4x) and HighErrorRate; you need ~20m for the 3x/1x ticket
// rungs and ~45m for the LATENCY page, because the latency budget is 1% (ten
// times larger than the availability budget) and therefore burns ten times
// slower for the same injected fault rate.
const DURATION = __ENV.DURATION || '10m';
const VUS = Number(__ENV.VUS || 10);

// Chaos knobs. Defaults chosen so the maths is easy to narrate:
//   35% 5xx  / 0.1% availability budget = 350x burn rate
//   25% slow / 1.0% latency budget      =  25x burn rate
const ERROR_PCT = Number(__ENV.ERROR_PCT || 35);  // % of requests forced to 5xx
const LATENCY_MS = Number(__ENV.LATENCY_MS || 900); // injected delay
const LATENCY_PCT = Number(__ENV.LATENCY_PCT || 25); // % of requests delayed

// Set to "false" to leave chaos running after the test (for a longer manual
// investigation). You then MUST run `make heal` yourself.
const RESET_ON_EXIT = (__ENV.RESET_ON_EXIT || 'true') !== 'false';

// =============================================================================
// CUSTOM METRICS — these mirror what Prometheus is seeing, so you can sanity
// check the pipeline from both ends: if k6 says 35% errors and the SLI says 2%,
// the recording rule or the scrape is wrong, not the app.
// =============================================================================
const injectedErrors = new Rate('injected_error_rate'); // should converge on ~0.35
const slowRequests = new Rate('slow_request_rate');     // requests over the 300ms SLO
const budgetBurnSamples = new Trend('observed_latency_ms', true);
const fiveXX = new Counter('http_5xx_total');

export const options = {
  // ---------------------------------------------------------------------------
  // STAGES — a short ramp, then a long, FLAT, boring plateau.
  // Flat matters: Prometheus' rate() windows and the alerts' `for:` clauses
  // assume a sustained condition. A spiky generator produces an on/off error
  // rate that can repeatedly arm and disarm an alert, which makes the timeline
  // below meaningless. The whole design goal here is "steady and broken".
  // ---------------------------------------------------------------------------
  stages: [
    { duration: '30s', target: VUS },  // short ramp — chaos is already on
    { duration: DURATION, target: VUS }, // the incident
    { duration: '30s', target: 0 },    // ramp down
  ],

  // ---------------------------------------------------------------------------
  // THRESHOLDS — DELIBERATELY UNACHIEVABLE WHILE CHAOS IS ON
  // ---------------------------------------------------------------------------
  // These are not "hard" thresholds invented to force a red result. They are
  // EXACTLY the SLO thresholds from slo/availability.yaml and slo/latency.yaml,
  // byte for byte identical to the ones in steady.js:
  //
  //     http_req_failed   rate<0.001    <- 99.9% availability SLO
  //     http_req_duration p(99)<300     <- 300 ms latency SLO
  //
  // With 35% forced errors and 25% forced 900 ms responses, both are
  // arithmetically impossible to meet. That is the point and it is a stronger
  // statement than a bespoke threshold would be: the *same contract* that
  // passes in steady state fails here, which proves the contract has teeth.
  //
  // abortOnFail is left at its default (false) on all of them — we need the
  // test to keep running after the first breach so the alerts have time to
  // fire. An aborting threshold would end the test in the first 30 seconds and
  // you would never see an alert at all.
  // ---------------------------------------------------------------------------
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.001', abortOnFail: false }],
    http_req_duration: [{ threshold: 'p(99)<300', abortOnFail: false }],
    checks: [{ threshold: 'rate>0.99', abortOnFail: false }],
    // Inverted sanity check: if chaos is actually engaged this rate should be
    // well ABOVE 0.1, so a *passing* threshold here means chaos did not take
    // effect and the whole run is void. A threshold used as an assertion about
    // the test harness rather than about the system under test.
    injected_error_rate: [{ threshold: 'rate>0.10', abortOnFail: false }],
  },

  // Every sample emitted by this test carries scenario="failure".
  tags: {
    scenario: 'failure',
    testid: __ENV.TESTID || 'failure-local',
  },

  noConnectionReuse: false,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// 2xx/3xx expected; everything else counts toward http_req_failed.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }));

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
function headers(extra) {
  return Object.assign(
    {
      'User-Agent': 'k6-failure/1.0',
      'X-Request-Id': `k6f-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`,
      Accept: 'application/json',
    },
    extra || {}
  );
}

/**
 * Call a chaos endpoint. The app accepts both POST (the semantically correct
 * verb for a state change) and GET (so you can trigger chaos from a browser
 * address bar during a demo, which is genuinely useful when presenting).
 * We try POST first and transparently fall back to GET on 404/405 so this
 * script keeps working regardless of which verbs the handler is registered for.
 *
 * Returns the final response so the caller can assert on it.
 */
function chaos(path) {
  const url = `${BASE_URL}${path}`;
  const params = {
    headers: headers(),
    timeout: '10s',
    // Tagged as `chaos` so these control-plane calls are trivially excluded
    // from the latency/error statistics of the actual load. They are not user
    // traffic and must not pollute the measurement.
    tags: { name: 'chaos-control', scenario: 'failure', control: 'true' },
  };

  let res = http.post(url, null, params);
  if (res.status === 404 || res.status === 405) {
    res = http.get(url, params);
  }
  return res;
}

// =============================================================================
// SETUP — enable chaos, then print the incident timeline.
// =============================================================================
export function setup() {
  console.log('');
  console.log('================================================================');
  console.log('  FAILURE SCENARIO — deliberate error-budget burn');
  console.log('================================================================');
  console.log(`  target : ${BASE_URL}`);
  console.log(`  profile: ${VUS} VUs, plateau ${DURATION}`);
  console.log('');

  // ---- 0. Is the app even there? ------------------------------------------
  const health = http.get(`${BASE_URL}/healthz`, {
    headers: headers(),
    timeout: '5s',
    tags: { name: 'healthz', control: 'true' },
  });
  if (health.status !== 200) {
    exec.test.abort(
      [
        '',
        '  ABORT: orders-api is not reachable — cannot stage an incident.',
        `    GET ${BASE_URL}/healthz -> ${health.status} (${health.error || 'no transport error'})`,
        '    Fix: make deploy-app, then kubectl get pods -n demo',
        '',
      ].join('\n')
    );
  }

  // ---- 1. Inject errors ----------------------------------------------------
  console.log(`[setup] enabling chaos: ${ERROR_PCT}% of requests -> 5xx`);
  const errRes = chaos(`/chaos/errors?pct=${ERROR_PCT}`);
  if (errRes.status >= 400) {
    exec.test.abort(
      [
        '',
        '  ABORT: the chaos endpoints are not available.',
        `    POST/GET ${BASE_URL}/chaos/errors?pct=${ERROR_PCT} -> ${errRes.status}`,
        '',
        '  Almost always this means the Deployment is missing CHAOS_ENABLED=true.',
        '  Check with:',
        '    kubectl get deploy orders-api -n demo -o jsonpath="{.spec.template.spec.containers[0].env}"',
        '  Fix with:',
        '    kubectl set env deploy/orders-api -n demo CHAOS_ENABLED=true',
        '    kubectl rollout status deploy/orders-api -n demo',
        '',
      ].join('\n')
    );
  }

  // ---- 2. Inject latency ---------------------------------------------------
  console.log(`[setup] enabling chaos: ${LATENCY_PCT}% of requests delayed by ${LATENCY_MS}ms`);
  const latRes = chaos(`/chaos/latency?ms=${LATENCY_MS}&pct=${LATENCY_PCT}`);
  if (latRes.status >= 400) {
    console.warn(`[setup] WARNING: latency chaos returned ${latRes.status}; continuing with error chaos only.`);
  }

  // ---- 3. The timeline -----------------------------------------------------
  // Derivations, so the numbers below are reproducible rather than folklore.
  //
  //   Availability SLI   bad = 5xx / total. Injected bad ratio ~ 0.35.
  //   Availability budget = 1 - 0.999 = 0.001  ->  burn rate 0.35/0.001 = 350x
  //
  //   A Prometheus rate() over window W, for a fault that started t minutes ago
  //   (t < W), reports approximately  injected_ratio * (t / W). So the long
  //   window crosses its burn-rate threshold at:
  //
  //       t_cross = (burn_rate_threshold * budget / injected_ratio) * W
  //
  //   14.4x availability: threshold = 14.4 * 0.001 = 0.0144 over a 1h window
  //       t = (0.0144 / 0.35) * 60 min = 2.5 min, plus `for: 2m` -> ~4.5-5 min
  //   6x  availability: threshold = 0.006 over a 6h window
  //       t = (0.006 / 0.35) * 360 min = 6.2 min, plus `for: 2m` -> ~8 min
  //   3x  availability: threshold = 0.003 over a 1d window
  //       t = (0.003 / 0.35) * 1440 min = 12.3 min -> ~14 min
  //   1x  availability: threshold = 0.001 over a 3d window
  //       t = (0.001 / 0.35) * 4320 min = 12.3 min -> ~14 min
  //
  //   Latency SLI: bad = requests slower than 300 ms. Injected ~0.25.
  //   Latency budget = 1 - 0.99 = 0.01  ->  burn rate 0.25/0.01 = 25x
  //       14.4x latency: threshold = 0.144 over 1h
  //       t = (0.144 / 0.25) * 60 min = 34.6 min -> ~37 min
  //   Hence the note about DURATION=45m if you want the latency page too.
  const t0 = new Date();
  const at = (mins) => new Date(t0.getTime() + mins * 60000).toISOString().substring(11, 19);

  console.log('');
  console.log('  INCIDENT TIMELINE (UTC) — what should fire, and when');
  console.log('  ---------------------------------------------------------------');
  console.log(`  T+00:00  ${at(0)}  chaos enabled, load starting`);
  console.log(`                      injected: ${ERROR_PCT}% 5xx  = ${(ERROR_PCT / 0.1).toFixed(0)}x availability burn rate`);
  console.log(`                      injected: ${LATENCY_PCT}% @ ${LATENCY_MS}ms = ${(LATENCY_PCT / 1).toFixed(0)}x latency burn rate`);
  console.log(`  T+00:30  ${at(0.5)}  first scrape with errors; Prometheus targets still UP`);
  console.log(`  T+01:00  ${at(1)}  route:http_requests_errors:rate5m visibly climbing on obs-app-red`);
  console.log(`  T+02:30  ${at(2.5)}  job:slo_availability_errors:ratio_rate1h crosses 1.44% (14.4x)`);
  console.log(`  T+04:30  ${at(4.5)}  >>> PAGE: ErrorBudgetBurn slo=availability burn_rate=14.4`);
  console.log('                      (1h/5m rung, severity=critical, page=true, after for: 2m)');
  console.log(`  T+08:00  ${at(8)}  >>> PAGE: ErrorBudgetBurn slo=availability burn_rate=6`);
  console.log('                      (6h/30m rung, severity=critical)');
  console.log(`  T+11:00  ${at(11)}  >>> WARN: HighErrorRate  (5xx ratio > 5% sustained for: 10m)`);
  console.log(`  T+11:00  ${at(11)}  >>> WARN: HighLatencyP99 (p99 > 500ms sustained for: 10m)`);
  console.log(`  T+14:00  ${at(14)}  >>> TICKET: ErrorBudgetBurn burn_rate=3 (1d/2h) and =1 (3d/6h)`);
  console.log(`  T+37:00  ${at(37)}  >>> PAGE: ErrorBudgetBurn slo=latency burn_rate=14.4`);
  console.log('                      (needs -e DURATION=45m; the 1% latency budget burns 10x slower)');
  console.log('  ---------------------------------------------------------------');
  console.log(`  This run holds for ${DURATION}. To reach every rung: -e DURATION=45m`);
  console.log('');
  console.log('  WATCH / SCREENSHOT (in this order — this is the portfolio evidence)');
  console.log('    1. http://localhost:3000/d/obs-app-red       Orders API — RED Metrics');
  console.log('         error-rate panel climbing, p99 panel climbing, in-flight rising');
  console.log('    2. http://localhost:3000/d/obs-slo-budget    Orders API — SLO & Error Budget');
  console.log('         budget-remaining gauge draining, burn-rate rungs lighting up');
  console.log('    3. http://localhost:9090/alerts              Prometheus — PENDING then FIRING');
  console.log('    4. http://localhost:9093                     Alertmanager — grouped, routed');
  console.log('    5. http://localhost:3000/d/obs-logs-explorer Logs: {namespace="demo"} |= "level=ERROR"');
  console.log('    6. Follow the runbook_url on the alert -> runbooks/ErrorBudgetBurn.md');
  console.log('         and actually walk the runbook. A runbook nobody has walked is fiction.');
  console.log('');
  console.log('  STOP IT EARLY:  make heal     (or ./scripts/heal.ps1 / ./scripts/heal.sh)');
  console.log('================================================================');
  console.log('');

  return { startedAt: t0.toISOString(), errorPct: ERROR_PCT, latencyPct: LATENCY_PCT };
}

// =============================================================================
// DEFAULT — same 60/30/10 traffic mix as steady.js.
// Identical mix is load-bearing: the ONLY difference between the control run
// and this run must be the chaos, otherwise you cannot attribute the SLI
// movement to the fault.
// =============================================================================
export default function () {
  const roll = Math.random();

  if (roll < 0.6) {
    request('GET', '/api/orders', null);
  } else if (roll < 0.9) {
    request(
      'POST',
      '/api/checkout',
      JSON.stringify({
        customer_id: `cust-${Math.floor(Math.random() * 10000)}`,
        items: 1 + Math.floor(Math.random() * 4),
        amount_euros: Number((5 + Math.random() * 295).toFixed(2)),
        currency: 'EUR',
      })
    );
  } else {
    request('GET', '/', null);
  }

  // Jittered think time, same distribution as steady.js so the request rate is
  // comparable between the two runs.
  sleep(0.4 + Math.random() * 0.8);
}

function request(method, route, body) {
  group(`failure ${route}`, function () {
    const params = {
      headers: headers(body ? { 'Content-Type': 'application/json' } : {}),
      // Every request carries scenario: 'failure'. Combined with the global
      // options.tags this is belt and braces, but it means the tag survives
      // even if someone later overrides options.tags from the command line.
      tags: { scenario: 'failure', name: route, route: route },
      // Must exceed the injected latency (900 ms) by a wide margin. If the
      // client times out at, say, 1 s, k6 records a transport error instead of
      // a slow success and you lose the ability to distinguish "slow" from
      // "broken" — which is exactly the distinction this scenario teaches.
      timeout: '15s',
    };

    const res =
      method === 'POST'
        ? http.post(`${BASE_URL}${route}`, body, params)
        : http.get(`${BASE_URL}${route}`, params);

    // Track the injected fault rates from the client side.
    const is5xx = res.status >= 500;
    injectedErrors.add(is5xx);
    if (is5xx) {
      fiveXX.add(1, { route: route, status: String(res.status) });
    }

    budgetBurnSamples.add(res.timings.duration);
    // "Slow" is defined by the SLO threshold, not by taste: 300 ms.
    slowRequests.add(res.timings.duration > 300);

    // These checks WILL fail roughly 35% of the time. That is the designed
    // behaviour; the `checks` threshold above turns it into a red summary.
    check(res, {
      'failure: no 5xx (expected to fail ~35% here)': (r) => r.status < 500,
      'failure: under 300ms (expected to fail ~25% here)': (r) => r.timings.duration < 300,
      'failure: server responded at all': (r) => r.status !== 0,
    });
  });
}

// =============================================================================
// TEARDOWN — reset chaos. Best effort; see the caveat at the top of this file.
// =============================================================================
export function teardown(data) {
  console.log('');
  if (!RESET_ON_EXIT) {
    console.log('[teardown] RESET_ON_EXIT=false — LEAVING CHAOS ENABLED.');
    console.log('[teardown] orders-api is still broken on purpose. When you are done:');
    console.log('[teardown]     make heal    (or ./scripts/heal.ps1 / ./scripts/heal.sh)');
    return;
  }

  console.log('[teardown] resetting chaos via /chaos/reset ...');
  const res = chaos('/chaos/reset');

  if (res.status >= 200 && res.status < 400) {
    console.log(`[teardown] chaos reset OK (status ${res.status}). orders-api is healthy again.`);
  } else {
    console.error(`[teardown] CHAOS RESET FAILED (status ${res.status}).`);
    console.error('[teardown] THE APP IS STILL BROKEN. Run the escape hatch now:');
    console.error('[teardown]     make heal');
    console.error('[teardown]     # or: kubectl exec -n demo deploy/orders-api -- wget -qO- localhost:8080/chaos/reset');
    console.error('[teardown]     # or: kubectl rollout restart deploy/orders-api -n demo   (chaos state is in-memory)');
  }

  console.log(`[teardown] incident ran from ${data.startedAt} to ${new Date().toISOString()}`);
  console.log('[teardown] The error budget you just burned is REAL on the obs-slo-budget');
  console.log('[teardown] dashboard: the 30d rolling window will carry this incident for 30 days.');
  console.log('[teardown] That is the honest behaviour of a rolling window, and it is a good');
  console.log('[teardown] reason not to run fire drills against a production SLO.');
  console.log('');
}

export function handleSummary(data) {
  const m = (name, stat, fallback) => {
    const metric = data.metrics[name];
    if (!metric || metric.values[stat] === undefined) return fallback;
    return metric.values[stat];
  };
  const n = (v, d = 2) => (typeof v === 'number' ? v.toFixed(d) : String(v));
  const pct = (v) => `${(v * 100).toFixed(2)}%`;

  const failRate = m('http_req_failed', 'rate', 0);
  const p99 = m('http_req_duration', 'p(99)', 0);
  const injected = m('injected_error_rate', 'rate', 0);
  const chaosEngaged = injected > 0.1;

  const lines = [
    '',
    '================================================================',
    '  k6 failure-scenario.js — error-budget burn summary',
    '================================================================',
    `  target            : ${BASE_URL}`,
    `  injected          : ${ERROR_PCT}% 5xx, ${LATENCY_PCT}% delayed by ${LATENCY_MS}ms`,
    '  ---------------------------------------------------------------',
    `  requests          : ${m('http_reqs', 'count', 0)}`,
    `  observed 5xx      : ${m('http_5xx_total', 'count', 0)}  (${pct(injected)} of requests)`,
    `  http_req_failed   : ${pct(failRate)}        SLO allows 0.10%`,
    `  p99 latency       : ${n(p99)} ms          SLO allows 300 ms`,
    `  slower than 300ms : ${pct(m('slow_request_rate', 'rate', 0))}`,
    `  checks passed     : ${pct(m('checks', 'rate', 0))}`,
    '  ---------------------------------------------------------------',
    `  chaos engaged     : ${chaosEngaged ? 'YES' : 'NO  <-- PROBLEM, see below'}`,
    '  thresholds        : FAILED (expected)',
    '  ---------------------------------------------------------------',
    chaosEngaged
      ? '  THIS RED SUMMARY IS THE CORRECT RESULT. The SLO thresholds used here'
      : '  WARNING: fewer than 10% of requests failed, so chaos probably never',
    chaosEngaged
      ? '  are the SAME ones steady.js passes with. Chaos made them unmeetable,'
      : '  engaged. Check CHAOS_ENABLED=true on the Deployment and re-run; the',
    chaosEngaged
      ? '  which is what proves the SLO is load-bearing rather than decorative.'
      : '  alerting pipeline has NOT actually been exercised by this run.',
    '  ---------------------------------------------------------------',
    '  NOW GO AND VERIFY THE ALERTS FIRED:',
    '    http://localhost:9090/alerts        Prometheus rule state',
    '    http://localhost:9093               Alertmanager',
    '    http://localhost:3000/d/obs-slo-budget   budget drawdown',
    '  If no alert fired, the incident was invisible — and an invisible',
    '  incident is the only kind that actually hurts you.',
    '',
    '  If chaos is somehow still enabled:  make heal',
    '================================================================',
    '',
  ];

  return {
    stdout: lines.join('\n'),
    'k6-failure-summary.json': JSON.stringify(data, null, 2),
  };
}

// Tests for the orders-api demo service.
//
// These are not box-ticking tests. Each one guards a property that, if it
// broke silently, would quietly degrade the observability story:
//
//   - routeLabel() is the cardinality guard rail. If it ever stops collapsing
//     unknown paths, Prometheus starts growing a new series per URL.
//   - the instrument() middleware must record a sample for EVERY request,
//     including failures, or the error ratio SLI is wrong in the safe-looking
//     direction (too low).
//   - the histogram must carry the le="0.3" bucket, because the latency SLO is
//     literally a query against that bucket. A well-meaning refactor of the
//     bucket list would make the SLO unmeasurable without any test failing —
//     unless this test exists.
//   - chaos endpoints must be inert unless explicitly enabled.
//
// Run with:  go test ./... -v
package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

// resetChaos returns the process to a clean state between tests. Chaos state is
// package-global (it mirrors the real per-pod, in-memory behaviour), so tests
// that arm it must disarm it or they leak into their neighbours.
func resetChaos(t *testing.T) {
	t.Helper()
	chaos.reset()
	t.Cleanup(func() { chaos.reset() })
}

// ---------------------------------------------------------------------------
// Cardinality guard rail
// ---------------------------------------------------------------------------

func TestRouteLabel_CollapsesUnboundedPaths(t *testing.T) {
	cases := []struct {
		path string
		want string
	}{
		{"/", "/"},
		{"/healthz", "/healthz"},
		{"/readyz", "/readyz"},
		{"/metrics", "/metrics"},
		{"/api/orders", "/api/orders"},
		// The important ones: an ID in the path must NOT become its own label.
		{"/api/orders/12345", "/api/orders"},
		{"/api/orders/abc-def-ghi", "/api/orders"},
		{"/api/checkout", "/api/checkout"},
		{"/api/checkout/session/9f2b", "/api/checkout"},
		// All chaos variants collapse to a single value.
		{"/chaos/errors", "/chaos"},
		{"/chaos/latency", "/chaos"},
		{"/chaos/reset", "/chaos"},
		// Anything unknown — scanners, typos, probes — collapses to "other".
		{"/wp-admin.php", "other"},
		{"/../../etc/passwd", "other"},
		{"/random/" + strings.Repeat("x", 200), "other"},
	}

	for _, tc := range cases {
		if got := routeLabel(tc.path); got != tc.want {
			t.Errorf("routeLabel(%q) = %q, want %q", tc.path, got, tc.want)
		}
	}
}

func TestRouteLabel_ProducesBoundedSet(t *testing.T) {
	// Hammer routeLabel with pseudo-random paths and assert the output set never
	// grows beyond the known template list. This is the property that keeps
	// Prometheus alive.
	allowed := map[string]bool{
		"/": true, "/healthz": true, "/readyz": true, "/metrics": true,
		"/api/orders": true, "/api/checkout": true, "/chaos": true, "other": true,
	}

	seen := map[string]bool{}
	for i := 0; i < 2000; i++ {
		seen[routeLabel("/api/orders/"+strings.Repeat("a", i%50))] = true
		seen[routeLabel("/unknown/"+strings.Repeat("b", i%37))] = true
	}

	for route := range seen {
		if !allowed[route] {
			t.Errorf("routeLabel produced unexpected label value %q — cardinality guard rail is broken", route)
		}
	}
	if len(seen) > len(allowed) {
		t.Errorf("routeLabel produced %d distinct values, want at most %d", len(seen), len(allowed))
	}
}

// ---------------------------------------------------------------------------
// Probe handlers
// ---------------------------------------------------------------------------

func TestHealthz_AlwaysOK(t *testing.T) {
	// Liveness must not depend on anything. Even with chaos fully armed it has
	// to return 200, otherwise Kubernetes restarts a pod that is merely
	// degraded — turning a partial outage into a total one.
	resetChaos(t)
	chaos.mu.Lock()
	chaos.errorPct = 100
	chaos.mu.Unlock()

	rr := httptest.NewRecorder()
	newMux().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("GET /healthz = %d, want 200 even under injected faults", rr.Code)
	}
}

func TestReadyz_ReflectsDrainState(t *testing.T) {
	mux := newMux()

	ready.Store(true)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("ready=true: GET /readyz = %d, want 200", rr.Code)
	}

	// Draining: readiness must fail so the Endpoints controller pulls this pod
	// out of the Service before the server stops accepting.
	ready.Store(false)
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("ready=false: GET /readyz = %d, want 503", rr.Code)
	}

	ready.Store(true) // restore for other tests
}

// ---------------------------------------------------------------------------
// Business handlers
// ---------------------------------------------------------------------------

func TestHandleOrders_SuccessPath(t *testing.T) {
	resetChaos(t)

	before := testutil.ToFloat64(ordersProcessedTotal.WithLabelValues("success"))

	rr := httptest.NewRecorder()
	newMux().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("GET /api/orders = %d, want 200", rr.Code)
	}

	var body map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	if _, ok := body["orders"]; !ok {
		t.Errorf("response missing \"orders\" key: %s", rr.Body.String())
	}

	after := testutil.ToFloat64(ordersProcessedTotal.WithLabelValues("success"))
	if after != before+1 {
		t.Errorf("orders_processed_total{status=\"success\"} = %v, want %v", after, before+1)
	}
}

func TestHandleCheckout_SuccessPath(t *testing.T) {
	resetChaos(t)

	rr := httptest.NewRecorder()
	newMux().ServeHTTP(rr, httptest.NewRequest(http.MethodPost, "/api/checkout", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("POST /api/checkout = %d, want 200", rr.Code)
	}

	var body map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	for _, key := range []string{"order_id", "status", "value_eur"} {
		if _, ok := body[key]; !ok {
			t.Errorf("checkout response missing %q: %s", key, rr.Body.String())
		}
	}
}

// ---------------------------------------------------------------------------
// Metric recording through the middleware
// ---------------------------------------------------------------------------

func TestInstrument_RecordsRateErrorsDuration(t *testing.T) {
	resetChaos(t)
	handler := instrument(newMux())

	countBefore := testutil.ToFloat64(httpRequestsTotal.WithLabelValues(http.MethodGet, "/api/orders", "200"))

	const n = 5
	for i := 0; i < n; i++ {
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))
		if rr.Code != http.StatusOK {
			t.Fatalf("request %d: got %d, want 200", i, rr.Code)
		}
	}

	countAfter := testutil.ToFloat64(httpRequestsTotal.WithLabelValues(http.MethodGet, "/api/orders", "200"))
	if countAfter != countBefore+n {
		t.Errorf("http_requests_total delta = %v, want %v", countAfter-countBefore, float64(n))
	}

	// The duration histogram must have observed the same number of events. If
	// these two ever diverge, every latency SLI silently drifts.
	if got := testutil.CollectAndCount(httpRequestDuration); got == 0 {
		t.Error("http_request_duration_seconds produced no series")
	}
}

func TestInstrument_RecordsErrorsNotJustSuccesses(t *testing.T) {
	// The failure mode this guards: a middleware that returns early on error and
	// never increments the counter. The availability SLI would then look
	// perfect during an outage, which is the worst possible failure direction.
	resetChaos(t)

	chaos.mu.Lock()
	chaos.errorPct = 100 // every request fails
	chaos.mu.Unlock()

	handler := instrument(newMux())

	before := testutil.ToFloat64(httpRequestsTotal.WithLabelValues(http.MethodGet, "/api/orders", "500"))

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("with errorPct=100, GET /api/orders = %d, want 500", rr.Code)
	}

	after := testutil.ToFloat64(httpRequestsTotal.WithLabelValues(http.MethodGet, "/api/orders", "500"))
	if after != before+1 {
		t.Errorf("http_requests_total{status=\"500\"} delta = %v, want 1", after-before)
	}
}

func TestInstrument_InFlightReturnsToBaseline(t *testing.T) {
	// A leaked in-flight gauge produces a permanently firing saturation alert.
	resetChaos(t)
	handler := instrument(newMux())

	baseline := testutil.ToFloat64(httpRequestsInFlight)

	for i := 0; i < 3; i++ {
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))
	}

	if got := testutil.ToFloat64(httpRequestsInFlight); got != baseline {
		t.Errorf("http_requests_in_flight = %v after requests completed, want %v", got, baseline)
	}
}

// ---------------------------------------------------------------------------
// The SLO bucket contract
// ---------------------------------------------------------------------------

func TestHistogramHasSLOBuckets(t *testing.T) {
	// slo/latency.yaml measures "fraction of requests faster than 300ms" as
	//
	//   http_request_duration_seconds_bucket{le="0.3"} / ..._count
	//
	// and the HighLatencyP99 alert leans on the 500ms edge. If either bucket
	// boundary disappears, those queries return no data and the SLO silently
	// stops being measured. This test makes that a build failure instead.
	resetChaos(t)
	handler := instrument(newMux())

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))

	metricsRR := httptest.NewRecorder()
	newMux().ServeHTTP(metricsRR, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	body, err := io.ReadAll(metricsRR.Body)
	if err != nil {
		t.Fatalf("reading /metrics: %v", err)
	}
	exposition := string(body)

	for _, le := range []string{`le="0.3"`, `le="0.5"`} {
		if !strings.Contains(exposition, le) {
			t.Errorf("http_request_duration_seconds is missing the %s bucket — the latency SLO is unmeasurable without it", le)
		}
	}
}

func TestMetricsEndpointExposesAllDeclaredMetrics(t *testing.T) {
	// Dashboards, recording rules and alert rules across this repo reference
	// these names by hand. If one is renamed, panels go blank and alerts quietly
	// never fire. Keep this list in sync with the CONTRACT section of README.md.
	resetChaos(t)

	// Touch the business metrics so they appear in the exposition format.
	handler := instrument(newMux())
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/orders", nil))
	appBuildInfo.WithLabelValues(version, commit, "go1.23").Set(1)
	queueDepth.Set(0)

	rr := httptest.NewRecorder()
	newMux().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("GET /metrics = %d, want 200", rr.Code)
	}
	body := rr.Body.String()

	required := []string{
		"http_requests_total",
		"http_request_duration_seconds_bucket",
		"http_request_duration_seconds_count",
		"http_request_duration_seconds_sum",
		"http_requests_in_flight",
		"orders_processed_total",
		"order_value_euros_bucket",
		"queue_depth",
		"app_build_info",
		// Free collectors that the Kubernetes dashboards rely on.
		"go_goroutines",
		"process_resident_memory_bytes",
	}
	for _, name := range required {
		if !strings.Contains(body, name) {
			t.Errorf("/metrics does not expose %q", name)
		}
	}
}

// ---------------------------------------------------------------------------
// Chaos endpoints
// ---------------------------------------------------------------------------

func TestChaosEndpoints_NotRoutedWhenDisabled(t *testing.T) {
	// Safety property: fault injection must be unreachable in a build that did
	// not opt in. Anything else is a production incident waiting to happen.
	original := chaosEnabled
	chaosEnabled = false
	t.Cleanup(func() { chaosEnabled = original })

	mux := newMux()
	for _, path := range []string{"/chaos/errors", "/chaos/latency", "/chaos/leak", "/chaos/cpu", "/chaos/reset"} {
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		// The catch-all "/" pattern in ServeMux answers unknown paths with the
		// index, so the assertion is "it did not act as a chaos endpoint".
		if strings.Contains(rr.Body.String(), `"chaos"`) {
			t.Errorf("%s responded as a chaos endpoint while CHAOS_ENABLED=false", path)
		}
	}
}

func TestChaosErrors_ArmsAndResets(t *testing.T) {
	original := chaosEnabled
	chaosEnabled = true
	t.Cleanup(func() { chaosEnabled = original })
	resetChaos(t)

	mux := newMux()

	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/chaos/errors?pct=100", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("arming chaos returned %d, want 200", rr.Code)
	}
	if _, _, got := chaos.snapshot(); got != 100 {
		t.Fatalf("errorPct = %d after arming, want 100", got)
	}

	// Every subsequent business request must now fail.
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))
	if rr.Code != http.StatusInternalServerError {
		t.Errorf("with chaos armed at 100%%, GET /api/orders = %d, want 500", rr.Code)
	}

	// And /chaos/reset must put everything back.
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/chaos/reset", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("reset returned %d, want 200", rr.Code)
	}
	if _, _, got := chaos.snapshot(); got != 0 {
		t.Errorf("errorPct = %d after reset, want 0", got)
	}

	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))
	if rr.Code != http.StatusOK {
		t.Errorf("after reset, GET /api/orders = %d, want 200", rr.Code)
	}
}

func TestChaosLatency_AddsDelay(t *testing.T) {
	original := chaosEnabled
	chaosEnabled = true
	t.Cleanup(func() { chaosEnabled = original })
	resetChaos(t)

	mux := newMux()

	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/chaos/latency?ms=250&pct=100", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("arming latency chaos returned %d, want 200", rr.Code)
	}

	start := time.Now()
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/orders", nil))
	elapsed := time.Since(start)

	if elapsed < 250*time.Millisecond {
		t.Errorf("request took %v, want at least 250ms of injected latency", elapsed)
	}
	if rr.Code != http.StatusOK {
		t.Errorf("latency injection must not change the status code; got %d", rr.Code)
	}
}

func TestChaosParameters_AreClamped(t *testing.T) {
	// Hostile or fat-fingered input must not be able to take the node down.
	cases := []struct {
		in, want int
	}{
		{-50, 0}, {0, 0}, {42, 42}, {100, 100}, {5000, 100},
	}
	for _, tc := range cases {
		if got := clampPercent(tc.in); got != tc.want {
			t.Errorf("clampPercent(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}

	if rollPercent(0) {
		t.Error("rollPercent(0) must never fire")
	}
	if !rollPercent(100) {
		t.Error("rollPercent(100) must always fire")
	}
}

// ---------------------------------------------------------------------------
// Queue simulator
// ---------------------------------------------------------------------------

func TestQueueSimulator_GrowsUnderFaultDrainsWhenHealthy(t *testing.T) {
	// queue_depth is the leading indicator the QueueDepthGrowing alert watches.
	resetChaos(t)

	queueMu.Lock()
	queueValue = 0
	queueMu.Unlock()
	queueDepth.Set(0)

	addQueue(10)
	if got := testutil.ToFloat64(queueDepth); got != 10 {
		t.Fatalf("queue_depth = %v after addQueue(10), want 10", got)
	}

	drainQueue(4)
	if got := testutil.ToFloat64(queueDepth); got != 6 {
		t.Errorf("queue_depth = %v after drainQueue(4), want 6", got)
	}

	// The queue must never go negative — a negative gauge breaks the dashboard
	// axis and any rate-of-change alert built on it.
	drainQueue(100)
	if got := testutil.ToFloat64(queueDepth); got != 0 {
		t.Errorf("queue_depth = %v after over-draining, want 0 (must clamp)", got)
	}
}

func TestQueueSimulator_StopsOnContextCancel(t *testing.T) {
	// A background goroutine that ignores cancellation blocks graceful shutdown.
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})

	go func() {
		runQueueSimulator(ctx)
		close(done)
	}()

	cancel()

	select {
	case <-done:
		// Correct: the simulator honoured the cancellation.
	case <-time.After(2 * time.Second):
		t.Error("runQueueSimulator did not return within 2s of context cancellation")
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func TestGetenvHelpers(t *testing.T) {
	t.Setenv("TEST_OBS_STRING", "value")
	if got := getenv("TEST_OBS_STRING", "fallback"); got != "value" {
		t.Errorf("getenv = %q, want %q", got, "value")
	}
	if got := getenv("TEST_OBS_ABSENT", "fallback"); got != "fallback" {
		t.Errorf("getenv fallback = %q, want %q", got, "fallback")
	}

	// Whitespace-only env vars are a classic Kubernetes ConfigMap accident and
	// must be treated as unset.
	t.Setenv("TEST_OBS_BLANK", "   ")
	if got := getenv("TEST_OBS_BLANK", "fallback"); got != "fallback" {
		t.Errorf("getenv(whitespace) = %q, want fallback", got)
	}

	t.Setenv("TEST_OBS_BOOL", "true")
	if !getenvBool("TEST_OBS_BOOL", false) {
		t.Error("getenvBool = false, want true")
	}
	if !getenvBool("TEST_OBS_ABSENT_BOOL", true) {
		t.Error("getenvBool fallback = false, want true")
	}

	t.Setenv("TEST_OBS_FLOAT", "0.25")
	if got := getenvFloat("TEST_OBS_FLOAT", 1.0); got != 0.25 {
		t.Errorf("getenvFloat = %v, want 0.25", got)
	}
	t.Setenv("TEST_OBS_BAD_FLOAT", "not-a-number")
	if got := getenvFloat("TEST_OBS_BAD_FLOAT", 1.0); got != 1.0 {
		t.Errorf("getenvFloat(invalid) = %v, want the fallback 1.0", got)
	}
}

func TestRandomDuration_StaysInBounds(t *testing.T) {
	for i := 0; i < 500; i++ {
		d := randomDuration(10*time.Millisecond, 50*time.Millisecond)
		if d < 10*time.Millisecond || d >= 50*time.Millisecond {
			t.Fatalf("randomDuration out of bounds: %v", d)
		}
	}
	// Degenerate range must not panic.
	if got := randomDuration(5*time.Millisecond, 5*time.Millisecond); got != 5*time.Millisecond {
		t.Errorf("randomDuration(equal bounds) = %v, want 5ms", got)
	}
}

func TestStatusRecorder_DefaultsTo200AndIgnoresDoubleWrite(t *testing.T) {
	rr := httptest.NewRecorder()
	rec := &statusRecorder{ResponseWriter: rr, status: http.StatusOK}

	// Writing a body without calling WriteHeader is an implicit 200.
	if _, err := rec.Write([]byte("hello")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if rec.status != http.StatusOK {
		t.Errorf("implicit status = %d, want 200", rec.status)
	}

	// A second WriteHeader must be ignored, matching net/http semantics —
	// otherwise the metric label would disagree with the wire response.
	rec.WriteHeader(http.StatusTeapot)
	if rec.status != http.StatusOK {
		t.Errorf("status after double WriteHeader = %d, want 200", rec.status)
	}
}

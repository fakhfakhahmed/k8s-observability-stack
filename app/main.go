// Command orders-api is a deliberately small HTTP service that is instrumented
// the way a real production service should be. It exists to give the
// observability stack in this repository something truthful to observe.
//
// It emits all three telemetry signals, and — critically — it emits them in a
// way that lets you *join* them:
//
//	METRICS  Prometheus RED metrics + business metrics on /metrics
//	TRACES   OpenTelemetry spans exported over OTLP/gRPC to Tempo
//	LOGS     structured JSON (log/slog) on stdout, every line carrying trace_id
//
// The trace_id in the log lines is the glue. Grafana's Loki datasource is
// configured with a `derivedField` that regex-matches trace_id in the log body
// and renders it as a clickable link into Tempo; Tempo's `tracesToLogsV2`
// configuration links back the other way. See:
//
//	stack/grafana/datasources/datasources.yaml
//
// The service also exposes fault-injection ("chaos") endpoints so that alerts,
// burn-rate ladders and dashboards can be demonstrated on demand rather than
// waiting for a real incident. They are disabled unless CHAOS_ENABLED=true.
//
// Author: Ahmed Fakhfakh
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

// ---------------------------------------------------------------------------
// Build information.
//
// These are overridden at build time with -ldflags, e.g.
//
//	go build -ldflags "-X main.version=0.1.0 -X main.commit=$(git rev-parse --short HEAD)"
//
// See app/Dockerfile.
// ---------------------------------------------------------------------------

var (
	version = "0.1.0"
	commit  = "dev"
)

const serviceName = "orders-api"

// ---------------------------------------------------------------------------
// PROMETHEUS METRICS
//
// Naming follows the Prometheus conventions:
//   - snake_case, prefixed by the subsystem, suffixed by the BASE unit
//     (seconds, bytes, euros) — never milliseconds, never a unit in a label
//   - counters end in _total
//   - a counter measures a monotonically increasing quantity; you almost always
//     query it through rate() or increase(), never raw
//
// CARDINALITY WARNING (the single most important Prometheus discipline):
// every unique combination of label values is a separate time series, and every
// series costs memory in the head block and bytes on disk. The labels below are
// all BOUNDED:
//
//	method ~5 values, route ~7 values, status ~8 values  => ~280 series per pod
//
// Adding an unbounded label such as `user_id`, `order_id` or — worst of all —
// `trace_id` would create a new series per request, forever. That is how people
// OOM a Prometheus. trace_id belongs in the log line and the span context, which
// is exactly where this service puts it. See LEARN.md "Cardinality".
// ---------------------------------------------------------------------------

var (
	// RATE + ERRORS of the RED method. One counter answers both: the rate is
	// sum(rate(http_requests_total[5m])) and the error ratio is the same thing
	// filtered to status=~"5..".
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests handled, partitioned by method, route template and response status code.",
		},
		// `route` is the ROUTE TEMPLATE, not the raw URL path. Normalising it in
		// routeLabel() is what keeps cardinality bounded — "/api/orders/12345"
		// must never become its own label value.
		[]string{"method", "route", "status"},
	)

	// DURATION of the RED method.
	//
	// BUCKET CHOICE IS NOT COSMETIC. histogram_quantile() interpolates linearly
	// *inside* the bucket it lands in, so the precision of your p99 is bounded by
	// your bucket edges. More importantly, an SLO of the form "99% of requests
	// faster than 300ms" is only measurable if a bucket boundary sits EXACTLY at
	// 300ms — the SLI is literally
	//
	//	http_request_duration_seconds_bucket{le="0.3"} / http_request_duration_seconds_count
	//
	// and without an le="0.3" series that query returns nothing. The same applies
	// to the 500ms secondary threshold used by the HighLatencyP99 alert.
	//
	// So: 0.3 and 0.5 are in this list *because the SLOs say 300ms and 500ms*.
	// If you change an SLO threshold, you must change these buckets, and vice
	// versa. See slo/latency.yaml and docs/slo-guide.md.
	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds. Buckets deliberately straddle the 300ms and 500ms SLO thresholds.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 2.5, 5, 10},
		},
		// Deliberately NOT labelled by status: a histogram costs
		// (len(buckets)+2) series per label combination, so adding `status` here
		// would multiply the series count by ~8 for very little analytical value.
		[]string{"method", "route"},
	)

	// SATURATION. The signal everybody forgets. Rate/Errors/Duration tell you how
	// the service is behaving; in-flight tells you how close it is to falling
	// over. This is the "S" of the Four Golden Signals.
	httpRequestsInFlight = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Number of HTTP requests currently being served. A saturation signal.",
		},
	)

	// --- Business metrics -------------------------------------------------
	//
	// Observability is not only infrastructure. "CPU is fine" is worthless if no
	// orders are being processed. These metrics let you alert on the thing the
	// business actually cares about, and they are often the FIRST signal of a
	// subtle failure (a dependency returning 200 with an empty body, say).

	ordersProcessedTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "orders_processed_total",
			Help: "Total number of orders processed, partitioned by outcome.",
		},
		[]string{"status"}, // success | failed | rejected
	)

	orderValueEuros = promauto.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "order_value_euros",
			Help:    "Distribution of order values in euros.",
			Buckets: []float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500},
		},
	)

	// A gauge that grows when the service cannot keep up. The QueueDepthGrowing
	// alert watches this; during an injected incident it climbs, which makes for
	// a convincing demo of a leading indicator.
	queueDepth = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "queue_depth",
			Help: "Number of orders waiting in the internal processing queue. A leading indicator of saturation.",
		},
	)

	// The classic "info metric" pattern: a gauge whose value is always 1 and
	// whose *labels* carry the information. Joined onto other metrics at query
	// time with `* on(instance) group_left(version) app_build_info`, this is how
	// you overlay deploy markers on a latency graph or answer "which version was
	// running when this broke?".
	appBuildInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "app_build_info",
			Help: "Build information. Always 1; the value is in the labels. Join with group_left to attribute metrics to a release.",
		},
		[]string{"version", "commit", "go_version"},
	)
)

// ---------------------------------------------------------------------------
// CHAOS / FAULT INJECTION STATE
//
// Guarded by CHAOS_ENABLED. The point of these endpoints is verification: an
// alert you have never seen fire is a hypothesis, not a control. Being able to
// drive the system into a known-bad state on demand is how you prove that the
// recording rules, the burn-rate ladder, the routing tree and the runbook links
// all actually work — and how you produce screenshots without waiting for a
// real outage.
//
// NOTE: this state is per-process and in-memory. With more than one replica,
// each pod has its own chaos state, which is why scripts/heal iterates over all
// pods rather than hitting the Service once.
// ---------------------------------------------------------------------------

type chaosState struct {
	mu sync.RWMutex

	latencyMs  int // extra latency to inject, in milliseconds
	latencyPct int // percentage of requests that get it (0-100)
	errorPct   int // percentage of requests forced to return 500 (0-100)

	leaked    [][]byte           // deliberately retained allocations
	cpuCancel context.CancelFunc // cancels any running CPU burner
}

func (c *chaosState) snapshot() (latencyMs, latencyPct, errorPct int) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.latencyMs, c.latencyPct, c.errorPct
}

func (c *chaosState) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.latencyMs, c.latencyPct, c.errorPct = 0, 0, 0
	c.leaked = nil
	if c.cpuCancel != nil {
		c.cpuCancel()
		c.cpuCancel = nil
	}
	// Hand the leaked memory back to the OS so that
	// container_memory_working_set_bytes visibly recovers on the dashboard.
	runtime.GC()
}

var chaos = &chaosState{}

// ---------------------------------------------------------------------------
// STRUCTURED LOGGING WITH TRACE CORRELATION
//
// traceHandler wraps any slog.Handler and, for every record logged with a
// context that carries a recording span, injects:
//
//	trace_id  — the 32-hex-character trace identifier
//	span_id   — the 16-hex-character span identifier
//
// THIS IS THE ENTIRE CORRELATION MECHANISM. Without trace_id in the log line
// there is nothing for Grafana's `derivedFields` regex to match, and the
// Loki -> Tempo jump silently does nothing. It is three lines of code and it is
// the difference between "we have logs and traces" and "we have observability".
//
// Note that trace_id is a *field in the log body*, never a Loki label. Loki
// labels define streams; a per-request label value would create one stream per
// request and destroy the index. See docs/logql-cookbook.md.
// ---------------------------------------------------------------------------

type traceHandler struct {
	slog.Handler
}

func (h traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return traceHandler{Handler: h.Handler.WithAttrs(attrs)}
}

func (h traceHandler) WithGroup(name string) slog.Handler {
	return traceHandler{Handler: h.Handler.WithGroup(name)}
}

// newLogger builds the JSON logger. Promtail's pipeline in
// stack/loki/promtail-values.yaml parses exactly this shape.
func newLogger(level slog.Level) *slog.Logger {
	base := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			// Emit RFC3339 with milliseconds. Loki needs a parseable timestamp,
			// and a stable key name ("time") keeps the Promtail stage simple.
			if a.Key == slog.TimeKey {
				return slog.String("time", a.Value.Time().UTC().Format("2006-01-02T15:04:05.000Z07:00"))
			}
			return a
		},
	})
	return slog.New(traceHandler{Handler: base}).With(
		slog.String("service", serviceName),
		slog.String("version", version),
	)
}

var logger = newLogger(slog.LevelInfo)

// ---------------------------------------------------------------------------
// ROUTE NORMALISATION
//
// Maps a raw request path onto a BOUNDED set of route templates. This is the
// guard rail that stops a crawler hitting /api/orders/../../etc from minting
// thousands of label values.
// ---------------------------------------------------------------------------

func routeLabel(path string) string {
	switch {
	case path == "/":
		return "/"
	case path == "/healthz":
		return "/healthz"
	case path == "/readyz":
		return "/readyz"
	case path == "/metrics":
		return "/metrics"
	case strings.HasPrefix(path, "/api/orders"):
		return "/api/orders"
	case strings.HasPrefix(path, "/api/checkout"):
		return "/api/checkout"
	case strings.HasPrefix(path, "/chaos"):
		// All chaos endpoints collapse to one label. They are excluded from the
		// SLI anyway — see stack/prometheus/rules/recording-rules.yaml.
		return "/chaos"
	default:
		// Everything unknown collapses here. Without this line, cardinality is
		// controlled by whoever is scanning your service, not by you.
		return "other"
	}
}

// ---------------------------------------------------------------------------
// HTTP MIDDLEWARE
// ---------------------------------------------------------------------------

// statusRecorder captures the status code so the metrics middleware can label
// by it. net/http gives you no way to read back what the handler wrote.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.wroteHeader {
		return
	}
	r.status = code
	r.wroteHeader = true
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if !r.wroteHeader {
		// An implicit 200, exactly as net/http would do.
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(b)
}

// Flush keeps the wrapper transparent to streaming handlers.
func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// instrument records the three RED signals plus saturation for every request.
func instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		route := routeLabel(r.URL.Path)

		// Saturation: increment on entry, decrement on exit, no matter how the
		// handler returns. A defer here is not optional — an early return or a
		// panic that skipped the Dec() would leak the gauge upward forever and
		// your saturation alert would be permanently firing.
		httpRequestsInFlight.Inc()
		defer httpRequestsInFlight.Dec()

		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(rec, r)

		elapsed := time.Since(start).Seconds()
		httpRequestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
		httpRequestDuration.WithLabelValues(r.Method, route).Observe(elapsed)
	})
}

// ---------------------------------------------------------------------------
// CHAOS APPLICATION
// ---------------------------------------------------------------------------

// errInjected is returned by applyChaos when a request has been selected for a
// forced failure.
var errInjected = errors.New("fault injected by /chaos/errors")

// applyChaos is called at the top of every business handler. It is a no-op
// unless somebody has armed the chaos endpoints.
//
// It records what it did onto the active span, so an injected fault is visible
// in the Tempo trace waterfall and not just in the HTTP status code. During a
// demo this is the moment the audience understands what traces are for.
func applyChaos(ctx context.Context) error {
	latencyMs, latencyPct, errorPct := chaos.snapshot()
	span := trace.SpanFromContext(ctx)

	if latencyMs > 0 && rollPercent(latencyPct) {
		span.SetAttributes(
			attribute.Bool("chaos.latency.injected", true),
			attribute.Int("chaos.latency.ms", latencyMs),
		)
		// A child span makes the injected delay a visible block in the waterfall
		// rather than unexplained dead time inside the parent.
		_, sleepSpan := tracer().Start(ctx, "chaos.inject_latency")
		time.Sleep(time.Duration(latencyMs) * time.Millisecond)
		sleepSpan.End()
	}

	if errorPct > 0 && rollPercent(errorPct) {
		span.SetAttributes(attribute.Bool("chaos.error.injected", true))
		span.SetStatus(codes.Error, "injected fault")
		span.RecordError(errInjected)
		return errInjected
	}

	return nil
}

// rollPercent returns true with probability pct/100.
func rollPercent(pct int) bool {
	if pct <= 0 {
		return false
	}
	if pct >= 100 {
		return true
	}
	return rand.IntN(100) < pct
}

// ---------------------------------------------------------------------------
// TRACING SETUP
// ---------------------------------------------------------------------------

func tracer() trace.Tracer {
	return otel.Tracer("github.com/fakhfakhahmed/k8s-observability-stack/app")
}

// initTracing wires up the OpenTelemetry SDK and returns a shutdown function
// that MUST be called before the process exits — the BatchSpanProcessor holds
// spans in memory and drops them if you just os.Exit(). A trace that stops
// exactly at the moment of the crash you are investigating is a familiar and
// avoidable disappointment.
func initTracing(ctx context.Context) (func(context.Context) error, error) {
	// OTEL_EXPORTER_OTLP_ENDPOINT conventionally carries a scheme
	// ("http://tempo.monitoring.svc.cluster.local:4317") but the gRPC exporter's
	// WithEndpoint option wants a bare host:port. Mismatching these is one of the
	// most common "my traces never arrive, and there is no error" bugs, so we
	// normalise it explicitly instead of relying on the implicit env parsing.
	raw := getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "tempo.monitoring.svc.cluster.local:4317")
	endpoint := raw
	if strings.Contains(raw, "://") {
		u, err := url.Parse(raw)
		if err != nil {
			return nil, fmt.Errorf("parse OTEL_EXPORTER_OTLP_ENDPOINT %q: %w", raw, err)
		}
		endpoint = u.Host
	}

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		// Plaintext inside the cluster. In production this would be mTLS, or the
		// span pipeline would terminate at a sidecar/daemonset OTel Collector.
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithTimeout(5*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("create OTLP trace exporter: %w", err)
	}

	// Resource attributes describe the *producer* of the telemetry and are
	// attached to every span. Tempo's metrics-generator uses service.name to
	// build the service graph, and Grafana's tracesToLogsV2 uses them to find the
	// matching Loki stream.
	res, err := resource.New(ctx,
		resource.WithFromEnv(),      // picks up OTEL_RESOURCE_ATTRIBUTES
		resource.WithTelemetrySDK(), // telemetry.sdk.* attributes
		resource.WithProcess(),
		resource.WithAttributes(
			semconv.ServiceName(getenv("OTEL_SERVICE_NAME", serviceName)),
			semconv.ServiceVersion(version),
			semconv.DeploymentEnvironment(getenv("DEPLOY_ENV", "minikube")),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("build OTel resource: %w", err)
	}

	// Sampling. This demo samples everything (ratio 1.0) because the traffic is
	// tiny and a missing trace during a demo is worse than the storage cost.
	//
	// In production you would either head-sample at a few percent (cheap, but you
	// lose the rare slow request you actually wanted) or run tail-based sampling
	// in an OTel Collector so you can keep 100% of errors and slow traces and
	// 1% of the boring ones. ParentBased means we honour an upstream service's
	// sampling decision rather than breaking the trace in half.
	ratio := getenvFloat("OTEL_TRACES_SAMPLER_RATIO", 1.0)

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter,
			sdktrace.WithMaxQueueSize(2048),
			sdktrace.WithBatchTimeout(2*time.Second),
		),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))),
	)
	otel.SetTracerProvider(tp)

	// Context propagation. W3C TraceContext is the standard `traceparent` header;
	// Baggage carries arbitrary key/values alongside it. Without a propagator set,
	// incoming traceparent headers are ignored and every service starts its own
	// disconnected trace — the classic "my traces have one span" symptom.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp.Shutdown, nil
}

// ---------------------------------------------------------------------------
// HANDLERS
// ---------------------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

// handleRoot is a tiny self-describing index, handy during a live demo.
func handleRoot(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"service": serviceName,
		"version": version,
		"commit":  commit,
		"endpoints": []string{
			"GET /healthz", "GET /readyz", "GET /metrics",
			"GET /api/orders", "POST /api/checkout",
		},
		"chaos_enabled": chaosEnabled,
		"docs":          "https://github.com/fakhfakhahmed/k8s-observability-stack",
	})
}

// handleHealthz is the LIVENESS probe: "is this process wedged?". It must stay
// trivially cheap and must NOT check dependencies — a liveness probe that fails
// when the database is slow turns a dependency blip into a cluster-wide restart
// storm.
func handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ready flips to false the moment SIGTERM arrives, before the HTTP server stops
// accepting. That gives the Endpoints controller time to remove this pod from
// the Service, which is how you get genuinely zero-downtime rollouts instead of
// a handful of connection-refused errors on every deploy.
var ready atomic.Bool

// handleReadyz is the READINESS probe: "should traffic be sent here?".
func handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// handleOrders simulates normal request-serving work with variable latency.
func handleOrders(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Attributes on the server span. Keep them descriptive — attributes are free
	// in a trace backend in a way that labels are NOT free in Prometheus.
	span := trace.SpanFromContext(ctx)
	span.SetAttributes(
		attribute.String("app.operation", "list_orders"),
		attribute.String("http.route", "/api/orders"),
	)

	if err := applyChaos(ctx); err != nil {
		ordersProcessedTotal.WithLabelValues("failed").Inc()
		queueDepth.Add(1) // work that could not be completed piles up
		logger.ErrorContext(ctx, "order processing failed",
			slog.String("route", "/api/orders"),
			slog.Int("status", http.StatusInternalServerError),
			slog.String("error", err.Error()),
		)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	// Nested span: validation.
	ctx, validateSpan := tracer().Start(ctx, "orders.validate")
	time.Sleep(randomDuration(2*time.Millisecond, 8*time.Millisecond))
	validateSpan.SetAttributes(attribute.Int("orders.count", 3))
	validateSpan.End()

	// Nested span: the "database" read.
	ctx, dbSpan := tracer().Start(ctx, "orders.query")
	dbSpan.SetAttributes(
		attribute.String("db.system", "postgresql"),
		attribute.String("db.operation", "SELECT"),
		attribute.String("db.sql.table", "orders"),
	)
	latency := randomDuration(15*time.Millisecond, 70*time.Millisecond)
	time.Sleep(latency)
	dbSpan.End()

	value := 5 + rand.Float64()*495
	orderValueEuros.Observe(value)
	ordersProcessedTotal.WithLabelValues("success").Inc()

	orderID := fmt.Sprintf("ord-%d", 1000+rand.IntN(9000))
	logger.InfoContext(ctx, "orders listed",
		slog.String("route", "/api/orders"),
		slog.Int("status", http.StatusOK),
		slog.Float64("duration_ms", float64(latency.Microseconds())/1000.0),
		slog.String("order_id", orderID),
		slog.Float64("order_value_eur", round2(value)),
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"orders": []map[string]any{
			{"id": orderID, "value_eur": round2(value), "status": "confirmed"},
		},
	})
}

// handleCheckout calls a simulated downstream dependency so that traces have
// real depth — a flat one-span trace teaches nobody anything, and the whole
// point of tracing is attributing latency ACROSS a boundary.
func handleCheckout(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)
	span.SetAttributes(
		attribute.String("app.operation", "checkout"),
		attribute.String("http.route", "/api/checkout"),
	)

	if err := applyChaos(ctx); err != nil {
		ordersProcessedTotal.WithLabelValues("failed").Inc()
		queueDepth.Add(1)
		logger.ErrorContext(ctx, "checkout failed",
			slog.String("route", "/api/checkout"),
			slog.Int("status", http.StatusInternalServerError),
			slog.String("error", err.Error()),
		)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "checkout failed"})
		return
	}

	start := time.Now()

	// --- Downstream dependency 1: inventory service -----------------------
	ctx, invSpan := tracer().Start(ctx, "inventory.reserve",
		trace.WithSpanKind(trace.SpanKindClient),
	)
	invSpan.SetAttributes(
		attribute.String("peer.service", "inventory-service"),
		attribute.String("rpc.system", "grpc"),
		attribute.String("rpc.method", "ReserveStock"),
	)
	time.Sleep(randomDuration(10*time.Millisecond, 45*time.Millisecond))
	invSpan.End()

	// --- Downstream dependency 2: payment gateway -------------------------
	// Deliberately the slowest span in the trace, and occasionally much slower,
	// so the waterfall has an obvious culprit to point at during a demo.
	ctx, paySpan := tracer().Start(ctx, "payment-gateway.authorize",
		trace.WithSpanKind(trace.SpanKindClient),
	)
	paySpan.SetAttributes(
		attribute.String("peer.service", "payment-gateway"),
		attribute.String("http.request.method", "POST"),
		attribute.String("url.full", "https://payments.example.com/v2/authorize"),
	)
	payLatency := randomDuration(40*time.Millisecond, 120*time.Millisecond)
	if rand.IntN(100) < 5 {
		// 5% of authorisations hit a slow path. This is what makes the p99
		// meaningfully different from the p50 and gives the latency SLO
		// something real to measure.
		payLatency += randomDuration(200*time.Millisecond, 600*time.Millisecond)
		paySpan.SetAttributes(attribute.Bool("payment.slow_path", true))
		paySpan.AddEvent("retry", trace.WithAttributes(attribute.Int("attempt", 2)))
	}
	time.Sleep(payLatency)
	paySpan.End()

	value := 10 + rand.Float64()*990
	orderValueEuros.Observe(value)
	ordersProcessedTotal.WithLabelValues("success").Inc()

	// Drain one item from the backlog on every successful checkout.
	drainQueue(1)

	orderID := fmt.Sprintf("ord-%d", 1000+rand.IntN(9000))
	logger.InfoContext(ctx, "checkout completed",
		slog.String("route", "/api/checkout"),
		slog.Int("status", http.StatusOK),
		slog.Float64("duration_ms", round2(float64(time.Since(start).Microseconds())/1000.0)),
		slog.Float64("payment_ms", round2(float64(payLatency.Microseconds())/1000.0)),
		slog.String("order_id", orderID),
		slog.Float64("order_value_eur", round2(value)),
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"order_id":  orderID,
		"status":    "confirmed",
		"value_eur": round2(value),
	})
}

// ---------------------------------------------------------------------------
// CHAOS ENDPOINTS
//
// Documented in README.md and driven by scripts/trigger-incident and
// load/k6/failure-scenario.js.
// ---------------------------------------------------------------------------

var chaosEnabled = false

// handleChaosLatency: GET /chaos/latency?ms=900&pct=25
func handleChaosLatency(w http.ResponseWriter, r *http.Request) {
	ms := queryInt(r, "ms", 500)
	pct := clampPercent(queryInt(r, "pct", 100))

	chaos.mu.Lock()
	chaos.latencyMs, chaos.latencyPct = ms, pct
	chaos.mu.Unlock()

	logger.WarnContext(r.Context(), "chaos: latency injection armed",
		slog.Int("latency_ms", ms), slog.Int("percent", pct))
	writeJSON(w, http.StatusOK, map[string]any{"chaos": "latency", "ms": ms, "pct": pct})
}

// handleChaosErrors: GET /chaos/errors?pct=35
func handleChaosErrors(w http.ResponseWriter, r *http.Request) {
	pct := clampPercent(queryInt(r, "pct", 20))

	chaos.mu.Lock()
	chaos.errorPct = pct
	chaos.mu.Unlock()

	logger.WarnContext(r.Context(), "chaos: error injection armed", slog.Int("percent", pct))
	writeJSON(w, http.StatusOK, map[string]any{"chaos": "errors", "pct": pct})
}

// handleChaosLeak: GET /chaos/leak?mb=64
//
// Allocates and RETAINS memory so container_memory_working_set_bytes climbs and
// the container eventually gets OOMKilled against its limit. Used to demonstrate
// the ContainerOOMKilled alert and its runbook.
func handleChaosLeak(w http.ResponseWriter, r *http.Request) {
	mb := queryInt(r, "mb", 64)
	if mb < 1 {
		mb = 1
	}
	if mb > 512 {
		mb = 512 // do not let a demo take the whole laptop down
	}

	block := make([]byte, mb*1024*1024)
	// Touch every page: Go may not fault the pages in otherwise, and untouched
	// pages do not count towards the working set, so the "leak" would be
	// invisible on the dashboard.
	for i := 0; i < len(block); i += 4096 {
		block[i] = 1
	}

	chaos.mu.Lock()
	chaos.leaked = append(chaos.leaked, block)
	total := 0
	for _, b := range chaos.leaked {
		total += len(b)
	}
	chaos.mu.Unlock()

	logger.WarnContext(r.Context(), "chaos: memory retained",
		slog.Int("added_mb", mb), slog.Int("total_mb", total/(1024*1024)))
	writeJSON(w, http.StatusOK, map[string]any{"chaos": "leak", "added_mb": mb, "total_mb": total / (1024 * 1024)})
}

// handleChaosCPU: GET /chaos/cpu?workers=2&seconds=120
//
// Burns CPU to drive throttling and the node saturation panels.
func handleChaosCPU(w http.ResponseWriter, r *http.Request) {
	workers := queryInt(r, "workers", runtime.NumCPU())
	seconds := queryInt(r, "seconds", 60)
	if workers < 1 {
		workers = 1
	}
	if workers > 8 {
		workers = 8
	}
	if seconds < 1 {
		seconds = 1
	}
	if seconds > 900 {
		seconds = 900
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(seconds)*time.Second)

	chaos.mu.Lock()
	if chaos.cpuCancel != nil {
		chaos.cpuCancel() // replace any previous burner
	}
	chaos.cpuCancel = cancel
	chaos.mu.Unlock()

	for i := 0; i < workers; i++ {
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				default:
					// Busy loop. Intentionally pointless work.
					_ = rand.Float64() * rand.Float64()
				}
			}
		}()
	}

	logger.WarnContext(r.Context(), "chaos: cpu burn started",
		slog.Int("workers", workers), slog.Int("seconds", seconds))
	writeJSON(w, http.StatusOK, map[string]any{"chaos": "cpu", "workers": workers, "seconds": seconds})
}

// handleChaosReset disarms everything. scripts/heal calls this on every pod.
func handleChaosReset(w http.ResponseWriter, r *http.Request) {
	chaos.reset()
	queueDepth.Set(0)
	logger.InfoContext(r.Context(), "chaos: all fault injection reset")
	writeJSON(w, http.StatusOK, map[string]string{"chaos": "reset"})
}

// ---------------------------------------------------------------------------
// BACKGROUND WORK
// ---------------------------------------------------------------------------

var queueMu sync.Mutex
var queueValue float64

func drainQueue(n float64) {
	queueMu.Lock()
	defer queueMu.Unlock()
	queueValue -= n
	if queueValue < 0 {
		queueValue = 0
	}
	queueDepth.Set(queueValue)
}

func addQueue(n float64) {
	queueMu.Lock()
	defer queueMu.Unlock()
	queueValue += n
	queueDepth.Set(queueValue)
}

// runQueueSimulator keeps queue_depth moving so the dashboards are not flat.
// Under normal conditions the queue drains; while errors are being injected it
// grows, which is exactly the "leading indicator" behaviour the
// QueueDepthGrowing alert is designed to catch.
func runQueueSimulator(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_, _, errorPct := chaos.snapshot()
			if errorPct > 0 {
				addQueue(float64(errorPct) / 10.0)
			} else {
				drainQueue(2)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// SMALL HELPERS
// ---------------------------------------------------------------------------

func getenv(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func getenvFloat(key string, fallback float64) float64 {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return fallback
}

func getenvBool(key string, fallback bool) bool {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return fallback
}

func queryInt(r *http.Request, key string, fallback int) int {
	if v := r.URL.Query().Get(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

func clampPercent(v int) int {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

func randomDuration(min, max time.Duration) time.Duration {
	if max <= min {
		return min
	}
	return min + time.Duration(rand.Int64N(int64(max-min)))
}

func round2(f float64) float64 {
	return float64(int64(f*100+0.5)) / 100
}

// ---------------------------------------------------------------------------
// WIRING
// ---------------------------------------------------------------------------

// newMux builds the routing table. Split out from main() so that main_test.go
// can exercise the real handler chain rather than a hand-rolled stand-in.
func newMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)

	// promhttp.Handler() exposes everything registered with the default
	// registry: our custom metrics plus the free go_* (GC, goroutines, heap) and
	// process_* (fds, CPU, RSS) collectors.
	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/api/orders", handleOrders)
	mux.HandleFunc("/api/checkout", handleCheckout)

	// Chaos endpoints are only routed when explicitly enabled. Returning 404
	// rather than 403 when disabled means they do not even advertise their
	// existence in a non-demo deployment.
	if chaosEnabled {
		mux.HandleFunc("/chaos/latency", handleChaosLatency)
		mux.HandleFunc("/chaos/errors", handleChaosErrors)
		mux.HandleFunc("/chaos/leak", handleChaosLeak)
		mux.HandleFunc("/chaos/cpu", handleChaosCPU)
		mux.HandleFunc("/chaos/reset", handleChaosReset)
	}

	return mux
}

func main() {
	chaosEnabled = getenvBool("CHAOS_ENABLED", false)
	addr := ":" + getenv("PORT", "8080")

	if getenvBool("LOG_DEBUG", false) {
		logger = newLogger(slog.LevelDebug)
	}
	slog.SetDefault(logger)

	// Publish build info exactly once. The value is meaningless; the labels are
	// the payload.
	appBuildInfo.WithLabelValues(version, commit, runtime.Version()).Set(1)

	// Root context, cancelled on SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// --- Tracing ----------------------------------------------------------
	// A failure to reach Tempo must NOT stop the service from serving traffic.
	// Telemetry is important; it is not more important than the product.
	shutdownTracing, err := initTracing(ctx)
	if err != nil {
		logger.Error("tracing disabled: could not initialise OTLP exporter",
			slog.String("error", err.Error()))
		shutdownTracing = func(context.Context) error { return nil }
	} else {
		logger.Info("tracing initialised",
			slog.String("endpoint", getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "tempo.monitoring.svc.cluster.local:4317")))
	}

	go runQueueSimulator(ctx)

	// otelhttp wraps the whole mux: it extracts any inbound `traceparent`
	// header, starts a server span, and puts it in the request context — which
	// is what makes trace.SpanContextFromContext work inside traceHandler and
	// therefore what puts trace_id into every log line.
	//
	// Order matters: instrument() is OUTSIDE otelhttp so that the Prometheus
	// histogram measures the same wall time the span records.
	handler := instrument(
		otelhttp.NewHandler(newMux(), "http.server",
			otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
				// Span names must be low cardinality for the same reason labels
				// must be: Tempo's metrics-generator turns them into metrics.
				return r.Method + " " + routeLabel(r.URL.Path)
			}),
			// Never trace the scrape endpoint or the probes: they are high
			// frequency, carry no information, and would drown the real traffic.
			otelhttp.WithFilter(func(r *http.Request) bool {
				p := r.URL.Path
				return p != "/metrics" && p != "/healthz" && p != "/readyz"
			}),
		),
	)

	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		logger.Info("orders-api listening",
			slog.String("addr", addr),
			slog.String("version", version),
			slog.String("commit", commit),
			slog.Bool("chaos_enabled", chaosEnabled),
		)
		ready.Store(true)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http server failed", slog.String("error", err.Error()))
			os.Exit(1)
		}
	}()

	<-ctx.Done()

	// --- Graceful shutdown ------------------------------------------------
	logger.Info("shutdown signal received, draining")

	// 1. Fail readiness first. kube-proxy / the Endpoints controller need a few
	//    seconds to stop sending us new connections. Skipping this step is the
	//    usual cause of "we get a burst of 502s on every deploy".
	ready.Store(false)
	time.Sleep(time.Duration(getenvFloat("DRAIN_SECONDS", 5)) * time.Second)

	// 2. Stop accepting, finish in-flight requests.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", slog.String("error", err.Error()))
	}

	// 3. Flush buffered spans LAST, once no new ones can be created. Without
	//    this the final seconds of trace data — usually the interesting part —
	//    die with the process.
	if err := shutdownTracing(shutdownCtx); err != nil {
		logger.Error("trace flush failed", slog.String("error", err.Error()))
	}

	logger.Info("shutdown complete")
}

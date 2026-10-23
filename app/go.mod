// Module for the "orders-api" demo service.
//
// This service is deliberately small but instrumented the way a real production
// service should be:
//   - Prometheus metrics  (RED + business metrics)  -> scraped by Prometheus
//   - OpenTelemetry traces (OTLP/gRPC)              -> exported to Tempo
//   - Structured JSON logs carrying trace_id        -> shipped by Promtail to Loki
//
// The trace_id in the logs is what makes the Loki <-> Tempo correlation in
// Grafana work. See stack/grafana/datasources/datasources.yaml.
module github.com/fakhfakhahmed/k8s-observability-stack/app

go 1.23

require (
	// Prometheus instrumentation library. `promauto` registers collectors with
	// the default registry so `promhttp.Handler()` exposes them on /metrics,
	// along with the free go_* and process_* runtime metrics.
	github.com/prometheus/client_golang v1.20.5

	// OpenTelemetry: API + SDK + the OTLP/gRPC span exporter that talks to Tempo.
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.56.0
	go.opentelemetry.io/otel v1.31.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.31.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.31.0
	go.opentelemetry.io/otel/sdk v1.31.0
	go.opentelemetry.io/otel/trace v1.31.0
	google.golang.org/grpc v1.67.1
)

require (
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cenkalti/backoff/v4 v4.3.0 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/felixge/httpsnoop v1.0.4 // indirect
	github.com/go-logr/logr v1.4.2 // indirect
	github.com/go-logr/stdr v1.2.2 // indirect
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.22.0 // indirect
	github.com/klauspost/compress v1.17.9 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/prometheus/client_model v0.6.1 // indirect
	github.com/prometheus/common v0.55.0 // indirect
	github.com/prometheus/procfs v0.15.1 // indirect
	go.opentelemetry.io/otel/metric v1.31.0 // indirect
	go.opentelemetry.io/proto/otlp v1.3.1 // indirect
	golang.org/x/net v0.30.0 // indirect
	golang.org/x/sys v0.26.0 // indirect
	golang.org/x/text v0.19.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20241015192408-796eee8c2d53 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20241015192408-796eee8c2d53 // indirect
	google.golang.org/protobuf v1.35.1 // indirect
)

# Grafana Cloud — Task Manager RED Dashboard (EKS / ingress-nginx v1.15.x)

## Data source
Prometheus (Grafana Cloud Mimir) — chau11ece.grafana.net

## Dashboard name
Task Manager RED — EKS (Day 45)

## Version note
ingress-nginx v1.15.1 removed the VTS-based `nginx_ingress_controller_requests` metric
(per-request with status labels). Available alternatives documented below.
This is a key production skill: always verify metric availability before writing PromQL.

---

## RED Dashboard Panels

### 1. Request Rate (req/s)
Uses the nginx process-level counter — total requests across all services.
```promql
rate(nginx_ingress_controller_nginx_process_requests_total[5m])
```
Type: Time series | Legend: Requests/s

For per-connection rate (proxy for throughput):
```promql
rate(nginx_ingress_controller_nginx_process_connections_total{state="handled"}[5m])
```

### 2. Error Rate — via Loki log query
The nginx access log records status codes. Use LogQL to count 4xx/5xx from the ingress log stream.

```logql
sum(rate({namespace="ingress-nginx"} |~ `" [45][0-9]{2} ` [5m])) by (namespace)
```
Type: Time series | Data source: **Loki**

To show error count as a panel stat:
```logql
count_over_time({namespace="ingress-nginx"} |~ `" [45][0-9]{2} ` [5m])
```

### 3. Latency — via Loki log parsing
The nginx access log includes request duration (field 10 in log line).
```logql
avg_over_time(
  {namespace="ingress-nginx"}
  | pattern `<_> - - [<_>] "<method> <path> <_>" <status> <_> "<_>" "<_>" <_> <duration> [<_>]`
  | unwrap duration [5m]
) by (status)
```
Type: Time series | Data source: **Loki**

### 4. Error Logs (raw)
```logql
{namespace="ingress-nginx"} |~ `" [45][0-9]{2} `
```
Type: Logs panel | Data source: **Loki**

### 5. Task Manager App Errors
```logql
{namespace="taskmanager"} |= "error"
```
Type: Logs panel | Data source: **Loki**

---

## Alternative: Enable OpenTelemetry Metrics (v1.15.x)
To restore per-request Prometheus metrics with status labels, upgrade ingress-nginx with:
```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.opentelemetry.enabled=true \
  --set controller.config.enable-opentelemetry="true"
```
This requires an OpenTelemetry collector — not configured in this training setup.

---

## Failure test (AC-08)

Generate traffic with 4xx errors:
```bash
NODE_IP="3.75.212.127"
# Normal requests (200s)
for i in $(seq 1 100); do curl -s -o /dev/null "http://${NODE_IP}:30080/"; done
# 404s — trigger error rate panel in Loki
for i in $(seq 1 50); do curl -s -o /dev/null "http://${NODE_IP}:30080/fail-$(date +%s%N)"; done
```

Expected: Error logs panel lights up with 404 entries.

---

## Why Loki for error rate?

In ingress-nginx v1.15.1, per-request status code metrics were moved out of Prometheus.
Using Loki (log-based) for error detection is the correct pattern when metric labels
are unavailable — this is how production systems combine Prometheus (for counters/histograms)
with Loki (for per-request details).

# AKS Envoy Data Transfer Observability — Implementation Guide

This guide provides an automated setup to capture, store, visualize, and audit inbound (External Gateway) and outbound (Egress Proxy) data transfer rates across your existing **AKS, VictoriaMetrics, Grafana, Graylog, and Rsyslog** stack.

---

## 1. Prerequisites & Required Parameters

Before running the deployment script, gather the following environment endpoints and credentials:

| Parameter | Description | Example |
| :--- | :--- | :--- |
| `ENVOY_EXTERNAL_URLS` | Comma-separated Prometheus admin endpoints for External Ingress Envoy | `http://envoy-ext-1.ingress:19001/stats/prometheus,http://envoy-ext-2.ingress:19001/stats/prometheus` |
| `ENVOY_EGRESS_URLS` | Comma-separated Prometheus admin endpoints for Outbound Egress Envoy | `http://envoy-egress-1.egress:19001/stats/prometheus` |
| `VM_WRITE_URL` | VictoriaMetrics remote-write endpoint (`vmagent` target) | `http://victoriametrics.monitoring:8428/api/v1/write` |
| `VM_QUERY_URL` | VictoriaMetrics Prometheus-compatible datasource URL for Grafana | `http://victoriametrics.monitoring:8428` |
| `VM_USER` / `VM_PASS` | Basic auth credentials for VictoriaMetrics (leave blank if unauthenticated) | `admin` / `********` |
| `GRAFANA_URL` | Base URL of your existing Grafana instance | `https://grafana.internal.corp` |
| `GRAFANA_USER` / `GRAFANA_PASS` | Grafana Admin username & password (or Service Account token) | `admin` / `********` |
| `GRAYLOG_HOST` / `GRAYLOG_PORT` | Graylog Syslog/GELF TCP input host and port for Rsyslog forwarding | `graylog.logging.svc.cluster.local` / `1514` |
| `AKS_NAMESPACE` | Kubernetes namespace where `vmagent` and Rsyslog DaemonSet will be deployed | `observability` |

---

## 2. Quick Start: Automated Setup Script

Save and execute the accompanying **`setup_envoy_observability.sh`** script. You can pass parameters via CLI flags or environment variables.

### Option A: Run via Command-Line Flags
```bash
chmod +x setup_envoy_observability.sh

./setup_envoy_observability.sh \
  --envoy-external-urls "http://10.240.1.15:19001/stats/prometheus,http://10.240.1.16:19001/stats/prometheus" \
  --envoy-egress-urls "http://10.240.2.20:19001/stats/prometheus" \
  --vm-write-url "http://victoriametrics.monitoring:8428/api/v1/write" \
  --vm-query-url "http://victoriametrics.monitoring:8428" \
  --vm-user "vmadmin" \
  --vm-pass "SuperSecretVM" \
  --grafana-url "https://grafana.example.com" \
  --grafana-user "admin" \
  --grafana-pass "SuperSecretGrafana" \
  --graylog-host "graylog.logging" \
  --graylog-port "1514" \
  --namespace "observability"
```

### Option B: Interactive Prompt Mode
Simply run `./setup_envoy_observability.sh` with no arguments, and the script will interactively prompt you for each URL and password securely (masking passwords).

---

## 3. What the Script Automates

1. **Kubernetes Secret & ConfigMap Generation (`vmagent`)**
   * Creates a Kubernetes `Secret` storing VictoriaMetrics basic auth credentials (if provided).
   * Generates a `vmagent` scrape configuration (`scrape.yml`) with two distinct jobs (`envoy-external-gateway` and `envoy-egress-proxy`) injecting `gateway_role="external"` and `gateway_role="egress"` labels.
   * Applies metric relabeling rules to drop high-cardinality unused Envoy histograms while preserving exact byte counters (`envoy_http_downstream_cx_*_bytes_total`, `envoy_cluster_upstream_cx_*_bytes_total`).
   * Deploys `vmagent` into your AKS cluster pointing to your existing VictoriaMetrics instance.

2. **Rsyslog DaemonSet Deployment (AKS Node Log Shipping to Graylog)**
   * Deploys an `rsyslog` ConfigMap and DaemonSet configured with `imfile` to tail `/var/log/containers/*envoy*.log`.
   * Configures disk-assisted LinkedList memory queues (`queue.type="LinkedList"`) to prevent log loss or node I/O spikes during heavy traffic bursts.
   * Forwards structured JSON logs directly to your Graylog TCP Syslog/GELF endpoint.

3. **Grafana Datasource & Dashboard Provisioning via API**
   * Registers (or updates) the **VictoriaMetrics** datasource in Grafana via `/api/datasources`.
   * Imports the complete **AKS Envoy Data Transfer & Bandwidth Observability** dashboard (`envoy_transfer_dashboard.json`) via `/api/dashboards/db`, pre-configured with:
     * **Inbound External Throughput (Mbps / Bytes/sec)**
     * **Outbound Egress Throughput (Mbps / Bytes/sec)**
     * **Cumulative 24h / 7d Data Volume (GB / TB)**
     * **Top Upstream Clusters & Services Driving Egress**
     * **Automated Threshold Alert Panel**

---

## 4. Required Envoy Proxy Configuration Snippet

Ensure your External and Egress Envoy proxies expose the admin stats endpoint and emit JSON access logs with byte counters. Add this snippet to your Envoy `HttpConnectionManager` config:

```yaml
access_log:
  - name: envoy.access_loggers.file
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
      path: /dev/stdout
      json_format:
        timestamp: "%START_TIME%"
        gateway_role: "%ENVIRONMENT(GATEWAY_ROLE)%"
        authority: "%REQ(:AUTHORITY)%"
        method: "%REQ(:METHOD)%"
        path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
        response_code: "%RESPONSE_CODE%"
        bytes_received: "%BYTES_RECEIVED%"
        bytes_sent: "%BYTES_SENT%"
        duration_ms: "%DURATION%"
        upstream_cluster: "%UPSTREAM_CLUSTER%"
        upstream_host: "%UPSTREAM_HOST%"
        downstream_remote_addr: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
```

---

## 5. Verification & Post-Setup Checks

1. **Check `vmagent` Targets:**
   ```bash
   kubectl -n observability port-forward deploy/vmagent-envoy 8429:8429
   # Open http://localhost:8429/targets to verify both external & egress Envoy targets are UP
   ```
2. **Verify Rsyslog Forwarding:**
   ```bash
   kubectl -n observability logs -l app=rsyslog-envoy-forwarder --tail=50
   ```
3. **Open Grafana Dashboard:**
   Log into your `GRAFANA_URL` and navigate to **Dashboards -> AKS Envoy Data Transfer & Bandwidth Observability**.

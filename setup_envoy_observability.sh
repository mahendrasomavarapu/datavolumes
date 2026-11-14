#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AKS Envoy Data Transfer Observability Setup Script
# Configures:
#   1. vmagent on AKS scraping External Ingress & Outbound Egress Envoy URLs
#   2. Remote-write to existing VictoriaMetrics (with optional Basic Auth)
#   3. Rsyslog DaemonSet on AKS forwarding Envoy JSON logs to Graylog
#   4. Grafana VictoriaMetrics Datasource + Bandwidth Dashboard via Grafana API
# ==============================================================================

NAMESPACE="${AKS_NAMESPACE:-observability}"
ENVOY_EXTERNAL_URLS="${ENVOY_EXTERNAL_URLS:-}"
ENVOY_EGRESS_URLS="${ENVOY_EGRESS_URLS:-}"
VM_WRITE_URL="${VM_WRITE_URL:-}"
VM_QUERY_URL="${VM_QUERY_URL:-}"
VM_USER="${VM_USER:-}"
VM_PASS="${VM_PASS:-}"
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_USER="${GRAFANA_USER:-}"
GRAFANA_PASS="${GRAFANA_PASS:-}"
GRAYLOG_HOST="${GRAYLOG_HOST:-}"
GRAYLOG_PORT="${GRAYLOG_PORT:-1514}"

print_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --envoy-external-urls   Comma-separated External Envoy Prometheus URLs (e.g., http://10.0.1.5:19001/stats/prometheus)
  --envoy-egress-urls     Comma-separated Egress Envoy Prometheus URLs (e.g., http://10.0.2.8:19001/stats/prometheus)
  --vm-write-url          VictoriaMetrics remote-write URL (e.g., http://vm:8428/api/v1/write)
  --vm-query-url          VictoriaMetrics query URL for Grafana (e.g., http://vm:8428)
  --vm-user               VictoriaMetrics Basic Auth username (optional)
  --vm-pass               VictoriaMetrics Basic Auth password (optional)
  --grafana-url           Grafana base URL (e.g., https://grafana.corp.internal)
  --grafana-user          Grafana Admin username
  --grafana-pass          Grafana Admin password
  --graylog-host          Graylog Syslog/GELF TCP host
  --graylog-port          Graylog Syslog/GELF TCP port (default: 1514)
  --namespace             AKS namespace to deploy collectors into (default: observability)
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --envoy-external-urls) ENVOY_EXTERNAL_URLS="$2"; shift 2 ;;
    --envoy-egress-urls)   ENVOY_EGRESS_URLS="$2"; shift 2 ;;
    --vm-write-url)        VM_WRITE_URL="$2"; shift 2 ;;
    --vm-query-url)        VM_QUERY_URL="$2"; shift 2 ;;
    --vm-user)             VM_USER="$2"; shift 2 ;;
    --vm-pass)             VM_PASS="$2"; shift 2 ;;
    --grafana-url)         GRAFANA_URL="$2"; shift 2 ;;
    --grafana-user)        GRAFANA_USER="$2"; shift 2 ;;
    --grafana-pass)        GRAFANA_PASS="$2"; shift 2 ;;
    --graylog-host)        GRAYLOG_HOST="$2"; shift 2 ;;
    --graylog-port)        GRAYLOG_PORT="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2"; shift 2 ;;
    -h|--help)             print_usage; exit 0 ;;
    *)                     echo "Unknown option: $1"; print_usage; exit 1 ;;
  esac
done

# Interactive fallback for missing required values
prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local is_secret="${3:-false}"
  if [[ -z "${!var_name}" ]]; then
    if [[ "$is_secret" == "true" ]]; then
      read -rsp "$prompt_text: " input_val
      echo ""
    else
      read -rp "$prompt_text: " input_val
    fi
    eval "$var_name=\"\$input_val\""
  fi
}

echo "=== AKS Envoy Data Transfer Observability Installer ==="
prompt_if_empty ENVOY_EXTERNAL_URLS "Enter External Envoy Prometheus URL(s) (comma-separated)"
prompt_if_empty ENVOY_EGRESS_URLS   "Enter Outbound Egress Envoy Prometheus URL(s) (comma-separated)"
prompt_if_empty VM_WRITE_URL        "Enter VictoriaMetrics Remote-Write URL (e.g. http://vm:8428/api/v1/write)"
prompt_if_empty VM_QUERY_URL        "Enter VictoriaMetrics Query URL (e.g. http://vm:8428)"
read -rp "Enter VictoriaMetrics Username (press Enter if none) [${VM_USER}]: " vm_u_in
VM_USER="${vm_u_in:-$VM_USER}"
if [[ -n "$VM_USER" && -z "$VM_PASS" ]]; then
  read -rsp "Enter VictoriaMetrics Password: " VM_PASS
  echo ""
fi
prompt_if_empty GRAFANA_URL         "Enter Grafana URL (e.g. https://grafana.internal)"
prompt_if_empty GRAFANA_USER        "Enter Grafana Admin Username"
prompt_if_empty GRAFANA_PASS        "Enter Grafana Admin Password" "true"
prompt_if_empty GRAYLOG_HOST        "Enter Graylog Syslog TCP Host (e.g. graylog.logging)"

# Validate prerequisites
for cmd in kubectl curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required CLI tool '$cmd' is not installed or not in PATH."
    exit 1
  fi
done

# Helper to parse URLs into scheme, host:port, and metrics_path
parse_envoy_targets() {
  local csv_urls="$1"
  local job_name="$2"
  local gateway_role="$3"
  local first_url
  first_url=$(echo "$csv_urls" | cut -d',' -f1 | xargs)

  local scheme="http"
  [[ "$first_url" == https://* ]] && scheme="https"

  local path
  path=$(echo "$first_url" | sed -E 's|^https?://[^/]+||')
  [[ -z "$path" ]] && path="/stats/prometheus"

  echo "  - job_name: '${job_name}'"
  echo "    scheme: '${scheme}'"
  echo "    metrics_path: '${path}'"
  echo "    scrape_interval: 15s"
  echo "    static_configs:"
  echo "      - targets:"
  IFS=',' read -ra URL_ARR <<< "$csv_urls"
  for u in "${URL_ARR[@]}"; do
    u_trimmed=$(echo "$u" | xargs)
    hostport=$(echo "$u_trimmed" | sed -E 's|^https?://||' | cut -d'/' -f1)
    echo "          - '${hostport}'"
  done
  echo "        labels:"
  echo "          gateway_role: '${gateway_role}'"
  echo "          cluster: 'aks-production'"
  echo "    metric_relabel_configs:"
  echo "      - source_labels: [__name__]"
  echo "        regex: '(envoy_http_downstream_cx_.*_bytes_total|envoy_cluster_upstream_cx_.*_bytes_total|envoy_http_downstream_rq_total|envoy_cluster_upstream_rq_total|envoy_server_live)'"
  echo "        action: keep"
}

echo "[1/4] Creating namespace '${NAMESPACE}' and VictoriaMetrics credentials..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

VM_AUTH_ARGS=""
if [[ -n "$VM_USER" ]]; then
  kubectl -n "${NAMESPACE}" create secret generic vm-remote-write-auth \
    --from-literal=username="${VM_USER}" \
    --from-literal=password="${VM_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
  VM_AUTH_ARGS='
            - -remoteWrite.basicAuth.username=$(VM_USER)
            - -remoteWrite.basicAuth.password=$(VM_PASS)'
fi

echo "[2/4] Generating vmagent ConfigMap and Deployment for Envoy scraping..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<EOF > "${TMP_DIR}/vmagent-scrape.yml"
global:
  scrape_interval: 15s

scrape_configs:
$(parse_envoy_targets "$ENVOY_EXTERNAL_URLS" "envoy-external-gateway" "external")
$(parse_envoy_targets "$ENVOY_EGRESS_URLS" "envoy-egress-proxy" "egress")
EOF

kubectl -n "${NAMESPACE}" create configmap vmagent-envoy-config \
  --from-file=scrape.yml="${TMP_DIR}/vmagent-scrape.yml" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vmagent-envoy
  labels:
    app: vmagent-envoy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vmagent-envoy
  template:
    metadata:
      labels:
        app: vmagent-envoy
    spec:
      containers:
        - name: vmagent
          image: victoriametrics/vmagent:v1.106.1
          args:
            - -promscrape.config=/etc/vmagent/scrape.yml
            - -remoteWrite.url=${VM_WRITE_URL}
            - -remoteWrite.tmpDataPath=/tmp/vmagent-remotewrite-data${VM_AUTH_ARGS}
          env:
            - name: VM_USER
              valueFrom:
                secretKeyRef:
                  name: vm-remote-write-auth
                  key: username
                  optional: true
            - name: VM_PASS
              valueFrom:
                secretKeyRef:
                  name: vm-remote-write-auth
                  key: password
                  optional: true
          ports:
            - containerPort: 8429
              name: http
          volumeMounts:
            - name: config
              mountPath: /etc/vmagent
      volumes:
        - name: config
          configMap:
            name: vmagent-envoy-config
EOF

echo "[3/4] Deploying Rsyslog DaemonSet on AKS to ship Envoy access logs to Graylog (${GRAYLOG_HOST}:${GRAYLOG_PORT})..."
cat <<EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rsyslog-envoy-config
data:
  rsyslog.conf: |
    module(load="imfile" PollingInterval="2")

    global(workDirectory="/var/spool/rsyslog")

    template(name="EnvoyGraylogTemplate" type="string"
      string="<%pri%>1 %timestamp:::date-rfc3339% %hostname% envoy-aks - - - %msg%\n"
    )

    input(type="imfile"
      File="/var/log/containers/*envoy*.log"
      Tag="envoy-access"
      Severity="info"
      Facility="local6"
      reopenOnTruncate="on"
    )

    if \$syslogtag == 'envoy-access' then {
      action(
        type="omfwd"
        target="${GRAYLOG_HOST}"
        port="${GRAYLOG_PORT}"
        protocol="tcp"
        template="EnvoyGraylogTemplate"
        queue.type="LinkedList"
        queue.filename="envoy_fwd_queue"
        queue.maxdiskspace="1g"
        queue.saveonshutdown="on"
        action.resumeRetryCount="-1"
      )
      stop
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: rsyslog-envoy-forwarder
  labels:
    app: rsyslog-envoy-forwarder
spec:
  selector:
    matchLabels:
      app: rsyslog-envoy-forwarder
  template:
    metadata:
      labels:
        app: rsyslog-envoy-forwarder
    spec:
      containers:
        - name: rsyslog
          image: rsyslog/syslog_appliance_alpine:latest
          volumeMounts:
            - name: rsyslog-conf
              mountPath: /etc/rsyslog.conf
              subPath: rsyslog.conf
            - name: varlogcontainers
              mountPath: /var/log/containers
              readOnly: true
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: spool
              mountPath: /var/spool/rsyslog
      volumes:
        - name: rsyslog-conf
          configMap:
            name: rsyslog-envoy-config
        - name: varlogcontainers
          hostPath:
            path: /var/log/containers
        - name: varlogpods
          hostPath:
            path: /var/log/pods
        - name: spool
          emptyDir: {}
EOF

echo "[4/4] Configuring VictoriaMetrics Datasource and Bandwidth Dashboard in Grafana (${GRAFANA_URL})..."
GRAFANA_CLEAN_URL="${GRAFANA_URL%/}"

# Create or update VictoriaMetrics Datasource
DS_PAYLOAD=$(jq -n \
  --arg url "$VM_QUERY_URL" \
  --arg user "$VM_USER" \
  --arg pass "$VM_PASS" \
  '{
    name: "VictoriaMetrics-Envoy",
    type: "prometheus",
    uid: "victoriametrics-envoy",
    url: $url,
    access: "proxy",
    basicAuth: ($user != ""),
    basicAuthUser: $user,
    secureJsonData: (if $pass != "" then {basicAuthPassword: $pass} else {} end),
    jsonData: {httpMethod: "POST", timeInterval: "15s"}
  }')

HTTP_CODE=$(curl -s -o "${TMP_DIR}/ds_resp.json" -w "%{http_code}" \
  -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "${GRAFANA_CLEAN_URL}/api/datasources" \
  -d "${DS_PAYLOAD}")

if [[ "$HTTP_CODE" == "409" ]]; then
  echo "  -> Datasource 'VictoriaMetrics-Envoy' already exists, updating..."
  curl -s -o /dev/null -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    -H "Content-Type: application/json" \
    -X PUT "${GRAFANA_CLEAN_URL}/api/datasources/uid/victoriametrics-envoy" \
    -d "${DS_PAYLOAD}"
elif [[ "$HTTP_CODE" != "200" ]]; then
  echo "  -> [WARN] Grafana Datasource API returned HTTP ${HTTP_CODE}: $(cat "${TMP_DIR}/ds_resp.json")"
else
  echo "  -> Datasource 'VictoriaMetrics-Envoy' created successfully."
fi

# Import Grafana Dashboard
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/envoy_transfer_dashboard.json" ]]; then
  DASH_RAW=$(sed 's/\${DS_VICTORIAMETRICS}/victoriametrics-envoy/g' "${SCRIPT_DIR}/envoy_transfer_dashboard.json")
else
  echo "[ERROR] envoy_transfer_dashboard.json not found in ${SCRIPT_DIR}."
  exit 1
fi

IMPORT_PAYLOAD=$(jq -n --argjson dash "$DASH_RAW" '{dashboard: $dash, overwrite: true, folderId: 0}')

DASH_CODE=$(curl -s -o "${TMP_DIR}/dash_resp.json" -w "%{http_code}" \
  -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "${GRAFANA_CLEAN_URL}/api/dashboards/db" \
  -d "${IMPORT_PAYLOAD}")

if [[ "$DASH_CODE" == "200" ]]; then
  DASH_URL=$(jq -r '.url' "${TMP_DIR}/dash_resp.json")
  echo "  -> Dashboard imported successfully: ${GRAFANA_CLEAN_URL}${DASH_URL}"
else
  echo "  -> [WARN] Grafana Dashboard API returned HTTP ${DASH_CODE}: $(cat "${TMP_DIR}/dash_resp.json")"
fi

echo ""
echo "=== Setup Complete! ==="
echo "1. vmagent deployed in namespace '${NAMESPACE}' scraping External & Egress Envoy targets."
echo "2. Rsyslog DaemonSet deployed in namespace '${NAMESPACE}' forwarding to ${GRAYLOG_HOST}:${GRAYLOG_PORT}."
echo "3. Grafana dashboard available at: ${GRAFANA_CLEAN_URL}/d/aks-envoy-transfer-v1"

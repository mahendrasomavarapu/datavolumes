#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${AKS_NAMESPACE:-envoy-observability}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
DRY_RUN=false

VM_CHART_VERSION="0.51.0"
GRAFANA_CHART_VERSION="10.5.15"
ENVOY_IMAGE="envoyproxy/envoy:v1.32.2"
BACKEND_IMAGE="hashicorp/http-echo:1.0.0"
VMAGENT_IMAGE="victoriametrics/vmagent:v1.156.0"

usage() {
  cat <<EOF
Usage: $0 [--namespace NAME] [--dry-run]

Installs a test Envoy ingress/egress pair, a sample HTTP upstream,
VictoriaMetrics Single, vmagent, and Grafana with the Envoy dashboard.

Options:
  --namespace NAME  Kubernetes namespace (default: envoy-observability)
  --dry-run         Render and validate Helm charts without changing the cluster
  -h, --help        Show this help

Optional environment:
  GRAFANA_ADMIN_PASSWORD  Set the Grafana admin password; otherwise retrieve it
                          from the grafana-admin Kubernetes Secret after install.
EOF
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --namespace)
      (($# >= 2)) || fail "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] &&
  ((${#NAMESPACE} <= 63)) || fail "Invalid Kubernetes namespace: $NAMESPACE"

for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command '$cmd' was not found."
done

if [[ "$DRY_RUN" != true && -z "$GRAFANA_ADMIN_PASSWORD" ]] &&
  ! kubectl get secret grafana-admin \
  --namespace "$NAMESPACE" >/dev/null 2>&1; then
  command -v openssl >/dev/null 2>&1 || fail "openssl is required to generate a Grafana password."
  GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

helm repo add vm https://victoriametrics.github.io/helm-charts/ --force-update >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts/ --force-update >/dev/null
helm repo update

cat >"$TMP_DIR/vm-values.yaml" <<'EOF'
server:
  retentionPeriod: 7d
  persistentVolume:
    enabled: true
    size: 5Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 768Mi
EOF

cat >"$TMP_DIR/grafana-values.yaml" <<EOF
admin:
  existingSecret: grafana-admin
service:
  type: ClusterIP
  port: 80
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    searchNamespace: ${NAMESPACE}
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        type: prometheus
        uid: victoriametrics-envoy
        access: proxy
        url: http://victoria-metrics-victoria-metrics-single-server:8428
        isDefault: true
        jsonData:
          timeInterval: 15s
resources:
  requests:
    cpu: 100m
    memory: 128Mi
EOF

if [[ "$DRY_RUN" == true ]]; then
  helm template victoria-metrics vm/victoria-metrics-single \
    --version "$VM_CHART_VERSION" --namespace "$NAMESPACE" \
    -f "$TMP_DIR/vm-values.yaml" >/dev/null
  helm template grafana grafana/grafana \
    --version "$GRAFANA_CHART_VERSION" --namespace "$NAMESPACE" \
    -f "$TMP_DIR/grafana-values.yaml" >/dev/null
  printf 'Helm templates rendered successfully for namespace %s.\n' "$NAMESPACE"
  exit 0
fi

kubectl cluster-info >/dev/null 2>&1 ||
  fail "Cannot reach the current Kubernetes context. Start/select the target cluster and retry."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "$GRAFANA_ADMIN_PASSWORD" ]]; then
  umask 077
  printf 'admin-user=admin\nadmin-password=%s\n' "$GRAFANA_ADMIN_PASSWORD" >"$TMP_DIR/grafana-admin.env"
  kubectl create secret generic grafana-admin \
    --namespace "$NAMESPACE" \
    --from-env-file="$TMP_DIR/grafana-admin.env" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

printf '[1/5] Installing VictoriaMetrics Single...\n'
helm upgrade --install victoria-metrics vm/victoria-metrics-single \
  --version "$VM_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$TMP_DIR/vm-values.yaml" \
  --wait --timeout 10m

printf '[2/5] Creating the sample upstream and Envoy configuration...\n'
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-config
  namespace: ${NAMESPACE}
data:
  envoy.yaml: |
    admin:
      access_log_path: /dev/null
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 9901
    static_resources:
      listeners:
        - name: listener_http
          address:
            socket_address:
              address: 0.0.0.0
              port_value: 10000
          filter_chains:
            - filters:
                - name: envoy.filters.network.http_connection_manager
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                    stat_prefix: ingress_http
                    route_config:
                      name: local_route
                      virtual_hosts:
                        - name: sample_backend
                          domains: ["*"]
                          routes:
                            - match:
                                prefix: /
                              route:
                                cluster: sample_backend
                    http_filters:
                      - name: envoy.filters.http.router
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
      clusters:
        - name: sample_backend
          connect_timeout: 2s
          type: STRICT_DNS
          lb_policy: ROUND_ROBIN
          load_assignment:
            cluster_name: sample_backend
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address:
                          address: sample-backend.${NAMESPACE}.svc.cluster.local
                          port_value: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-backend
  namespace: ${NAMESPACE}
  labels:
    app: sample-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-backend
  template:
    metadata:
      labels:
        app: sample-backend
    spec:
      containers:
        - name: http-echo
          image: ${BACKEND_IMAGE}
          args: ["-listen=:5678", "-text=Hello from the Envoy sample upstream"]
          ports:
            - name: http
              containerPort: 5678
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: sample-backend
  namespace: ${NAMESPACE}
spec:
  selector:
    app: sample-backend
  ports:
    - name: http
      port: 5678
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: envoy-external
  namespace: ${NAMESPACE}
  labels:
    app: envoy-external
spec:
  replicas: 1
  selector:
    matchLabels:
      app: envoy-external
  template:
    metadata:
      labels:
        app: envoy-external
    spec:
      containers:
        - name: envoy
          image: ${ENVOY_IMAGE}
          args: ["-c", "/etc/envoy/envoy.yaml", "--log-level", "info"]
          ports:
            - name: http
              containerPort: 10000
            - name: admin
              containerPort: 9901
          readinessProbe:
            httpGet:
              path: /ready
              port: admin
            initialDelaySeconds: 2
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/envoy
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: envoy-config
---
apiVersion: v1
kind: Service
metadata:
  name: envoy-external
  namespace: ${NAMESPACE}
spec:
  selector:
    app: envoy-external
  ports:
    - name: http
      port: 10000
      targetPort: http
    - name: admin
      port: 9901
      targetPort: admin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: envoy-egress
  namespace: ${NAMESPACE}
  labels:
    app: envoy-egress
spec:
  replicas: 1
  selector:
    matchLabels:
      app: envoy-egress
  template:
    metadata:
      labels:
        app: envoy-egress
    spec:
      containers:
        - name: envoy
          image: ${ENVOY_IMAGE}
          args: ["-c", "/etc/envoy/envoy.yaml", "--log-level", "info"]
          ports:
            - name: http
              containerPort: 10000
            - name: admin
              containerPort: 9901
          readinessProbe:
            httpGet:
              path: /ready
              port: admin
            initialDelaySeconds: 2
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/envoy
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: envoy-config
---
apiVersion: v1
kind: Service
metadata:
  name: envoy-egress
  namespace: ${NAMESPACE}
spec:
  selector:
    app: envoy-egress
  ports:
    - name: http
      port: 10000
      targetPort: http
    - name: admin
      port: 9901
      targetPort: admin
EOF

printf '[3/5] Installing vmagent...\n'
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vmagent-envoy-config
  namespace: ${NAMESPACE}
data:
  scrape.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: envoy-external
        metrics_path: /stats/prometheus
        static_configs:
          - targets: ["envoy-external.${NAMESPACE}.svc.cluster.local:9901"]
            labels:
              gateway_role: external
              cluster: kubemarine-test
      - job_name: envoy-egress
        metrics_path: /stats/prometheus
        static_configs:
          - targets: ["envoy-egress.${NAMESPACE}.svc.cluster.local:9901"]
            labels:
              gateway_role: egress
              cluster: kubemarine-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vmagent-envoy
  namespace: ${NAMESPACE}
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
          image: ${VMAGENT_IMAGE}
          args:
            - -promscrape.config=/etc/vmagent/scrape.yml
            - -remoteWrite.url=http://victoria-metrics-victoria-metrics-single-server:8428/api/v1/write
            - -remoteWrite.tmpDataPath=/tmp/vmagent-remotewrite-data
          ports:
            - name: http
              containerPort: 8429
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
          volumeMounts:
            - name: config
              mountPath: /etc/vmagent
              readOnly: true
            - name: data
              mountPath: /tmp/vmagent-remotewrite-data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: vmagent-envoy-config
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: vmagent-envoy
  namespace: ${NAMESPACE}
spec:
  selector:
    app: vmagent-envoy
  ports:
    - name: http
      port: 8429
      targetPort: http
EOF

printf '[4/5] Installing Grafana and provisioning the dashboard...\n'
helm upgrade --install grafana grafana/grafana \
  --version "$GRAFANA_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$TMP_DIR/grafana-values.yaml" \
  --wait --timeout 10m

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/envoy_transfer_dashboard.json" ]] ||
  fail "Missing dashboard file: $SCRIPT_DIR/envoy_transfer_dashboard.json"
sed 's/\${DS_VICTORIAMETRICS}/victoriametrics-envoy/g' \
  "$SCRIPT_DIR/envoy_transfer_dashboard.json" >"$TMP_DIR/dashboard.json"
kubectl create configmap envoy-transfer-dashboard \
  --namespace "$NAMESPACE" \
  --from-file=dashboard.json="$TMP_DIR/dashboard.json" \
  --dry-run=client -o yaml >"$TMP_DIR/dashboard-configmap.yaml"
kubectl label --local -f "$TMP_DIR/dashboard-configmap.yaml" \
  grafana_dashboard=1 -o yaml | kubectl apply -f -

printf '[5/5] Waiting for workloads...\n'
kubectl rollout status deployment/sample-backend --namespace "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/envoy-external --namespace "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/envoy-egress --namespace "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/vmagent-envoy --namespace "$NAMESPACE" --timeout=5m
kubectl rollout status statefulset/victoria-metrics-victoria-metrics-single-server \
  --namespace "$NAMESPACE" --timeout=10m
kubectl rollout status deployment/grafana --namespace "$NAMESPACE" --timeout=10m

cat <<EOF

Installation complete in namespace '${NAMESPACE}'.

Run each port-forward command in its own terminal, then open the URL:

Grafana:
  kubectl -n ${NAMESPACE} port-forward svc/grafana 3000:80
  http://localhost:3000/d/aks-envoy-transfer-v1
  Username: admin
  Password: kubectl -n ${NAMESPACE} get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d

VictoriaMetrics:
  kubectl -n ${NAMESPACE} port-forward svc/victoria-metrics-victoria-metrics-single-server 8428:8428
  http://localhost:8428/vmui/

Envoy sample upstream:
  kubectl -n ${NAMESPACE} port-forward svc/envoy-external 8080:10000
  http://localhost:8080/

Envoy metrics:
  kubectl -n ${NAMESPACE} port-forward svc/envoy-external 9901:9901
  http://localhost:9901/stats/prometheus

vmagent target status:
  kubectl -n ${NAMESPACE} port-forward svc/vmagent-envoy 8429:8429
  http://localhost:8429/targets
EOF

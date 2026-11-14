# Envoy Observability Stack

This guide documents the implementation in `setup_envoy_observability.sh`.
The installer deploys a self-contained metrics demo into a dedicated Kubernetes
namespace: two static-config Envoy proxies, a sample HTTP upstream, an
in-cluster traffic generator, VictoriaMetrics Single, `vmagent`, and Grafana
with the provisioned dashboard.

The script uses `kubectl` and Helm against the **current kubectl context**. It
does not call Kubemarine itself. It was installed and verified on the local
Minikube cluster; it can target a reachable Kubemarine-managed Kubernetes
cluster whose version and storage meet the prerequisites below.
The deployment client is only used to submit Kubernetes resources; Envoy,
traffic generation, metrics collection/storage, and Grafana run as Pods in the
cluster. The installer does not run those application services on the client.

## What is deployed

| Component | Kubernetes resource / image | Purpose |
|---|---|---|
| Sample backend | `sample-backend` Deployment and Service; `hashicorp/http-echo:1.0.0` | Returns a fixed response so test requests generate traffic. |
| External test Envoy | `envoy-external` Deployment and ClusterIP Service; `envoyproxy/envoy:v1.32.2` | Listens on HTTP port 10000 and routes requests to the sample backend. Exposes admin metrics on port 9901. |
| Egress test Envoy | `envoy-egress` Deployment and ClusterIP Service; same Envoy image/config | A second independently scraped test proxy, labelled as the egress role. |
| Demo traffic generator | `envoy-demo-traffic` Deployment; `curlimages/curl:8.12.1` | Sends requests to both Envoy Services every two seconds from inside Kubernetes so the dashboard has sample traffic without a local client. |
| VictoriaMetrics | Helm release `victoria-metrics`, chart `vm/victoria-metrics-single` version `0.51.0` (app `v1.156.0`) | Stores metrics for seven days on a 5 GiB PVC. |
| vmagent | `vmagent-envoy` Deployment and ClusterIP Service; `victoriametrics/vmagent:v1.156.0` | Scrapes both Envoy admin endpoints every 15 seconds and remote-writes metrics to VictoriaMetrics. |
| Grafana | `grafana` Deployment and ClusterIP Service; `grafana/grafana:12.3.1` | Reads VictoriaMetrics and loads the dashboard and datasource from Kubernetes ConfigMaps. Grafana data is stored on a 2 GiB PVC. |

Each workload has one replica. The configured resources are:

| Workload | CPU request | Memory request | Memory limit |
|---|---:|---:|---:|
| Sample backend | 25m | 32 MiB | 64 MiB |
| Each Envoy | 50m | 64 MiB | 256 MiB |
| vmagent | 50m | 64 MiB | 256 MiB |
| VictoriaMetrics | 100m | 256 MiB | 768 MiB |
| Grafana | 100m | 128 MiB | 512 MiB |

No CPU limits are set by this demo.

### Data flow

1. `envoy-demo-traffic` sends requests to both Envoy Services on port `10000`.
   Each Envoy routes requests to `sample-backend:5678`.
2. `vmagent` scrapes
   `envoy-external:9901/stats/prometheus` and
   `envoy-egress:9901/stats/prometheus`.
3. Scrape target labels distinguish the two sets of metrics:
   `gateway_role="external"` or `gateway_role="egress"`, and
   `cluster="kubemarine-test"`.
4. vmagent remote-writes the metrics to VictoriaMetrics at
   `http://victoria-metrics-victoria-metrics-single-server:8428/api/v1/write`.
5. Grafana's provisioned VictoriaMetrics datasource queries that service.
   The dashboard is mounted from the `envoy-transfer-dashboard` ConfigMap.

The dashboard contains inbound and outbound throughput time series, four
24-hour byte-volume stat panels, and a top-10 egress-cluster throughput panel.
Its queries use Envoy downstream and upstream connection byte counters. It does
not configure alert rules.

## Prerequisites and cluster selection

- `kubectl`, Helm 3, and `jq` installed locally. `openssl` is required when the
  installer needs to generate a Grafana password.
- A reachable Kubernetes cluster selected as the current context:

  ```bash
  kubectl config current-context
  kubectl cluster-info
  ```

- Kubernetes 1.25 or newer for the pinned VictoriaMetrics chart.
- A default StorageClass capable of provisioning ReadWriteOnce PVCs: 5 GiB
  for VictoriaMetrics and 2 GiB for Grafana.
- Access to pull the pinned container images and the VictoriaMetrics Helm
  chart.

Choose the target context before running the installer. It creates resources
only in the requested namespace; it does not switch contexts or configure a
Kubemarine cluster.

## Install or update

From the repository directory:

```bash
chmod +x setup_envoy_observability.sh
./setup_envoy_observability.sh --namespace envoy-observability
```

The namespace defaults to `envoy-observability`; it can also be selected with
the `NAMESPACE` environment variable. Namespace names must be valid Kubernetes
DNS labels.

The installer adds/updates the VictoriaMetrics Helm repository, creates the
namespace, creates or reuses the Grafana admin Secret, installs VictoriaMetrics,
applies the Envoy/backend/vmagent/Grafana resources, and waits for each workload
to become ready. Re-running the command applies the same configuration and
upgrades the Helm release.

To supply a known Grafana admin password without putting it in shell history or
the process argument list:

```bash
read -s GRAFANA_ADMIN_PASSWORD
export GRAFANA_ADMIN_PASSWORD
./setup_envoy_observability.sh --namespace envoy-observability
unset GRAFANA_ADMIN_PASSWORD
```

If `GRAFANA_ADMIN_PASSWORD` is not set and the namespace has no
`grafana-admin` Secret, the installer generates a password using OpenSSL. If
the Secret already exists and no password is supplied, the existing Secret is
left unchanged. The Secret contains `admin-user` and `admin-password`.

Retrieve the generated/current password on macOS:

```bash
kubectl -n envoy-observability get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -D
```

On GNU/Linux, use `base64 -d` instead of `base64 -D`.

### Render-only check

This validates the pinned VictoriaMetrics chart template and dashboard JSON;
it does not contact the Kubernetes API or apply resources:

```bash
./setup_envoy_observability.sh --namespace envoy-observability --dry-run
```

## Access the services

All Services are `ClusterIP`; the installer does not start local application
processes or port-forwards, or create NodePorts or public endpoints. Use these
service addresses from an existing in-cluster client:

| Service | In-cluster URL |
|---|---|
| Grafana | `http://grafana.envoy-observability.svc.cluster.local/` |
| Dashboard | `http://grafana.envoy-observability.svc.cluster.local/d/aks-envoy-transfer-v1` |
| VictoriaMetrics UI | `http://victoria-metrics-victoria-metrics-single-server.envoy-observability.svc.cluster.local:8428/vmui/` |
| External test proxy | `http://envoy-external.envoy-observability.svc.cluster.local:10000/` |
| Egress test proxy | `http://envoy-egress.envoy-observability.svc.cluster.local:10000/` |
| External Envoy metrics | `http://envoy-external.envoy-observability.svc.cluster.local:9901/stats/prometheus` |
| vmagent targets | `http://vmagent-envoy.envoy-observability.svc.cluster.local:8429/targets` |

These are Kubernetes-internal DNS names, not links resolvable by a browser
outside the cluster. To view Grafana externally, expose only the Grafana
Service through your organization's existing internal Ingress or gateway, with
its normal authentication and TLS policy. Do not expose the Envoy admin port.
Log into Grafana with username `admin` and the password retrieved above. The
dashboard UID is `aks-envoy-transfer-v1`; its displayed title is
**Envoy Data Transfer & Bandwidth Observability**.

## Sample traffic

The `envoy-demo-traffic` Deployment continuously calls both Envoy Services
from inside the cluster. It starts with the installation and provides sample
traffic for the dashboard; no local curl process or port-forward is needed.
Because the scrape interval is 15 seconds, allow at least one interval for
metrics to appear.

Check workload and storage status:

```bash
kubectl -n envoy-observability get pods,services,pvc
kubectl -n envoy-observability get deployments,statefulsets
```

Check vmagent's active targets and logs from your Kubernetes administration
environment or an existing in-cluster diagnostic client:

```bash
kubectl -n envoy-observability get pods
kubectl -n envoy-observability logs deployment/vmagent-envoy
```

From an existing in-cluster diagnostic client, query a stored Envoy counter
using the VictoriaMetrics service DNS:

```bash
curl -fsS \
  'http://victoria-metrics-victoria-metrics-single-server.envoy-observability.svc.cluster.local:8428/api/v1/query?query=envoy_http_downstream_cx_rx_bytes_total'
```

The result should include samples with `gateway_role` set to `external` and
`egress`.

## Operations and limitations

- Envoy admin metrics are available on an in-cluster ClusterIP Service on port
  9901. They are not exposed publicly. Port-forward only to inspect them
  locally.
- Both demo Envoy Deployments use the same static configuration and route to
  the sample backend. The “egress” proxy is a metrics demonstration, not a
  production outbound firewall/proxy. The “external” proxy is not configured
  with an external LoadBalancer, Ingress, TLS, or production access controls.
- `envoy-demo-traffic` generates synthetic test requests continuously. Remove
  or scale down this Deployment before using the namespace for real traffic.
- Before production use, replace the test routing and upstream, configure the
  required gateway/network exposure, review Envoy admin access, resource
  requests/limits, storage sizing, authentication, and network policies.
- This implementation collects metrics only. It does not configure
  Graylog/Rsyslog, node log shipping, Envoy JSON access logs, or Grafana alert
  rules.
- VictoriaMetrics retains seven days of data. Both VictoriaMetrics and Grafana
  use PVCs, so persistent storage is required.
- To inspect application logs:

  ```bash
  kubectl -n envoy-observability logs deployment/envoy-external
  kubectl -n envoy-observability logs deployment/envoy-egress
  kubectl -n envoy-observability logs deployment/vmagent-envoy
  kubectl -n envoy-observability logs deployment/grafana
  ```

- Deleting the namespace removes the namespace's workloads, Secrets,
  ConfigMaps, and PVCs. Depending on the StorageClass reclaim policy, deleting
  PVCs can also delete the backing data. Check the PVCs and backups before
  cleanup.

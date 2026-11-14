# Envoy Observability Stack for Kubemarine

The setup script installs a disposable Envoy test pair, a sample HTTP upstream,
VictoriaMetrics Single, `vmagent`, and Grafana into a dedicated Kubernetes
namespace. It provisions the included bandwidth dashboard and retains
VictoriaMetrics data on a 5 GiB persistent volume.

## Prerequisites

- A reachable Kubernetes cluster in the current `kubectl` context
- `kubectl`, Helm 3, and OpenSSL
- A default StorageClass for VictoriaMetrics persistence

The script pins the VictoriaMetrics and Grafana chart versions. Envoy,
`vmagent`, and the sample upstream use pinned container image tags.

## Install

```bash
chmod +x setup_envoy_observability.sh
./setup_envoy_observability.sh --namespace envoy-observability
```

To render both Helm charts without installing resources:

```bash
./setup_envoy_observability.sh --namespace envoy-observability --dry-run
```

To set a known Grafana admin password, provide it through the environment
instead of placing it in the command line:

```bash
read -s GRAFANA_ADMIN_PASSWORD
export GRAFANA_ADMIN_PASSWORD
./setup_envoy_observability.sh --namespace envoy-observability
unset GRAFANA_ADMIN_PASSWORD
```

If no password is supplied and the Secret does not already exist, the script
generates one. The password is stored in the `grafana-admin` Secret; retrieve it
with:

```bash
kubectl -n envoy-observability get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

## Check the installation

Each port-forward command must run in a separate terminal:

| Component | Port-forward | URL |
|---|---|---|
| Grafana dashboard | `kubectl -n envoy-observability port-forward svc/grafana 3000:80` | <http://localhost:3000/d/aks-envoy-transfer-v1> |
| VictoriaMetrics UI | `kubectl -n envoy-observability port-forward svc/victoria-metrics-victoria-metrics-single-server 8428:8428` | <http://localhost:8428/vmui/> |
| Envoy sample upstream | `kubectl -n envoy-observability port-forward svc/envoy-external 8080:10000` | <http://localhost:8080/> |
| Envoy Prometheus metrics | `kubectl -n envoy-observability port-forward svc/envoy-external 9901:9901` | <http://localhost:9901/stats/prometheus> |
| vmagent scrape targets | `kubectl -n envoy-observability port-forward svc/vmagent-envoy 8429:8429` | <http://localhost:8429/targets> |

Make requests to the sample upstream to populate the throughput panels. The
dashboard collects both `external` and `egress` labels from the two Envoy test
deployments.

## Notes

- The Envoy admin port is a ClusterIP service port, not exposed externally.
- The test Envoys both route to the in-cluster sample HTTP upstream; replace
  their configuration before using this as a production gateway.
- This script no longer configures Graylog or forwards node logs. It installs
  the metrics and dashboard stack requested for the test environment.
- To inspect resources and logs:

  ```bash
  kubectl -n envoy-observability get deployments,statefulsets,services,pvc
  kubectl -n envoy-observability get pods
  kubectl -n envoy-observability logs deploy/vmagent-envoy
  ```

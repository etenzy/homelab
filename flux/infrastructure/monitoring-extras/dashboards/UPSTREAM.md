# Additional Grafana dashboards

These JSON files are provisioned by standard Kustomize `configMapGenerator`
entries in the parent component. Grafana's existing dashboard sidecar discovers
their `grafana_dashboard: "1"` label across namespaces. No additional controller,
Grafana plugin, custom monitoring API or startup download is required.

## Sources and local changes

| Dashboard | Pinned source | License |
| --- | --- | --- |
| Flux Performance | [Flux Operator v0.62.1](https://github.com/controlplaneio-fluxcd/flux-operator/blob/48e2cd76c475be87a1c9a8bd83fe07e064abd725/config/monitoring/dashboards/flux-performance.json) | [AGPL-3.0](flux-operator-LICENSE) |
| Flux Kubernetes API Performance | [Flux Operator v0.62.1](https://github.com/controlplaneio-fluxcd/flux-operator/blob/48e2cd76c475be87a1c9a8bd83fe07e064abd725/config/monitoring/dashboards/flux-k8s-api-performance.json) | [AGPL-3.0](flux-operator-LICENSE) |
| Cert Manager / Overview | [cert-manager-mixin](https://github.com/imusmanmalik/cert-manager-mixin/blob/a5f74ad04be4ee8fc007a10a918b3c48154c7e55/dashboards/cert-manager-overview.json) | [Apache-2.0](cert-manager-mixin-LICENSE) |
| LVM Pool | [OpenEBS monitoring](https://github.com/openebs/monitoring/blob/39140e75d10ff53a89b1eaac2a32ffbca2dff38c/deploy/charts/dashboards/lvmLocalPV/lvmlocalpv-pool.json) | [Apache-2.0](openebs-monitoring-LICENSE) |

The Flux files are reformatted JSON with unchanged content. They use metrics
already scraped from Flux Operator, Flux controllers and kube-prometheus-stack.
Resource information is refreshed on the operator's existing reporting interval;
this change does not increase that interval or add kube-state-metrics CRD watches.

The cert-manager dashboard is the community mixin linked from the
[official cert-manager documentation](https://cert-manager.io/docs/devops-tips/prometheus-metrics/#monitoring-mixin).
Its `.json` source contains Jsonnet and must be rendered before Grafana imports it.
It was rendered with go-jsonnet v0.21.0 and the pinned repository's
`config.libsonnet`, using its single-cluster defaults:

```bash
jsonnet -e '(import "dashboards/cert-manager-overview.json") + { _config:: (import "config.libsonnet")._config }' \
  -o cert-manager-overview-rendered.json
```

Run that command from a checkout of the pinned mixin commit. After rendering,
the local JSON replaces the four legacy kube-state-metrics CPU/memory resource
families with `kube_pod_container_resource_limits` and
`kube_pod_container_resource_requests`, selecting `resource="cpu"` or
`resource="memory"`. The unused, unnamed hidden cluster variable is removed.
Certificate, reconciliation and ACME queries are retained.

The OpenEBS dashboard's instance variable queries
`label_values(lvm_vg_total_size_bytes, instance)` directly, with no address-stripping
regex. The LVM plugin's Pod IP targets differ from node-exporter's targets, so
selecting node-exporter addresses would produce empty panels. The label is
`LVM instance`; the default datasource UID is `prometheus`. VG/LV metric names
match the pinned LVM v1.10.1 collectors. Thin-pool panels require actual thin pools;
the supplied `high-io` class uses thick volumes, so those panels can be empty.
Eight upstream I/O panels and their two section headers are omitted: they join
node-exporter disk series to LVM plugin series by incompatible scrape instances.
The remaining layout is compacted. Use the existing node disk dashboards for
host I/O and Kubernetes persistent-volume dashboards for filesystem usage.

All four dashboards retain datasource variables and use built-in Grafana panels.
No Loki, Thanos, Mimir, external storage exporter or new recording rule is needed.

## Original source SHA256

```text
186712861adae1157c24e3f6bb23b22f9a604a8201ce21934c73ccbc52b9d8c7  flux-performance.json
406bbe1cbafb1a6ed873f90fab9bf4e63cdedc7cf9578c1135a487d0e9ce58fd  flux-k8s-api-performance.json
59f09f9e583f8d7cef90dac92a98b183e1212484a9bab5ceb87dcb0bb11a04f2  cert-manager-overview.json (Jsonnet source)
8440ca4086c3d31c636b4e65f0aa78b4eac49fe56f69769422157f4c80b4dbb7  config.libsonnet (cert-manager mixin)
dfad66ffc7285cd662672133d4721532c52d2bee2ed5d4fcd2753c52b91e3a5a  lvmlocalpv-pool.json
```

## Coverage without a dedicated upstream dashboard

Metrics Server has no bundled dashboard in chart 3.14.0 / app v0.9.0. Use the
stack's Kubernetes workload/pod dashboards with namespace `kube-system` and its
Metrics Server deployment for CPU, memory, restarts and availability. Check its
ServiceMonitor target in Prometheus for scrape health. The same workload views
cover the certificate approver and CSI controller Pods.

The prometheus-operator-crds chart contains schemas only and has no runtime
process or metrics endpoint. Its operator is covered by kube-prometheus-stack.
SeaweedFS and NVIDIA exporters are not installed by these templates yet, so their
dashboards are not provisioned. Existing Cilium agent/operator/Hubble dashboards
and kube-prometheus-stack's bundled Kubernetes/storage/Prometheus dashboards
remain owned by their Helm charts and are not duplicated here.

# news — cluster manifests

This directory contains the cluster-specific layer for the `news` service. The shipping Helm chart lives under [`chart/`](./chart/); cluster overrides live in [`values.yaml`](./values.yaml).

Argo CD applies the chart with `helm` from `chart/`, the values overlay from `values.yaml`, and any sister manifests at the top level of this directory (none currently — Tailscale Ingresses are also chart-templated). See [`../../apps/news.yaml`](../../apps/news.yaml) for the three-source wiring.

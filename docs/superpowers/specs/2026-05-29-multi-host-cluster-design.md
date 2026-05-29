# Multi-Host Cluster: Add Desktop Node + Repo Refactor

**Date:** 2026-05-29
**Status:** Approved

## Context

nas2 is a single-node k3s cluster (server + etcd) on Ubuntu 24.04. The repo assumes one host everywhere: a single `gpu_hosts` inventory group, one play in `playbook.yml` applying all roles to that group, and Makefile targets hardcoded to `ssh ed@nas2`.

The goal is to add a Windows desktop running WSL2 (Ubuntu 24.04, RTX5080) as a k3s **agent** node, and refactor the repo so adding future hosts requires only a new inventory entry and a `host_vars/<name>/main.yml` file.

## Constraints

**WSL2 GPU driver:** On WSL2, the NVIDIA Linux kernel driver lives in Windows (the host provides GPU access via the Direct3D 12 compute / CUDA-on-WSL virtualization layer). The `nvidia_driver` and `cuda` Ansible roles must be **skipped on WSL2 nodes**. Only `nvidia_container_toolkit` is needed — it integrates the Windows-provided GPU into the container runtime.

**Storage:** All existing PVCs are provisioned by the k3s local-path provisioner on nas2 (`ReadWriteOnce`). Kubernetes VolumeScheduling encodes node affinity into those PersistentVolumes automatically. Stateful workloads (ollama, hermes, agentregistry) will continue to schedule on nas2 without explicit nodeSelectors. New stateless GPU pods can schedule to either node.

**Desktop as agent-only:** nas2 remains the sole control-plane and etcd node. The desktop is a pure worker. If the desktop goes down, the cluster stays healthy on nas2.

## Architecture

### Inventory

```
inventory/hosts.yml
  all:
    k3s_servers:        # control-plane node(s)
      nas2
    k3s_agents:         # worker-only node(s)
      desktop

host_vars/
  nas2/main.yml         # k3s_node_role: server, wsl2: false, TLS SANs, route advertisement
  desktop/main.yml      # k3s_node_role: agent, wsl2: true, k3s_server_url
```

Adding a future host = one inventory line + one `host_vars/<name>/main.yml`.

### Playbook Structure

Two plays in `playbook.yml`:

**Play 1 — `k3s_servers`** (full role set, identical to current nas2 setup):
`common, console_font, nvidia_driver, docker, nvidia_container_toolkit, cuda, tailscale, k3s, kubectl, argocd_bootstrap, user_shell, claude_code, wifi, firewall`

**Play 2 — `k3s_agents`** (worker subset):
`common, docker, nvidia_container_toolkit, tailscale, k3s, user_shell, firewall`

Omitted from agents:
- `nvidia_driver`, `cuda` — WSL2 gets GPU from Windows; installing Linux driver would break GPU passthrough
- `argocd_bootstrap`, `kubectl` — cluster bootstrap runs once on the server only
- `console_font`, `wifi`, `claude_code` — server-specific utilities

### k3s Role Changes

`roles/k3s/defaults/main.yml` gains:
- `k3s_node_role: server` (default; overridden per-host via host_vars)
- `k3s_server_url: ""` (agents: `https://nas2.taile9c9c.ts.net:6443`)
- `k3s_agent_args: []`

`roles/k3s/tasks/main.yml` install task splits into:
- **Server install:** `INSTALL_K3S_EXEC: "server {{ k3s_server_args }}"` (when `k3s_node_role == 'server'`)
- **Agent install:** `INSTALL_K3S_EXEC: "agent {{ k3s_agent_args }}"` + `K3S_URL` + `K3S_TOKEN` (when `k3s_node_role == 'agent'`)

**Token fetch:** The agent play reads `/var/lib/rancher/k3s/server/token` from nas2 via `delegate_to: groups['k3s_servers'][0]` — no manual extract or vault storage required.

**Readiness check:** Server checks via local `k3s kubectl wait`. Agent delegates the same check to the server node.

**Service name:** k3s server = `k3s`, agent = `k3s-agent`. Handler updated to use `'k3s-agent' if k3s_node_role == 'agent' else 'k3s'`.

**Config template (`config.yaml.j2`):** TLS SANs block emitted only when `k3s_node_role == 'server'` — agents get an empty config file.

### common Role: WSL2 Systemd

New `roles/common/tasks/wsl2.yml` included from `tasks/main.yml` when `wsl2 | default(false)`.

Ensures `/etc/wsl.conf` has `[boot] systemd=true` — required for k3s and Tailscale to run as systemd services in WSL2. This runs before the k3s and tailscale roles in the play order.

### Variable Migration

Moved from `group_vars/all/main.yml` to `host_vars/nas2/main.yml`:
- `k3s_tls_san` — server-specific; agents need none (role default `[]` applies)
- `tailscale_advertise_routes` — server advertises pod/service CIDRs; `host_vars/desktop` sets `[]`

### Makefile

- `K3S_SERVER ?= nas2` variable at top; all `ssh ed@nas2` → `ssh ed@$(K3S_SERVER)`
- New `apply-host` target: `ansible-playbook playbook.yml --diff --limit $(HOST)`

### gitops

No workload manifest changes required. PVC node affinity handles stateful scheduling. The `# Single-node now` comment is removed from `gitops/manifests/ollama/values.yaml`.

## Pre-requisites (manual, before Ansible)

Before running `make apply-host HOST=desktop`:
1. WSL2 instance has `openssh-server` installed and running
2. Desktop is reachable at `desktop.taile9c9c.ts.net` (Tailscale connected on Windows, or Tailscale CLI installed in WSL2 manually)
3. SSH key from the provisioning machine is in `~/.ssh/authorized_keys` in WSL2

## Verification

1. `make check` — dry-run, zero errors across both plays
2. `make apply-host HOST=nas2` — idempotent re-apply, no changes
3. `make apply-host HOST=desktop` — first provision; k3s agent joins
4. `kubectl get nodes -o wide` — both `nas2` (control-plane) and `desktop` (worker) `Ready`
5. `kubectl describe node desktop | grep -i gpu` — `nvidia.com/gpu.present: true`
6. `tests/run-all.sh --retry 3` — 16+ passing, existing workloads unaffected
7. `tests/test-multi-node.sh` — PASS
8. One-shot test pod with `runtimeClassName: nvidia`, no PVC → schedules on `desktop`, `nvidia-smi` exits 0

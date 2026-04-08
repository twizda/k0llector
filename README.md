# k0llector

**Version:** 0.2.0 (see `VERSION`; run `./collect.sh --version`)

Collects a timestamped diagnostic bundle from a Kubernetes cluster pointed at by `kubectl`. The default profile targets a k0rdent **management** cluster (layers 1–10). Use **`--k0s`** to append **layer 11** (k0s-oriented API snapshots: `kube-system`, optional `k0s-autopilot`, nodes, webhooks, CSRs, etc.). **Layer 6** collects host `journalctl` for `k0scontroller` / `k0sworker` when SSH is configured, and (by default) runs **`sudo k0s status`** on every node and **`sudo k0s etcd member-list`** on control-plane nodes. Each run writes **`00-SUMMARY.txt`** and **`00-INDEX.txt`**.

## Usage

```bash
chmod +x collect.sh
./collect.sh
```

With a single tarball when finished:

```bash
./collect.sh -a
```

Default layers are **1–10**. Omit heavy sections with `-l` (e.g. `-l 1,2,3,4,5,6,7` to skip long log collection in layers 9–10).

### Options

| Flag | Meaning |
|------|--------|
| `-o DIR` | Output root (default `./k0llect-out` or `K0LLECT_OUTPUT`) |
| `-l LIST` | Comma-separated layers (default `1,2,3,4,5,6,7,8,9,10`) |
| `--no-ssh` | Skip layer 6 |
| `--ssh-jump H` | Bastion for layer 6 (`ssh -J`). Same as `K0LLECT_SSH_JUMP`. |
| `-a`, `--archive` | Create one `.tar.gz` of the run directory |
| `--archive-path F` | Full path for the tarball (implies `--archive`) |
| `--request-timeout D` | Per-request timeout for every `kubectl` call (e.g. `60s`, `2m`). Overrides env default. |
| `--no-request-timeout` | Do not pass `kubectl --request-timeout` (API server default). |
| `--k0s` | Append **layer 11** (k0s-focused snapshots). Combines with default layers unless you narrow with `-l`. Same as `K0LLECT_K0S_EXTRAS=1`. |
| `--redact-configmaps` | After layer 11 collects `configmaps-kube-system.yaml`, apply **best-effort** masking of obvious secret-like keys and long base64 values. Prefer reviewing the bundle before sharing in all cases. |
| `--no-redact-configmaps` | Do not redact (default unless `K0LLECT_REDACT_CONFIGMAPS=1`). |

### Environment

| Variable | Purpose |
|----------|---------|
| `KUBECTL` | kubectl binary path (default `kubectl`) |
| `K0LLECT_KCM_NS` | KCM namespace (default `kcm-system`) |
| `K0LLECT_KOF_NS` | If set and namespace exists, layer 9 collects ServiceMonitors/PodMonitors/pods there (e.g. KOF install namespace) |
| `K0LLECT_K0S_NS` | Comma-separated **extra** namespaces to include in **layer 11** (pods/events/`get all`) and **layer 10** pod log tails when the namespace exists (e.g. `kube-node-lease`, `cert-manager`) |
| `K0LLECT_COREDNS_LABELS` | Comma-separated `-l` selectors for CoreDNS in layer 1 |
| `K0LLECT_SSH_USER`, `K0LLECT_SSH_JUMP`, `K0LLECT_SSH_OPTS`, `K0LLECT_SKIP_SSH` | Layer 6 SSH |
| `K0LLECT_SSH_K0S_CLI` | Set to `0` to skip SSH `k0s status` / `k0s etcd member-list` (default `1` when layer 6 runs with SSH) |
| `K0LLECT_K0S_BIN` | `k0s` binary path on **remote** nodes for SSH probes (default `k0s`) |
| `K0LLECT_ARCHIVE`, `K0LLECT_ARCHIVE_PATH` | Archiving |
| `K0LLECT_LOG_TAIL` | Tail lines per pod in layer 10 (default `100`) |
| `K0LLECT_LOGS_MAX_PODS` | Max pods per namespace in layer 10 (default `30`) |
| `K0LLECT_REQUEST_TIMEOUT` | If **unset**, k0llector defaults to `60s` for `kubectl --request-timeout`. If set to **empty**, no timeout flag is passed. Any other value is used as-is (e.g. `120s`). |
| `K0LLECT_K0S_EXTRAS` | Set to `1` to enable layer 11 without passing `--k0s`. |
| `K0LLECT_REDACT_CONFIGMAPS` | Set to `1` to redact layer 11 kube-system ConfigMaps (same as `--redact-configmaps`). |
| `K0LLECT_REDACT_KEEP_ORIGINAL` | Set to `1` to write `configmaps-kube-system.yaml.full` before redacting (when redaction is enabled). |

Layer 6 uses `sudo -n` on the remote host for `journalctl` and (unless disabled) `k0s` subcommands (passwordless sudo required for non-interactive runs).

### Standalone k0s (no k0rdent)

Omit k0rdent-heavy layers and keep cluster health, logs, host journals, k0s CLI probes, and k0s layer 11:

```bash
K0LLECT_SSH_USER=ubuntu ./collect.sh --k0s -l 1,6,10,11 -a
```

Optional extra namespaces (e.g. leases, cert-manager):

```bash
K0LLECT_K0S_NS=kube-node-lease,cert-manager K0LLECT_SSH_USER=ubuntu ./collect.sh --k0s -l 1,6,10,11 -a
```

Layers 2–5, 7–9 will fail or be empty on a plain k0s cluster if you include them; the commands above avoid that. You can add **7** if you use Cluster API on that cluster (`-l 1,6,7,10,11`).

### Full k0rdent + k0s extras

```bash
./collect.sh --k0s -a
```

This runs the usual management-cluster layers **and** layer 11 (some overlap with layer 1 `kube-system` is intentional for a denser k0s-focused snapshot under `layer11-k0s/`).

### Multi-cluster / multiple kubeconfigs

k0llector uses whatever cluster **`kubectl`** points at (`KUBECONFIG`, `kubectl config use-context`, etc.). To collect **another** cluster (e.g. regional or workload), run the script again with a different kube context or `KUBECONFIG` and a **separate** `-o` output root so bundles do not overwrite each other:

```bash
kubectl config use-context mgmt && ./collect.sh -o ./bundles/mgmt-run
KUBECONFIG=~/.kube/regional.yaml ./collect.sh -o ./bundles/regional-run
```

### CoreDNS labels (layer 1)

Default selectors include `k8s-app=kube-dns`, `app.kubernetes.io/name=coredns`, and `k8s-app=coredns`. Override with `K0LLECT_COREDNS_LABELS`.

### Bastion (layer 6)

```bash
K0LLECT_SSH_USER=ubuntu K0LLECT_SSH_JUMP=ubuntu@bastion.example.com ./collect.sh -l 6
```

### Archive

Default archive path: `<output-root>/<timestamp>.tar.gz`.

### Sensitive data

**Credentials:** layer 3 includes `credentials.yaml` with a header noting that objects may reference Secret names; review before sharing. Other commands may still surface secret references in specs.

**Layer 10** tails logs from many pods in `kube-system` and other namespaces; ensure log content is acceptable to export under your policy.

**Layer 11** includes full **ConfigMaps in `kube-system`** (chart values, etc.). Use **`--redact-configmaps`** or **`K0LLECT_REDACT_CONFIGMAPS=1`** for best-effort masking of common secret-like YAML keys and long base64-like lines. Redaction is **not** a guarantee—treat bundles as potentially sensitive until you review them.

**SSH k0s probes** (`k0s status`, `k0s etcd member-list`) can expose cluster topology; disable with `K0LLECT_SSH_K0S_CLI=0` if you only want journals.

## Layers (0.2.0)

| Layer | Contents |
|-------|-----------|
| **1** | Nodes, `kubectl top`, kube-system pods, `api-resources` for `k0rdent.mirantis.com`, CoreDNS describe/logs per label selector |
| **2** | `Management`, KCM namespace pods/describe/events, kcm-controller-manager logs, admission **Validating/MutatingWebhookConfiguration** (cluster-wide) |
| **3** | Templates, `ClusterDeployment`, `ProviderTemplate`, **Credential** (with notice), cluster-scoped: `Release`, `AccessManagement`, `MultiClusterService`, `ManagementBackup`, `ProviderInterface`, `Region`, `StateManagementProvider`; namespaced: chains, `ServiceSet`, `ClusterAuthentication`, `DataSource`, `ClusterDataSource`, `ClusterIPAM`, `ClusterIPAMClaim` |
| **4** | Flux: `HelmRelease`, `HelmRepository`, `HelmChart`, `GitRepository`, `OCIRepository`, `Bucket`, `Kustomization`; controller logs: helm, source, kustomize, notification, image-automation, image-reflector |
| **5** | KCM pods, non-Running filter, **k0smotron** pods (`app.kubernetes.io/part-of=k0smotron`) and logs for both `app=k0smotron` and `part-of` label, StatefulSets |
| **6** | Optional SSH `journalctl` for `k0scontroller` / `k0sworker` per node; optional **`sudo k0s status`** on all nodes; **`sudo k0s etcd member-list`** on control-plane nodes (disable CLI parts with `K0LLECT_SSH_K0S_CLI=0`; remote binary via `K0LLECT_K0S_BIN`) |
| **7** | Cluster API: `Cluster`, `Machine`, `MachineDeployment`, `MachineSet`, `KubeadmControlPlane` (`-A`); pods/events in common CAPI/CAPx namespaces if present |
| **8** | projectsveltos: API resources grep, `SveltosCluster` (`-A`), pods/events in `projectsveltos` if present |
| **9** | `ServiceMonitor`, `PodMonitor`, `PrometheusRule` in `kcm-system`; same + pods in `K0LLECT_KOF_NS` when set |
| **10** | Per-pod log tails (bounded) for namespaces that exist: `kcm-system`, `projectsveltos`, `kube-system`, `kubevirt`, `cdi`, **plus any namespace listed in `K0LLECT_K0S_NS`** (deduped) |
| **11** | **k0s** (with `--k0s` / `K0LLECT_K0S_EXTRAS=1`): `api-resources` lines matching `k0s`, full `nodes` YAML, optional legacy `componentstatuses`, `kube-system` events/pods/daemonsets/deployments/endpoints/configmaps (optional **redact**), admission webhooks cluster-wide, CSRs, `kubectl top pods -n kube-system`, non-ready pod lines; if present: **`k0s-autopilot`**; **HelmRelease** in `kube-system`; **per-namespace** snapshots for each **`K0LLECT_K0S_NS`** entry that exists |

If a CRD or namespace is missing, the corresponding file contains the kubectl error and a non-zero `# exit_code`.

## Output files

- `00-meta.txt` — k0llector version, kubectl version, context, request timeout, `KUBECONFIG` hint, `k0s_extras`, `k0s_extra_namespaces`, SSH k0s CLI settings, redact flags  
- `00-cluster-info.txt` — `kubectl cluster-info`  
- `00-SUMMARY.txt` — bundle size, layers, list of files whose collected command ended with **non-zero** `# exit_code`, plus counts of files with an exit footer vs failures  
- `00-INDEX.txt` — sorted file list and `du -sh` of the bundle  

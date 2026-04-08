# k0llector

**Version:** 0.1.2 (see `VERSION`; run `./collect.sh --version`)

Collects a timestamped diagnostic bundle from a k0rdent **management** cluster: kubectl-based inventory (layers 1–5, 7–10) and optional SSH for k0s journals on nodes (layer 6). Each run writes **`00-SUMMARY.txt`** (rollup of non-zero `kubectl` exits and bundle size) and **`00-INDEX.txt`** (full file list).

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

### Environment

| Variable | Purpose |
|----------|---------|
| `KUBECTL` | kubectl binary path (default `kubectl`) |
| `K0LLECT_KCM_NS` | KCM namespace (default `kcm-system`) |
| `K0LLECT_KOF_NS` | If set and namespace exists, layer 9 collects ServiceMonitors/PodMonitors/pods there (e.g. KOF install namespace) |
| `K0LLECT_COREDNS_LABELS` | Comma-separated `-l` selectors for CoreDNS in layer 1 |
| `K0LLECT_SSH_USER`, `K0LLECT_SSH_JUMP`, `K0LLECT_SSH_OPTS`, `K0LLECT_SKIP_SSH` | Layer 6 SSH |
| `K0LLECT_ARCHIVE`, `K0LLECT_ARCHIVE_PATH` | Archiving |
| `K0LLECT_LOG_TAIL` | Tail lines per pod in layer 10 (default `100`) |
| `K0LLECT_LOGS_MAX_PODS` | Max pods per namespace in layer 10 (default `30`) |
| `K0LLECT_REQUEST_TIMEOUT` | If **unset**, k0llector defaults to `60s` for `kubectl --request-timeout`. If set to **empty**, no timeout flag is passed. Any other value is used as-is (e.g. `120s`). |

Layer 6 uses `sudo -n journalctl` on the remote host (passwordless sudo required for non-interactive runs).

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

## Layers (0.1.1)

| Layer | Contents |
|-------|-----------|
| **1** | Nodes, `kubectl top`, kube-system pods, `api-resources` for `k0rdent.mirantis.com`, CoreDNS describe/logs per label selector |
| **2** | `Management`, KCM namespace pods/describe/events, kcm-controller-manager logs, admission **Validating/MutatingWebhookConfiguration** (cluster-wide) |
| **3** | Templates, `ClusterDeployment`, `ProviderTemplate`, **Credential** (with notice), cluster-scoped: `Release`, `AccessManagement`, `MultiClusterService`, `ManagementBackup`, `ProviderInterface`, `Region`, `StateManagementProvider`; namespaced: chains, `ServiceSet`, `ClusterAuthentication`, `DataSource`, `ClusterDataSource`, `ClusterIPAM`, `ClusterIPAMClaim` |
| **4** | Flux: `HelmRelease`, `HelmRepository`, `HelmChart`, `GitRepository`, `OCIRepository`, `Bucket`, `Kustomization`; controller logs: helm, source, kustomize, notification, image-automation, image-reflector |
| **5** | KCM pods, non-Running filter, **k0smotron** pods (`app.kubernetes.io/part-of=k0smotron`) and logs for both `app=k0smotron` and `part-of` label, StatefulSets |
| **6** | Optional SSH `journalctl` for `k0scontroller` / `k0sworker` per node |
| **7** | Cluster API: `Cluster`, `Machine`, `MachineDeployment`, `MachineSet`, `KubeadmControlPlane` (`-A`); pods/events in common CAPI/CAPx namespaces if present |
| **8** | projectsveltos: API resources grep, `SveltosCluster` (`-A`), pods/events in `projectsveltos` if present |
| **9** | `ServiceMonitor`, `PodMonitor`, `PrometheusRule` in `kcm-system`; same + pods in `K0LLECT_KOF_NS` when set |
| **10** | Per-pod log tails (bounded) for namespaces that exist: `kcm-system`, `projectsveltos`, `kube-system`, `kubevirt`, `cdi` (aligned with KCM support-bundle style) |

If a CRD or namespace is missing, the corresponding file contains the kubectl error and a non-zero `# exit_code`.

## Output files

- `00-meta.txt` — k0llector version, kubectl version, context, request timeout, `KUBECONFIG` hint  
- `00-cluster-info.txt` — `kubectl cluster-info`  
- `00-SUMMARY.txt` — bundle size, layers, list of files whose collected command ended with **non-zero** `# exit_code`, plus counts of files with an exit footer vs failures  
- `00-INDEX.txt` — sorted file list and `du -sh` of the bundle  

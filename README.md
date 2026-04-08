# k0llector

**Version:** 0.1 (see `VERSION`; run `./collect.sh --version`)

Collects a timestamped diagnostic bundle from a k0rdent **management** cluster (kubectl-based layers 1–5; optional SSH for k0s journals on nodes).

## Usage

```bash
chmod +x collect.sh
./collect.sh
```

With a single tarball when finished:

```bash
./collect.sh -a
# or
K0LLECT_ARCHIVE=1 ./collect.sh
```

Output defaults to `./k0llect-out/<UTC-timestamp>/`. Each command’s stdout/stderr is stored under layer-named subdirectories; failures are recorded with a non-zero `# exit_code` footer.

### Options

| Flag | Meaning |
|------|--------|
| `-o DIR` | Output root (default `./k0llect-out` or `K0LLECT_OUTPUT`) |
| `-l 1,2,3` | Run only listed layers |
| `--no-ssh` | Skip automated SSH (layer 6) |
| `--ssh-jump H` | Bastion / jump host for layer 6 (`ssh -J H …`). Same as `K0LLECT_SSH_JUMP`. |
| `-a`, `--archive` | After collection, create one gzip’d tar of the run directory |
| `--archive-path F` | Full path for the tarball (implies `--archive`); parent dirs are created |

### Environment

| Variable | Purpose |
|----------|---------|
| `KUBECTL` | kubectl binary path (default `kubectl`) |
| `K0LLECT_KCM_NS` | kcm namespace (default `kcm-system`) |
| `K0LLECT_COREDNS_LABELS` | Comma-separated label selectors for CoreDNS in layer 1 (see below) |
| `K0LLECT_SSH_USER` | If set, layer 6 runs `journalctl` on each node via `ssh` |
| `K0LLECT_SSH_JUMP` | Jump host for layer 6, e.g. `ubuntu@bastion.example.com` (OpenSSH `-J`) |
| `K0LLECT_SSH_OPTS` | Extra ssh flags (default `-o BatchMode=yes -o ConnectTimeout=10`) |
| `K0LLECT_SKIP_SSH` | Set to `1` to skip SSH without `--no-ssh` |
| `K0LLECT_ARCHIVE` | Set to `1` to create a `.tar.gz` (same as `-a`) |
| `K0LLECT_ARCHIVE_PATH` | Full path for the tarball when archiving |

Layer 6 uses `sudo -n journalctl` on the remote host (passwordless sudo required for non-interactive runs).

### CoreDNS labels (layer 1)

Clusters differ: CoreDNS may use `k8s-app=kube-dns`, `app.kubernetes.io/name=coredns`, or `k8s-app=coredns`. By default, k0llector runs **describe** and **logs** for each selector in `K0LLECT_COREDNS_LABELS` (comma-separated, no spaces unless you quote the env value). Files are named from the selector, for example:

- `describe-coredns-k8s-app-kube-dns.txt`
- `describe-coredns-app.kubernetes.io-name-coredns.txt`

Override entirely:

```bash
K0LLECT_COREDNS_LABELS='k8s-app=kube-dns,app.kubernetes.io/name=coredns' ./collect.sh -l 1
```

Selectors that match no pods still produce files with kubectl’s message and a non-zero exit code footer.

### Bastion / jump host (layer 6)

When nodes are reachable only via a bastion, set a jump target (OpenSSH `ProxyJump` / `-J`):

```bash
K0LLECT_SSH_USER=ubuntu K0LLECT_SSH_JUMP=ubuntu@bastion.example.com ./collect.sh -l 6
```

Or:

```bash
./collect.sh --ssh-jump ubuntu@bastion.example.com -l 6
```

On OpenSSH versions that support it, multiple hops can be comma-separated in one `-J` argument (e.g. `user@hop1,user@hop2`). You can also encode complex paths in `K0LLECT_SSH_OPTS` (for example `ProxyJump` in an `ssh_config` `Host` block) and use a short `K0LLECT_SSH_JUMP` only if needed.

### Archive

Default archive path: `<output-root>/<timestamp>.tar.gz` (sibling to the unpacked directory). Extract with:

```bash
tar -xzf k0llect-out/20260108T120000Z.tar.gz -C /path/to/dest
```

## Layers

1. Management cluster health (nodes, optional `top`, kube-system, CoreDNS for each configured label selector)
2. KCM (`management`, pods, describe, controller logs, events)
3. Templates and `ClusterDeployment` / `ProviderTemplate`
4. Flux Helm (`HelmRelease`, `HelmRepository`, `HelmChart`, source-controller logs)
5. HCP / k0smotron signals (pods, non-Running filter, k0smotron logs, StatefulSets)
6. k0s unit journals on nodes (SSH + sudo when `K0LLECT_SSH_USER` is set; optional `-J` jump)

If metrics-server, Helm CRDs, or labeled workloads are missing, the corresponding files will contain the kubectl error and a non-zero exit code.

#!/usr/bin/env bash
# k0llector — collect a diagnostic bundle for k0rdent / management cluster troubleshooting.
# Requires: kubectl (and optional: ssh for layer 6, metrics-server for kubectl top).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K0LLECTOR_VERSION="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "${SCRIPT_DIR}/VERSION" 2>/dev/null || true)"
[[ -z "$K0LLECTOR_VERSION" ]] && K0LLECTOR_VERSION="unknown"

KUBECTL="${KUBECTL:-kubectl}"
OUTPUT_ROOT="${K0LLECT_OUTPUT:-./k0llect-out}"
KCM_NS="${K0LLECT_KCM_NS:-kcm-system}"
SSH_USER="${K0LLECT_SSH_USER:-}"
SSH_OPTS="${K0LLECT_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}"
SSH_JUMP="${K0LLECT_SSH_JUMP:-}"
SKIP_SSH="${K0LLECT_SKIP_SSH:-0}"
# Comma-separated kubectl -l selectors for CoreDNS (tried in order; each may match nothing).
COREDNS_LABELS="${K0LLECT_COREDNS_LABELS:-k8s-app=kube-dns,app.kubernetes.io/name=coredns,k8s-app=coredns}"
CREATE_ARCHIVE=0
ARCHIVE_PATH_OVERRIDE="${K0LLECT_ARCHIVE_PATH:-}"
[[ "${K0LLECT_ARCHIVE:-0}" == "1" ]] && CREATE_ARCHIVE=1

usage() {
  cat <<'EOF'
Usage: collect.sh [options]

  -o DIR         Output root directory (default: ./k0llect-out or $K0LLECT_OUTPUT)
  -l LIST        Comma-separated layers to run (default: 1,2,3,4,5,6). Example: -l 1,2,3
  --no-ssh       Skip layer 6 (node journalctl via SSH)
  --ssh-jump H   Bastion for layer 6: OpenSSH -J (e.g. user@bastion). Overrides $K0LLECT_SSH_JUMP.
  -a, --archive  Write a single .tar.gz of the run directory when finished
  --archive-path F  Full path for the tarball (default: <output-root>/<timestamp>.tar.gz)
  --version      Print k0llector version and exit
  -h, --help     This help

Environment:
  KUBECTL, K0LLECT_OUTPUT, K0LLECT_KCM_NS
  K0LLECT_COREDNS_LABELS (comma-separated -l selectors for CoreDNS in layer 1)
  K0LLECT_SSH_USER, K0LLECT_SSH_JUMP, K0LLECT_SSH_OPTS, K0LLECT_SKIP_SSH
  K0LLECT_ARCHIVE=1, K0LLECT_ARCHIVE_PATH

Layer 6 runs journalctl on each node via ssh only if K0LLECT_SSH_USER is set (unless --no-ssh).
With a jump host, ssh uses: ssh ... -J <jump> user@node ...
EOF
}

LAYERS="1,2,3,4,5,6"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT_ROOT="$2"; shift 2 ;;
    -l) LAYERS="$2"; shift 2 ;;
    --no-ssh) SKIP_SSH=1; shift ;;
    --ssh-jump) SSH_JUMP="$2"; shift 2 ;;
    -a|--archive) CREATE_ARCHIVE=1; shift ;;
    --archive-path) ARCHIVE_PATH_OVERRIDE="$2"; CREATE_ARCHIVE=1; shift 2 ;;
    --version) echo "k0llector ${K0LLECTOR_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

layer_enabled() {
  local n="$1"
  [[ ",${LAYERS}," == *",${n},"* ]]
}

timestamp_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Safe filename fragment from a kubectl label selector (e.g. k8s-app=kube-dns).
coredns_selector_to_basename() {
  local s="$1"
  s="${s//=/-}"
  s="${s//\//-}"
  s="${s//,/-}"
  s="${s// /-}"
  printf '%s' "$s"
}

# Run command; capture stdout+stderr to file; never abort the script.
collect() {
  local out_file="$1"
  shift
  local ec=0
  {
    echo "# k0llector @ $(timestamp_utc)"
    echo "# command: $*"
    echo "---"
    "$@" 2>&1
    ec=$?
    echo "---"
    echo "# exit_code: $ec"
  } >"$out_file"
}

need_kubectl() {
  if ! command -v "$KUBECTL" >/dev/null 2>&1; then
    echo "k0llector: kubectl not found (set KUBECTL=...). Aborting." >&2
    exit 1
  fi
}

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUTPUT_ROOT%/}/${RUN_TS}"
mkdir -p "$OUT"

need_kubectl

{
  echo "k0llector_version: ${K0LLECTOR_VERSION}"
  echo "k0llector_run_utc: $(timestamp_utc)"
  echo "output_dir: $OUT"
  echo "kubectl: $KUBECTL"
  echo "layers: $LAYERS"
  echo "---"
  "$KUBECTL" version -o yaml 2>&1 || true
  echo "---"
  "$KUBECTL" config current-context 2>&1 || true
} >"$OUT/00-meta.txt" 2>&1

collect "$OUT/00-cluster-info.txt" "$KUBECTL" cluster-info

# --- Layer 1 ---
if layer_enabled 1; then
  L1="$OUT/layer1-management-cluster"
  mkdir -p "$L1"
  collect "$L1/nodes-wide.txt" "$KUBECTL" get nodes -o wide
  collect "$L1/top-nodes.txt" "$KUBECTL" top nodes
  collect "$L1/pods-kube-system.txt" "$KUBECTL" get pods -n kube-system -o wide
  IFS=',' read -r -a _coredns_sels <<< "$COREDNS_LABELS"
  for sel in "${_coredns_sels[@]}"; do
    sel="$(printf '%s\n' "$sel" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$sel" ]] && continue
    _bn="$(coredns_selector_to_basename "$sel")"
    collect "$L1/describe-coredns-${_bn}.txt" "$KUBECTL" describe pods -n kube-system -l "$sel"
    collect "$L1/logs-coredns-${_bn}.txt" "$KUBECTL" logs -n kube-system -l "$sel" --tail=100 --prefix=true
  done
fi

# --- Layer 2 ---
if layer_enabled 2; then
  L2="$OUT/layer2-kcm"
  mkdir -p "$L2"
  collect "$L2/management.yaml" "$KUBECTL" get management -n "$KCM_NS" -o yaml
  collect "$L2/pods-wide.txt" "$KUBECTL" get pods -n "$KCM_NS" -o wide
  collect "$L2/describe-pods.txt" "$KUBECTL" describe pods -n "$KCM_NS"
  collect "$L2/logs-kcm-controller-manager.txt" "$KUBECTL" logs -n "$KCM_NS" -l app=kcm-controller-manager --tail=200 --prefix=true
  collect "$L2/events-kcm-system.txt" "$KUBECTL" get events -n "$KCM_NS" --sort-by='.lastTimestamp'
  collect "$L2/events-kcm-controller-all-ns.txt" "$KUBECTL" get events -A --field-selector reportingComponent=kcm-controller-manager
fi

# --- Layer 3 ---
if layer_enabled 3; then
  L3="$OUT/layer3-templates-deployments"
  mkdir -p "$L3"
  collect "$L3/clustertemplate.yaml" "$KUBECTL" get clustertemplate -n "$KCM_NS" -o yaml
  collect "$L3/servicetemplate.yaml" "$KUBECTL" get servicetemplate -n "$KCM_NS" -o yaml
  collect "$L3/clusterdeployment-all.yaml" "$KUBECTL" get clusterdeployment -A -o yaml
  collect "$L3/providertemplate.txt" "$KUBECTL" get providertemplate -n "$KCM_NS"
fi

# --- Layer 4 ---
if layer_enabled 4; then
  L4="$OUT/layer4-flux-helm"
  mkdir -p "$L4"
  collect "$L4/helmrelease-all.yaml" "$KUBECTL" get helmrelease -A -o yaml
  collect "$L4/helmrepository-all.yaml" "$KUBECTL" get helmrepository -A -o yaml
  collect "$L4/helmchart-all.txt" "$KUBECTL" get helmchart -A
  collect "$L4/logs-source-controller.txt" "$KUBECTL" logs -n "$KCM_NS" -l app=source-controller --tail=200 --prefix=true
fi

# --- Layer 5 ---
if layer_enabled 5; then
  L5="$OUT/layer5-hcp-k0smotron"
  mkdir -p "$L5"
  collect "$L5/pods-kcm-all.txt" "$KUBECTL" get pods -n "$KCM_NS" -o wide
  {
    echo "# k0llector @ $(timestamp_utc)"
    echo "# non-Running lines (grep -v Running on kubectl get pods)"
    echo "---"
    "$KUBECTL" get pods -n "$KCM_NS" 2>&1 | grep -v Running || true
    echo "---"
  } >"$L5/pods-not-running-lines.txt"
  collect "$L5/logs-k0smotron.txt" "$KUBECTL" logs -n "$KCM_NS" -l app=k0smotron --tail=200 --prefix=true
  collect "$L5/statefulsets.txt" "$KUBECTL" get statefulsets -n "$KCM_NS" -o wide
fi

# --- Layer 6 (optional SSH) ---
if layer_enabled 6 && [[ "$SKIP_SSH" != "1" ]] && [[ -n "$SSH_USER" ]]; then
  L6="$OUT/layer6-k0s-node"
  mkdir -p "$L6"
  collect "$L6/nodes-for-ssh.txt" "$KUBECTL" get nodes -o wide

  SSH_JUMP_ARGS=()
  if [[ -n "$SSH_JUMP" ]]; then
    SSH_JUMP_ARGS=( -J "$SSH_JUMP" )
  fi
  {
    echo "# k0llector ssh settings @ $(timestamp_utc)"
    echo "# K0LLECT_SSH_USER=$SSH_USER"
    echo "# jump (-J): ${SSH_JUMP:-<none>}"
    echo "# extra opts: $SSH_OPTS"
  } >"$L6/ssh-config-snippet.txt"

  # shellcheck disable=SC2046
  for node in $("$KUBECTL" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    [[ -z "$node" ]] && continue
    cp_label="$("$KUBECTL" get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
    role_label="$("$KUBECTL" get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
    is_cp=""
    [[ "$cp_label" == "true" ]] && is_cp=1
    [[ "$role_label" == "true" ]] && is_cp=1
    m_label="$("$KUBECTL" get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null || true)"
    [[ "$m_label" == "true" ]] && is_cp=1

    target="$L6/${node}"
    mkdir -p "$target"
    if [[ -n "$is_cp" ]]; then
      # shellcheck disable=SC2086
      collect "$target/journal-k0scontroller.txt" ssh "${SSH_JUMP_ARGS[@]}" $SSH_OPTS "${SSH_USER}@${node}" sudo -n journalctl -u k0scontroller --no-pager -n 200
    else
      # shellcheck disable=SC2086
      collect "$target/journal-k0sworker.txt" ssh "${SSH_JUMP_ARGS[@]}" $SSH_OPTS "${SSH_USER}@${node}" sudo -n journalctl -u k0sworker --no-pager -n 200
    fi
  done
elif layer_enabled 6; then
  L6="$OUT/layer6-k0s-node"
  mkdir -p "$L6"
  {
    echo "# Skipped: set K0LLECT_SSH_USER=user and ensure SSH+sudo on nodes, or pass --no-ssh."
    echo "# Optional bastion: K0LLECT_SSH_JUMP=user@bastion or --ssh-jump user@bastion"
    echo "# To collect manually on each controller: sudo journalctl -u k0scontroller --no-pager -n 200"
    echo "# On each worker: sudo journalctl -u k0sworker --no-pager -n 200"
  } >"$L6/SKIPPED.txt"
fi

echo "k0llector: wrote bundle under: $OUT"

if [[ "$CREATE_ARCHIVE" == "1" ]]; then
  ARCHIVE_FILE="${ARCHIVE_PATH_OVERRIDE:-${OUTPUT_ROOT%/}/${RUN_TS}.tar.gz}"
  if ! command -v tar >/dev/null 2>&1; then
    echo "k0llector: --archive requested but tar not found; skipping archive." >&2
  else
    mkdir -p "$(dirname "$ARCHIVE_FILE")"
    tar -czf "$ARCHIVE_FILE" -C "${OUTPUT_ROOT%/}" "$RUN_TS"
    echo "k0llector: archive: $ARCHIVE_FILE"
  fi
else
  echo "k0llector: archive with: tar -czf \"${RUN_TS}.tar.gz\" -C \"${OUTPUT_ROOT%/}\" \"$RUN_TS\"  (or run with -a / --archive)"
fi

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
KOF_NS="${K0LLECT_KOF_NS:-}"
SSH_USER="${K0LLECT_SSH_USER:-}"
SSH_OPTS="${K0LLECT_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}"
SSH_JUMP="${K0LLECT_SSH_JUMP:-}"
SKIP_SSH="${K0LLECT_SKIP_SSH:-0}"
COREDNS_LABELS="${K0LLECT_COREDNS_LABELS:-k8s-app=kube-dns,app.kubernetes.io/name=coredns,k8s-app=coredns}"
LOG_TAIL="${K0LLECT_LOG_TAIL:-100}"
LOGS_MAX_PODS="${K0LLECT_LOGS_MAX_PODS:-30}"
CREATE_ARCHIVE=0
ARCHIVE_PATH_OVERRIDE="${K0LLECT_ARCHIVE_PATH:-}"
[[ "${K0LLECT_ARCHIVE:-0}" == "1" ]] && CREATE_ARCHIVE=1
# Unset K0LLECT_REQUEST_TIMEOUT → default 60s; empty K0LLECT_REQUEST_TIMEOUT → no --request-timeout (kubectl default).
REQUEST_TIMEOUT="${K0LLECT_REQUEST_TIMEOUT-60s}"

usage() {
  cat <<'EOF'
Usage: collect.sh [options]

  -o DIR         Output root directory (default: ./k0llect-out or $K0LLECT_OUTPUT)
  -l LIST        Comma-separated layers (default: 1–10). Example: -l 1,2,3
  --no-ssh       Skip layer 6 (node journalctl via SSH)
  --ssh-jump H   Bastion for layer 6: OpenSSH -J (e.g. user@bastion). Overrides $K0LLECT_SSH_JUMP.
  -a, --archive  Write a single .tar.gz of the run directory when finished
  --archive-path F  Full path for the tarball (default: <output-root>/<timestamp>.tar.gz)
  --request-timeout D  Per-request timeout for kubectl (e.g. 60s, 2m). Default from env or 60s.
  --no-request-timeout  Do not pass kubectl --request-timeout (use API server default).
  --version      Print k0llector version and exit
  -h, --help     This help

Environment:
  KUBECTL, K0LLECT_OUTPUT, K0LLECT_KCM_NS, K0LLECT_KOF_NS (KOF / observability namespace, optional)
  K0LLECT_COREDNS_LABELS, K0LLECT_SSH_USER, K0LLECT_SSH_JUMP, K0LLECT_SSH_OPTS, K0LLECT_SKIP_SSH
  K0LLECT_ARCHIVE=1, K0LLECT_ARCHIVE_PATH
  K0LLECT_LOG_TAIL (default 100), K0LLECT_LOGS_MAX_PODS (default 30, layer 10)
  K0LLECT_REQUEST_TIMEOUT (default 60s if unset; set to empty for no timeout)

Multi-cluster: point kubectl at another cluster with KUBECONFIG or kubectl config use-context,
  and run collect.sh again with a different -o output root (or rename the timestamp dir).

Layers: 1 mgmt health, 2 KCM, 3 k0rdent CRs+templates, 4 Flux, 5 HCP/k0smotron,
        6 SSH journals, 7 Cluster API, 8 projectsveltos, 9 monitors/KOF, 10 namespace log samples.

Layer 6: ssh … -J <jump> user@node when K0LLECT_SSH_JUMP / --ssh-jump set.
EOF
}

LAYERS="1,2,3,4,5,6,7,8,9,10"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT_ROOT="$2"; shift 2 ;;
    -l) LAYERS="$2"; shift 2 ;;
    --no-ssh) SKIP_SSH=1; shift ;;
    --ssh-jump) SSH_JUMP="$2"; shift 2 ;;
    -a|--archive) CREATE_ARCHIVE=1; shift ;;
    --archive-path) ARCHIVE_PATH_OVERRIDE="$2"; CREATE_ARCHIVE=1; shift 2 ;;
    --request-timeout) REQUEST_TIMEOUT="$2"; shift 2 ;;
    --no-request-timeout) REQUEST_TIMEOUT=""; shift ;;
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

namespace_exists() {
  "${KUBECTL_CMD[@]}" get ns "$1" -o name &>/dev/null
}

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

# Like collect() but with extra header lines after command line (before output).
collect_with_preamble() {
  local out_file="$1"
  shift
  local preamble="$1"
  shift
  local ec=0
  {
    echo "# k0llector @ $(timestamp_utc)"
    echo "# command: $*"
    echo "$preamble"
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

# Collect tail logs for up to LOGS_MAX_PODS pods in a namespace (layer 10).
collect_namespace_pod_logs() {
  local ns="$1"
  local out_dir="$2"
  local n=0
  mkdir -p "$out_dir"
  # shellcheck disable=SC2046
  for pod in $("${KUBECTL_CMD[@]}" get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [[ -z "$pod" ]] && continue
    n=$((n + 1))
    [[ "$n" -gt "$LOGS_MAX_PODS" ]] && break
    collect "$out_dir/${pod}.txt" "${KUBECTL_CMD[@]}" logs -n "$ns" "$pod" --all-containers=true --tail="$LOG_TAIL" --prefix=true
  done
}

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUTPUT_ROOT%/}/${RUN_TS}"
mkdir -p "$OUT"

need_kubectl

if [[ -n "$REQUEST_TIMEOUT" ]]; then
  KUBECTL_CMD=( "$KUBECTL" --request-timeout="$REQUEST_TIMEOUT" )
else
  KUBECTL_CMD=( "$KUBECTL" )
fi

{
  echo "k0llector_version: ${K0LLECTOR_VERSION}"
  echo "k0llector_run_utc: $(timestamp_utc)"
  echo "output_dir: $OUT"
  echo "kubectl: $KUBECTL"
  echo "kubectl_request_timeout: ${REQUEST_TIMEOUT:-<none>}"
  echo "KUBECONFIG: ${KUBECONFIG:-<unset, default kubeconfig>}"
  echo "layers: $LAYERS"
  echo "kcm_namespace: $KCM_NS"
  echo "kof_namespace: ${KOF_NS:-<unset>}"
  echo "---"
  "${KUBECTL_CMD[@]}" version -o yaml 2>&1 || true
  echo "---"
  "${KUBECTL_CMD[@]}" config current-context 2>&1 || true
} >"$OUT/00-meta.txt" 2>&1

collect "$OUT/00-cluster-info.txt" "${KUBECTL_CMD[@]}" cluster-info

# --- Layer 1 ---
if layer_enabled 1; then
  L1="$OUT/layer1-management-cluster"
  mkdir -p "$L1"
  collect "$L1/nodes-wide.txt" "${KUBECTL_CMD[@]}" get nodes -o wide
  collect "$L1/top-nodes.txt" "${KUBECTL_CMD[@]}" top nodes
  collect "$L1/pods-kube-system.txt" "${KUBECTL_CMD[@]}" get pods -n kube-system -o wide
  collect "$L1/api-resources-k0rdent.txt" "${KUBECTL_CMD[@]}" api-resources --api-group=k0rdent.mirantis.com -o wide
  IFS=',' read -r -a _coredns_sels <<< "$COREDNS_LABELS"
  for sel in "${_coredns_sels[@]}"; do
    sel="$(printf '%s\n' "$sel" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$sel" ]] && continue
    _bn="$(coredns_selector_to_basename "$sel")"
    collect "$L1/describe-coredns-${_bn}.txt" "${KUBECTL_CMD[@]}" describe pods -n kube-system -l "$sel"
    collect "$L1/logs-coredns-${_bn}.txt" "${KUBECTL_CMD[@]}" logs -n kube-system -l "$sel" --tail=100 --prefix=true
  done
fi

# --- Layer 2 ---
if layer_enabled 2; then
  L2="$OUT/layer2-kcm"
  mkdir -p "$L2"
  collect "$L2/management.yaml" "${KUBECTL_CMD[@]}" get management -o yaml
  collect "$L2/pods-wide.txt" "${KUBECTL_CMD[@]}" get pods -n "$KCM_NS" -o wide
  collect "$L2/describe-pods.txt" "${KUBECTL_CMD[@]}" describe pods -n "$KCM_NS"
  collect "$L2/logs-kcm-controller-manager.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=kcm-controller-manager --tail=200 --prefix=true
  collect "$L2/events-kcm-system.txt" "${KUBECTL_CMD[@]}" get events -n "$KCM_NS" --sort-by='.lastTimestamp'
  collect "$L2/events-kcm-controller-all-ns.txt" "${KUBECTL_CMD[@]}" get events -A --field-selector reportingComponent=kcm-controller-manager
  collect "$L2/validatingwebhookconfigurations.yaml" "${KUBECTL_CMD[@]}" get validatingwebhookconfiguration -o yaml
  collect "$L2/mutatingwebhookconfigurations.yaml" "${KUBECTL_CMD[@]}" get mutatingwebhookconfiguration -o yaml
fi

# --- Layer 3 ---
if layer_enabled 3; then
  L3="$OUT/layer3-kcm-resources"
  mkdir -p "$L3"
  collect "$L3/clustertemplate.yaml" "${KUBECTL_CMD[@]}" get clustertemplate -n "$KCM_NS" -o yaml
  collect "$L3/servicetemplate.yaml" "${KUBECTL_CMD[@]}" get servicetemplate -n "$KCM_NS" -o yaml
  collect "$L3/clusterdeployment-all.yaml" "${KUBECTL_CMD[@]}" get clusterdeployment -A -o yaml
  collect "$L3/providertemplate.yaml" "${KUBECTL_CMD[@]}" get providertemplate -n "$KCM_NS" -o yaml
  collect_with_preamble "$L3/credentials.yaml" "# NOTICE: Credential objects may reference Secret names; review before sharing." "${KUBECTL_CMD[@]}" get credentials -n "$KCM_NS" -o yaml
  collect "$L3/releases.yaml" "${KUBECTL_CMD[@]}" get release -o yaml
  collect "$L3/accessmanagements.yaml" "${KUBECTL_CMD[@]}" get accessmanagement -o yaml
  collect "$L3/multiclusterservices.yaml" "${KUBECTL_CMD[@]}" get multiclusterservice -o yaml
  collect "$L3/managementbackups.yaml" "${KUBECTL_CMD[@]}" get managementbackup -o yaml
  collect "$L3/providerinterfaces.yaml" "${KUBECTL_CMD[@]}" get providerinterface -o yaml
  collect "$L3/regions.yaml" "${KUBECTL_CMD[@]}" get region -o yaml
  collect "$L3/statemanagementproviders.yaml" "${KUBECTL_CMD[@]}" get statemanagementprovider -o yaml
  collect "$L3/clustertemplatechains.yaml" "${KUBECTL_CMD[@]}" get clustertemplatechain -n "$KCM_NS" -o yaml
  collect "$L3/servicetemplatechains.yaml" "${KUBECTL_CMD[@]}" get servicetemplatechain -n "$KCM_NS" -o yaml
  collect "$L3/servicesets.yaml" "${KUBECTL_CMD[@]}" get serviceset -n "$KCM_NS" -o yaml
  collect "$L3/clusterauthentications.yaml" "${KUBECTL_CMD[@]}" get clusterauthentication -n "$KCM_NS" -o yaml
  collect "$L3/datasources.yaml" "${KUBECTL_CMD[@]}" get datasource -n "$KCM_NS" -o yaml
  collect "$L3/clusterdatasources.yaml" "${KUBECTL_CMD[@]}" get clusterdatasource -n "$KCM_NS" -o yaml
  collect "$L3/clusteripams.yaml" "${KUBECTL_CMD[@]}" get clusteripam -n "$KCM_NS" -o yaml
  collect "$L3/clusteripamclaims.yaml" "${KUBECTL_CMD[@]}" get clusteripamclaim -n "$KCM_NS" -o yaml
fi

# --- Layer 4 ---
if layer_enabled 4; then
  L4="$OUT/layer4-flux"
  mkdir -p "$L4"
  collect "$L4/helmrelease-all.yaml" "${KUBECTL_CMD[@]}" get helmrelease -A -o yaml
  collect "$L4/helmrepository-all.yaml" "${KUBECTL_CMD[@]}" get helmrepository -A -o yaml
  collect "$L4/helmchart-all.txt" "${KUBECTL_CMD[@]}" get helmchart -A
  collect "$L4/gitrepository-all.yaml" "${KUBECTL_CMD[@]}" get gitrepository -A -o yaml
  collect "$L4/ocirepository-all.yaml" "${KUBECTL_CMD[@]}" get ocirepository -A -o yaml
  collect "$L4/bucket-all.yaml" "${KUBECTL_CMD[@]}" get bucket -A -o yaml
  collect "$L4/kustomization-all.yaml" "${KUBECTL_CMD[@]}" get kustomization -A -o yaml
  collect "$L4/logs-helm-controller.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=helm-controller --tail=200 --prefix=true
  collect "$L4/logs-source-controller.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=source-controller --tail=200 --prefix=true
  collect "$L4/logs-kustomize-controller.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=kustomize-controller --tail=200 --prefix=true
  collect "$L4/logs-notification-controller.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=notification-controller --tail=200 --prefix=true
  collect "$L4/logs-image-automation-controller.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=image-automation-controller --tail=200 --prefix=true
  collect "$L4/logs-image-reflector-controller.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=image-reflector-controller --tail=200 --prefix=true
fi

# --- Layer 5 ---
if layer_enabled 5; then
  L5="$OUT/layer5-hcp-k0smotron"
  mkdir -p "$L5"
  collect "$L5/pods-kcm-all.txt" "${KUBECTL_CMD[@]}" get pods -n "$KCM_NS" -o wide
  {
    echo "# k0llector @ $(timestamp_utc)"
    echo "# non-Running lines (grep -v Running on kubectl get pods)"
    echo "---"
    "${KUBECTL_CMD[@]}" get pods -n "$KCM_NS" 2>&1 | grep -v Running || true
    echo "---"
  } >"$L5/pods-not-running-lines.txt"
  collect "$L5/pods-part-of-k0smotron.txt" "${KUBECTL_CMD[@]}" get pods -n "$KCM_NS" -l app.kubernetes.io/part-of=k0smotron -o wide
  collect "$L5/logs-k0smotron-app-label.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app=k0smotron --tail=200 --prefix=true
  collect "$L5/logs-k0smotron-part-of-label.txt" "${KUBECTL_CMD[@]}" logs -n "$KCM_NS" -l app.kubernetes.io/part-of=k0smotron --tail=200 --prefix=true
  collect "$L5/statefulsets.txt" "${KUBECTL_CMD[@]}" get statefulsets -n "$KCM_NS" -o wide
fi

# --- Layer 6 (optional SSH) ---
if layer_enabled 6 && [[ "$SKIP_SSH" != "1" ]] && [[ -n "$SSH_USER" ]]; then
  L6="$OUT/layer6-k0s-node"
  mkdir -p "$L6"
  collect "$L6/nodes-for-ssh.txt" "${KUBECTL_CMD[@]}" get nodes -o wide

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
  for node in $("${KUBECTL_CMD[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    [[ -z "$node" ]] && continue
    cp_label="$("${KUBECTL_CMD[@]}" get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
    role_label="$("${KUBECTL_CMD[@]}" get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
    is_cp=""
    [[ "$cp_label" == "true" ]] && is_cp=1
    [[ "$role_label" == "true" ]] && is_cp=1
    m_label="$("${KUBECTL_CMD[@]}" get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null || true)"
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

# --- Layer 7: Cluster API ---
if layer_enabled 7; then
  L7="$OUT/layer7-cluster-api"
  mkdir -p "$L7"
  collect "$L7/clusters.yaml" "${KUBECTL_CMD[@]}" get cluster -A -o yaml
  collect "$L7/machines.yaml" "${KUBECTL_CMD[@]}" get machine -A -o yaml
  collect "$L7/machinedeployments.yaml" "${KUBECTL_CMD[@]}" get machinedeployment -A -o yaml
  collect "$L7/machinesets.yaml" "${KUBECTL_CMD[@]}" get machineset -A -o yaml
  collect "$L7/kubeadmcontrolplanes.yaml" "${KUBECTL_CMD[@]}" get kubeadmcontrolplane -A -o yaml
  for capi_ns in capi-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capi-docker-system capz-system capa-system capv-system capg-system capo-system; do
    if namespace_exists "$capi_ns"; then
      collect "$L7/pods-${capi_ns}.txt" "${KUBECTL_CMD[@]}" get pods -n "$capi_ns" -o wide
      collect "$L7/events-${capi_ns}.txt" "${KUBECTL_CMD[@]}" get events -n "$capi_ns" --sort-by='.lastTimestamp'
    fi
  done
fi

# --- Layer 8: projectsveltos ---
if layer_enabled 8; then
  L8="$OUT/layer8-projectsveltos"
  mkdir -p "$L8"
  {
    echo "# k0llector @ $(timestamp_utc)"
    echo "# command: ${KUBECTL_CMD[*]} api-resources | grep -i sveltos"
    echo "---"
    "${KUBECTL_CMD[@]}" api-resources 2>&1 | grep -i sveltos || true
    echo "---"
  } >"$L8/api-resources-sveltos.txt"
  collect "$L8/sveltosclusters.yaml" "${KUBECTL_CMD[@]}" get sveltosclusters -A -o yaml
  if namespace_exists projectsveltos; then
    collect "$L8/pods-projectsveltos.txt" "${KUBECTL_CMD[@]}" get pods -n projectsveltos -o wide
    collect "$L8/events-projectsveltos.txt" "${KUBECTL_CMD[@]}" get events -n projectsveltos --sort-by='.lastTimestamp'
  fi
fi

# --- Layer 9: observability (KOF / Prometheus Operator) ---
if layer_enabled 9; then
  L9="$OUT/layer9-observability"
  mkdir -p "$L9"
  collect "$L9/servicemonitors-kcm.yaml" "${KUBECTL_CMD[@]}" get servicemonitor -n "$KCM_NS" -o yaml
  collect "$L9/podmonitors-kcm.yaml" "${KUBECTL_CMD[@]}" get podmonitor -n "$KCM_NS" -o yaml
  collect "$L9/prometheusrules-kcm.yaml" "${KUBECTL_CMD[@]}" get prometheusrule -n "$KCM_NS" -o yaml
  if [[ -n "$KOF_NS" ]] && namespace_exists "$KOF_NS"; then
    collect "$L9/servicemonitors-kof-ns.yaml" "${KUBECTL_CMD[@]}" get servicemonitor -n "$KOF_NS" -o yaml
    collect "$L9/podmonitors-kof-ns.yaml" "${KUBECTL_CMD[@]}" get podmonitor -n "$KOF_NS" -o yaml
    collect "$L9/pods-kof-ns.txt" "${KUBECTL_CMD[@]}" get pods -n "$KOF_NS" -o wide
  else
    {
      echo "# KOF namespace not set or missing. Set K0LLECT_KOF_NS to collect KOF ServiceMonitors/Pods (e.g. kof)."
    } >"$L9/KOF_SKIPPED.txt"
  fi
fi

# --- Layer 10: namespace log samples (support-bundle style) ---
if layer_enabled 10; then
  L10="$OUT/layer10-namespace-logs"
  mkdir -p "$L10"
  {
    echo "# Per-pod log tail=${LOG_TAIL}, max pods per namespace=${LOGS_MAX_PODS}"
    echo "# Namespaces: kcm-system, projectsveltos, kube-system, kubevirt, cdi (when present)"
  } >"$L10/README.txt"
  for log_ns in "$KCM_NS" projectsveltos kube-system kubevirt cdi; do
    if namespace_exists "$log_ns"; then
      collect_namespace_pod_logs "$log_ns" "$L10/logs-${log_ns}"
    fi
  done
fi

# Bundle summary (exit_code rollup for collect() outputs)
_summary_ctx="$("${KUBECTL_CMD[@]}" config current-context 2>/dev/null || echo '?')"
{
  echo "k0llector bundle summary"
  echo "version: ${K0LLECTOR_VERSION}"
  echo "generated_utc: $(timestamp_utc)"
  echo "output_dir: $OUT"
  echo "kubectl_context: ${_summary_ctx}"
  echo "kubectl_request_timeout: ${REQUEST_TIMEOUT:-<none>}"
  echo "KUBECONFIG: ${KUBECONFIG:-<unset, default kubeconfig>}"
  echo "layers: $LAYERS"
  echo "bundle_disk_usage:"
  du -sh "$OUT" 2>/dev/null || true
  echo "---"
  echo "Files with non-zero # exit_code (from collect/kubectl steps):"
  _nz=0
  _total_f=0
  while IFS= read -r _f; do
    [[ -f "$_f" ]] || continue
    grep -q '^# exit_code: ' "$_f" 2>/dev/null || continue
    _total_f=$((_total_f + 1))
    _ec="$(grep '^# exit_code: ' "$_f" 2>/dev/null | tail -1)"
    _ec="${_ec##*exit_code: }"
    _ec="${_ec// /}"
    _ec="${_ec//$'\r'/}"
    [[ -z "$_ec" ]] && continue
    if [[ "$_ec" != "0" ]]; then
      _nz=$((_nz + 1))
      echo "  exit=${_ec}  ${_f#"${OUT}/"}"
    fi
  done < <(find "$OUT" -type f | sort)
  if [[ "$_nz" -eq 0 ]]; then
    echo "  (none)"
  fi
  echo "---"
  echo "files_with_exit_code_footer: ${_total_f}"
  echo "non_zero_exit_count: ${_nz}"
} >"$OUT/00-SUMMARY.txt"

# Bundle index (file list)
{
  echo "# k0llector bundle file index @ $(timestamp_utc)"
  echo "# output_dir: $OUT"
  du -sh "$OUT" 2>/dev/null || true
  echo "---"
  find "$OUT" -type f | sort
} >"$OUT/00-INDEX.txt"

echo "k0llector: wrote bundle under: $OUT"
echo "k0llector: summary: $OUT/00-SUMMARY.txt"

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

#!/usr/bin/env bash
# ============================================================================
# k8s-monitor.sh
#
# Collects a broad diagnostic bundle from a Kubernetes/OpenShift cluster:
#   1.  kubelet logs                    - every node (control-plane + worker)
#   2.  kube-system                     - logs, events, yaml of every object
#   3.  ingress-nginx                   - logs, events, yaml of every object
#   4.  a custom namespace              - logs, events, yaml of every object
#   5.  `kubectl top nodes` output      - sampled over time
#   6.  all events in the cluster
#   7.  VM-level metrics (top/vmstat/free/df) on every node
#   8.  workload (pod) metrics          - `kubectl top pods -A`
#   9.  container-level metrics         - `kubectl top pods -A --containers`
#      + host dmesg on every node
#  10.  kernel log (journalctl -k)      - every node
#  11.  container-runtime state         - crictl ps/inspect/logs/events
#  12.  `kubectl describe node`         - every node
#  13.  everything else useful          - cluster-info dump, api-resources,
#                                         CRDs, storage classes, PV, etc.
#
# All settings live in config.sh (same directory). Edit that file first.
#
# USAGE:
#   ./k8s-monitor.sh                 # one-shot snapshot (MODE=snapshot)
#   MODE=watch ./k8s-monitor.sh      # continuous monitoring until Ctrl+C
#   MODE=watch WATCH_MINUTES=30 ./k8s-monitor.sh   # continuous for 30 min
#
#   For a multi-day watch-mode run, launch it detached so it survives a
#   closed terminal/SSH session, e.g.:
#     nohup env MODE=watch WATCH_MINUTES=$((60*24*3)) ./k8s-monitor.sh \
#       > k8s-monitor.out 2>&1 &
#   or run it inside tmux/screen. The script also ignores SIGHUP on its own
#   as a second line of defense, but a proper detached launch is still best.
#
# REQUIRES: kubectl (or oc), jq. ssh only if NODE_ACCESS_METHOD=ssh.
# PERMISSIONS: needs a cluster-admin-ish identity - it reads secrets/yaml in
#              kube-system and creates/deletes pods in a helper namespace.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "${SCRIPT_DIR}/config.sh"

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
log_info() { echo "[$(date '+%H:%M:%S')] INFO  $*"; }
log_warn() { echo "[$(date '+%H:%M:%S')] WARN  $*" >&2; }
log_err()  { echo "[$(date '+%H:%M:%S')] ERROR $*" >&2; }

KC=("$KUBECTL_BIN")
[[ -n "$KUBE_CONTEXT" ]] && KC+=(--context "$KUBE_CONTEXT")

# Run a command, save stdout+stderr to a file, never let failure kill the script
capture() {
    local outfile="$1"; shift
    mkdir -p "$(dirname "$outfile")"
    if "$@" >"$outfile" 2>&1; then
        echo "  ok   -> ${outfile#"$OUTPUT_DIR"/}"
    else
        echo "  FAIL -> ${outfile#"$OUTPUT_DIR"/} (see file for error)"
    fi
}

# Same as capture, but runs a raw shell string (needed for pipes/redirection)
capture_sh() {
    local outfile="$1"; shift
    local cmd="$1"
    mkdir -p "$(dirname "$outfile")"
    if bash -c "$cmd" >"$outfile" 2>&1; then
        echo "  ok   -> ${outfile#"$OUTPUT_DIR"/}"
    else
        echo "  FAIL -> ${outfile#"$OUTPUT_DIR"/} (see file for error)"
    fi
}

BG_PIDS=()   # background tail/streaming PIDs, killed on exit

# Ignore SIGHUP so a closed terminal / dropped SSH session doesn't kill a
# long-running (e.g. multi-day) watch-mode session. Still recommended to
# launch with nohup/tmux/screen/systemd for a proper detached run - see
# README notes in the usage comment at the top of this file.
trap '' HUP

stop_live_streams() {
    if [[ "${#BG_PIDS[@]}" -gt 0 ]]; then
        for pid in "${BG_PIDS[@]}"; do
            kill "$pid" >/dev/null 2>&1 || true
        done
    fi
    BG_PIDS=()
    STREAMED_PODS=()
}

cleanup() {
    log_info "Cleaning up..."
    stop_live_streams
    if [[ "$NODE_ACCESS_METHOD" == "kubectl-debug" && "$KEEP_DEBUG_NAMESPACE" != "true" ]]; then
        log_info "Removing helper namespace ${DEBUG_NAMESPACE}..."
        "${KC[@]}" delete namespace "$DEBUG_NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
    log_info "Output saved under: $OUTPUT_DIR"
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
API_REACHABLE=true

preflight_checks() {
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        log_err "This script needs bash 4+ (uses mapfile/wait -n). You're running ${BASH_VERSION}."
        log_err "On macOS the default /bin/bash is 3.2 - install a newer bash (e.g. 'brew install bash') and re-run with it, or run this from a Linux jump host."
        exit 1
    fi
    command -v "$KUBECTL_BIN" >/dev/null 2>&1 || { log_err "$KUBECTL_BIN not found in PATH"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_err "jq not found in PATH (required for parsing node/pod lists)"; exit 1; }
    if [[ "$NODE_ACCESS_METHOD" == "ssh" ]]; then
        command -v ssh >/dev/null 2>&1 || { log_err "ssh not found in PATH"; exit 1; }
    fi

    if "${KC[@]}" cluster-info >/dev/null 2>&1; then
        API_REACHABLE=true
    else
        API_REACHABLE=false
        if [[ "$NODE_ACCESS_METHOD" == "ssh" && -n "$STATIC_NODE_LIST" ]]; then
            log_warn "Cannot reach the Kubernetes API server - starting anyway in NODE-ONLY mode via SSH."
            log_warn "Namespace / cluster-wide / extra-cluster-state collection will be skipped entirely (all require the API)."
            log_warn "Only node-level data (kubelet/kernel/dmesg/VM-metrics/crictl via SSH) will be collected, for: ${STATIC_NODE_LIST}"
        else
            log_err "Cannot reach the cluster with current kubeconfig/context."
            log_err "To still collect node-level data via SSH when the API is down, set NODE_ACCESS_METHOD=ssh and STATIC_NODE_LIST=\"node1 node2 ...\" in config.sh, then re-run."
            exit 1
        fi
    fi

    mkdir -p "$OUTPUT_DIR"
    log_info "Output directory: $OUTPUT_DIR"
}

# ----------------------------------------------------------------------------
# Node discovery
# ----------------------------------------------------------------------------
ALL_NODES=()
CONTROL_PLANE_NODES=()
WORKER_NODES=()

discover_nodes() {
    if [[ -n "$STATIC_NODE_LIST" ]]; then
        log_info "Using STATIC_NODE_LIST (API discovery skipped)..."
        read -ra ALL_NODES <<< "$STATIC_NODE_LIST"
        CONTROL_PLANE_NODES=()
        WORKER_NODES=("${ALL_NODES[@]}")   # role split needs the API; not available here
        log_info "Using ${#ALL_NODES[@]} statically-configured node(s) - control-plane/worker role unknown without API access"
        return 0
    fi
    log_info "Discovering nodes..."
    local nodes_json
    nodes_json="$("${KC[@]}" get nodes -o json)"
    mapfile -t ALL_NODES < <(echo "$nodes_json" | jq -r '.items[].metadata.name')
    mapfile -t CONTROL_PLANE_NODES < <(echo "$nodes_json" | jq -r '
        .items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null
                        or .metadata.labels["node-role.kubernetes.io/master"] != null)
        | .metadata.name')
    mapfile -t WORKER_NODES < <(comm -23 \
        <(printf '%s\n' "${ALL_NODES[@]}" | sort) \
        <(printf '%s\n' "${CONTROL_PLANE_NODES[@]}" | sort))
    log_info "Found ${#ALL_NODES[@]} node(s): ${#CONTROL_PLANE_NODES[@]} control-plane, ${#WORKER_NODES[@]} worker"
}

# ----------------------------------------------------------------------------
# Node access (kubectl-debug method sets up one helper pod per node)
# ----------------------------------------------------------------------------
sanitize_pod_name() { echo "debug-$(echo "$1" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"; }

setup_node_access() {
    [[ "$NODE_ACCESS_METHOD" != "kubectl-debug" ]] && return 0
    log_info "Setting up per-node helper pods in namespace '${DEBUG_NAMESPACE}'..."
    "${KC[@]}" create namespace "$DEBUG_NAMESPACE" --dry-run=client -o yaml | "${KC[@]}" apply -f - >/dev/null

    for node in "${ALL_NODES[@]}"; do
        local pod; pod="$(sanitize_pod_name "$node")"
        cat <<EOF | "${KC[@]}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${DEBUG_NAMESPACE}
  labels:
    app: k8s-monitor-debug
spec:
  nodeName: ${node}
  hostPID: true
  hostNetwork: false
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: debugger
      image: ${NODE_DEBUG_IMAGE}
      command: ["sleep", "86400"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: host-root
          mountPath: /host
  volumes:
    - name: host-root
      hostPath:
        path: /
EOF
    done

    log_info "Waiting for helper pods to be Ready (up to 120s)..."
    "${KC[@]}" wait --for=condition=Ready pod -l app=k8s-monitor-debug -n "$DEBUG_NAMESPACE" --timeout=120s || \
        log_warn "Some helper pods did not become Ready in time - their data will be missing/partial."
}

# node_exec NODE "shell command string" -> runs on the node, prints to stdout
node_exec() {
    local node="$1"; shift
    local cmd="$1"
    case "$NODE_ACCESS_METHOD" in
        ssh)
            ssh -i "$SSH_KEY" $SSH_OPTS "${SSH_USER}@${node}" "$cmd" 2>&1
            ;;
        kubectl-debug)
            local pod; pod="$(sanitize_pod_name "$node")"
            "${KC[@]}" exec -n "$DEBUG_NAMESPACE" "$pod" -- chroot /host bash -c "$cmd" 2>&1
            ;;
        none)
            echo "SKIPPED: NODE_ACCESS_METHOD=none (read-only mode) - no node connection made" >&2
            return 1
            ;;
        *)
            echo "ERROR: unknown NODE_ACCESS_METHOD=$NODE_ACCESS_METHOD" >&2
            return 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# 1/9/10/11/7: per-node logs, kernel, dmesg, metrics, container runtime
# ----------------------------------------------------------------------------
collect_node_data() {
    local node="$1"
    local dir="${OUTPUT_DIR}/nodes/${node}"
    mkdir -p "$dir"
    log_info "[$node] collecting node-level data..."

    # --- 12: kubectl describe node (API-level, no node access needed) ---
    capture "${dir}/describe-node.txt" "${KC[@]}" describe node "$node"

    if [[ "$NODE_ACCESS_METHOD" == "none" ]]; then
        {
            echo "Read-only mode (NODE_ACCESS_METHOD=none): host-level data was NOT collected for this node."
            echo "No SSH connection and no helper pod were created - only the API-level describe-node.txt above was gathered."
            echo "kubelet log, kernel log, dmesg, VM metrics, and container-runtime (crictl) data require either"
            echo "NODE_ACCESS_METHOD=ssh or NODE_ACCESS_METHOD=kubectl-debug to reach the node itself."
        } > "${dir}/READ_ONLY_MODE_SKIPPED.txt"
        log_info "[$node] read-only mode - host-level data skipped"
        return 0
    fi

    if [[ "$COLLECT_NODE_LOGS" == "true" ]]; then
        # --- 1: kubelet log ---
        if [[ "$PLATFORM_TYPE" == "rke1" ]]; then
            # RKE1 runs kubelet itself as a Docker container, not a systemd service -
            # journalctl has nothing to show here. Pull it via `docker logs` instead.
            node_exec "$node" "docker logs --since=${LOG_LOOKBACK} --timestamps ${RKE1_KUBELET_CONTAINER_NAME} 2>&1" \
                > "${dir}/kubelet.log" 2>&1 \
                && echo "  ok   -> nodes/${node}/kubelet.log (via docker logs, RKE1 mode)" \
                || echo "  FAIL -> nodes/${node}/kubelet.log (docker logs ${RKE1_KUBELET_CONTAINER_NAME} - check RKE1_KUBELET_CONTAINER_NAME matches the actual container name)"
        else
            node_exec "$node" "journalctl -u kubelet --since '${LOG_LOOKBACK} ago' --no-pager" \
                > "${dir}/kubelet.log" 2>&1 \
                && echo "  ok   -> nodes/${node}/kubelet.log" \
                || echo "  FAIL -> nodes/${node}/kubelet.log"
        fi

        # --- 10: kernel log via journalctl ---
        node_exec "$node" "journalctl -k --since '${LOG_LOOKBACK} ago' --no-pager" \
            > "${dir}/kernel-journal.log" 2>&1 \
            && echo "  ok   -> nodes/${node}/kernel-journal.log" \
            || echo "  FAIL -> nodes/${node}/kernel-journal.log"

        # --- 9 (part): dmesg ---
        node_exec "$node" "dmesg -T 2>/dev/null || dmesg" \
            > "${dir}/dmesg.log" 2>&1 \
            && echo "  ok   -> nodes/${node}/dmesg.log" \
            || echo "  FAIL -> nodes/${node}/dmesg.log"

        # --- container-engine service log too (containerd/crio/docker) ---
        node_exec "$node" "journalctl -u containerd --since '${LOG_LOOKBACK} ago' --no-pager 2>/dev/null || \
                            journalctl -u crio --since '${LOG_LOOKBACK} ago' --no-pager 2>/dev/null || \
                            journalctl -u docker --since '${LOG_LOOKBACK} ago' --no-pager 2>/dev/null" \
            > "${dir}/container-engine.log" 2>&1 \
            && echo "  ok   -> nodes/${node}/container-engine.log" \
            || echo "  FAIL -> nodes/${node}/container-engine.log"
    fi

    if [[ "$COLLECT_NODE_METRICS" == "true" ]]; then
        # --- 7: VM-level metrics ---
        node_exec "$node" "
            echo '### uptime ###';        uptime;
            echo '### top -bn1 ###';       top -bn1 | head -40;
            echo '### free -h ###';        free -h;
            echo '### vmstat 1 3 ###';     vmstat 1 3;
            echo '### df -h ###';          df -h;
            echo '### iostat ###';         iostat -xz 1 2 2>/dev/null || echo '(iostat not installed)';
            echo '### disk pressure (nproc) ###'; nproc;
        " > "${dir}/vm-metrics.txt" 2>&1 \
            && echo "  ok   -> nodes/${node}/vm-metrics.txt" \
            || echo "  FAIL -> nodes/${node}/vm-metrics.txt"
    fi

    if [[ "$COLLECT_CONTAINER_RUNTIME" == "true" ]]; then
        local crdir="${dir}/container-runtime"
        mkdir -p "${crdir}/inspect" "${crdir}/logs"

        if [[ "$PLATFORM_TYPE" == "rke1" ]]; then
            # RKE1's runtime is plain Docker, not a CRI runtime - crictl doesn't speak
            # Docker's API, so use the docker CLI directly. This also covers RKE's own
            # platform containers (kubelet, kube-proxy, etcd, etc.) alongside every
            # regular pod container, since on RKE1 they're all just Docker containers.
            node_exec "$node" "docker ps -a" \
                > "${crdir}/ps-a.txt" 2>&1 \
                && echo "  ok   -> nodes/${node}/container-runtime/ps-a.txt (docker, RKE1 mode)" \
                || echo "  FAIL -> nodes/${node}/container-runtime/ps-a.txt"

            node_exec "$node" "docker images" > "${crdir}/images.txt" 2>&1
            node_exec "$node" "docker info" > "${crdir}/info.txt" 2>&1
            node_exec "$node" "docker stats --no-stream --all" > "${crdir}/stats.txt" 2>&1
            node_exec "$node" "docker system df -v" > "${crdir}/system-df.txt" 2>&1

            # bounded event stream snapshot (docker events has no natural end)
            node_exec "$node" "timeout 10 docker events" > "${crdir}/events-10s-sample.log" 2>&1

            # per-container inspect + logs
            local ids
            ids="$(node_exec "$node" "docker ps -aq" 2>/dev/null)"
            local id
            for id in $ids; do
                [[ -z "$id" ]] && continue
                node_exec "$node" "docker inspect ${id}" > "${crdir}/inspect/${id}.json" 2>&1
                node_exec "$node" "docker logs --tail=${CRICTL_LOG_TAIL_LINES} --timestamps ${id}" \
                    > "${crdir}/logs/${id}.log" 2>&1
            done
            echo "  ok   -> nodes/${node}/container-runtime/{inspect,logs}/*  ($(echo "$ids" | wc -w) containers, RKE1 mode)"
        else
            node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} ps -a" \
                > "${crdir}/ps-a.txt" 2>&1 \
                && echo "  ok   -> nodes/${node}/container-runtime/ps-a.txt" \
                || echo "  FAIL -> nodes/${node}/container-runtime/ps-a.txt"

            node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} pods" \
                > "${crdir}/pods.txt" 2>&1

            node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} images" \
                > "${crdir}/images.txt" 2>&1

            node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} stats -a" \
                > "${crdir}/stats.txt" 2>&1

            node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} info" \
                > "${crdir}/info.txt" 2>&1

            # bounded event stream snapshot (crictl events has no natural end)
            node_exec "$node" "timeout 10 ${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} events" \
                > "${crdir}/events-10s-sample.log" 2>&1

            # per-container inspect + logs
            local ids
            ids="$(node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} ps -a -q" 2>/dev/null)"
            local id
            for id in $ids; do
                [[ -z "$id" ]] && continue
                node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} inspect ${id}" \
                    > "${crdir}/inspect/${id}.json" 2>&1
                node_exec "$node" "${CRICTL_BIN} --runtime-endpoint=${RUNTIME_ENDPOINT} logs --tail=${CRICTL_LOG_TAIL_LINES} ${id}" \
                    > "${crdir}/logs/${id}.log" 2>&1
            done
            echo "  ok   -> nodes/${node}/container-runtime/{inspect,logs}/*  ($(echo "$ids" | wc -w) containers)"
        fi
    fi
}

collect_all_nodes() {
    log_info "Collecting per-node data for ${#ALL_NODES[@]} node(s) (max ${MAX_PARALLEL_NODE_JOBS} in parallel)..."
    local running=0
    for node in "${ALL_NODES[@]}"; do
        collect_node_data "$node" &
        running=$((running + 1))
        if [[ "$running" -ge "$MAX_PARALLEL_NODE_JOBS" ]]; then
            wait -n
            running=$((running - 1))
        fi
    done
    wait
}

# ----------------------------------------------------------------------------
# 2/3/4: per-namespace logs, events, yaml of every object
# ----------------------------------------------------------------------------
collect_namespace_data() {
    local ns="$1"
    local dir="${OUTPUT_DIR}/namespaces/${ns}"
    mkdir -p "${dir}/yaml" "${dir}/pods"
    log_info "[ns:$ns] collecting namespace data..."

    if ! "${KC[@]}" get namespace "$ns" >/dev/null 2>&1; then
        log_warn "[ns:$ns] namespace does not exist, skipping"
        echo "namespace not found" > "${dir}/NAMESPACE_NOT_FOUND.txt"
        return 0
    fi

    # --- events ---
    capture "${dir}/events.txt" "${KC[@]}" get events -n "$ns" --sort-by=.lastTimestamp

    # --- yaml of every namespaced object kind that exists in this namespace ---
    # truncate first: in watch mode this function runs every pass, and without
    # this the file would append forever and duplicate content on every pass.
    : > "${dir}/yaml/all-resources.yaml"
    local kind
    "${KC[@]}" api-resources --namespaced=true --verbs=list -o name 2>/dev/null | while read -r kind; do
        local out
        out="$("${KC[@]}" get "$kind" -n "$ns" -o yaml 2>/dev/null)"
        if [[ -n "$out" ]] && ! grep -q '^items: \[\]' <<<"$out"; then
            echo "$out" >> "${dir}/yaml/all-resources.yaml"
            echo "---" >> "${dir}/yaml/all-resources.yaml"
        fi
    done
    echo "  ok   -> namespaces/${ns}/yaml/all-resources.yaml"

    # --- per-pod describe + logs (current and previous, every container) ---
    local pods
    mapfile -t pods < <("${KC[@]}" get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
    for pod in "${pods[@]}"; do
        [[ -z "$pod" ]] && continue
        local pdir="${dir}/pods/${pod}"
        mkdir -p "$pdir"
        capture "${pdir}/describe.txt" "${KC[@]}" describe pod "$pod" -n "$ns"

        local containers
        mapfile -t containers < <("${KC[@]}" get pod "$pod" -n "$ns" \
            -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}{range .spec.initContainers[*]}{.name}{"\n"}{end}' 2>/dev/null)
        for c in "${containers[@]}"; do
            [[ -z "$c" ]] && continue
            capture "${pdir}/${c}.log" "${KC[@]}" logs "$pod" -n "$ns" -c "$c" --since="${LOG_LOOKBACK}" --timestamps
            if [[ "$KEEP_PREVIOUS_CONTAINER_LOGS" == "true" ]]; then
                "${KC[@]}" logs "$pod" -n "$ns" -c "$c" --previous --timestamps \
                    > "${pdir}/${c}-previous.log" 2>/dev/null || rm -f "${pdir}/${c}-previous.log"
            fi
        done
    done
    log_info "[ns:$ns] done (${#pods[@]} pod(s))"
}

collect_all_namespaces() {
    for ns in "${NAMESPACES_TO_MONITOR[@]}"; do
        collect_namespace_data "$ns"
    done
}

# ----------------------------------------------------------------------------
# 5/6/8/9/12: cluster-wide snapshots
# ----------------------------------------------------------------------------
collect_cluster_wide() {
    local dir="${OUTPUT_DIR}/cluster"
    mkdir -p "${dir}/node-describe"
    log_info "Collecting cluster-wide data..."

    # --- 6: all events, all namespaces ---
    capture "${dir}/events-all-namespaces.txt" "${KC[@]}" get events -A --sort-by=.lastTimestamp

    # --- 5: kubectl top nodes (appended with a timestamp header, useful across watch iterations) ---
    {
        echo "=== $(date -Iseconds) ==="
        "${KC[@]}" top nodes 2>&1
        echo
    } >> "${dir}/top-nodes.log"
    echo "  ok   -> cluster/top-nodes.log (appended)"

    # --- 8: workload/pod metrics ---
    {
        echo "=== $(date -Iseconds) ==="
        "${KC[@]}" top pods -A 2>&1
        echo
    } >> "${dir}/top-pods.log"
    echo "  ok   -> cluster/top-pods.log (appended)"

    # --- 9: per-container metrics ---
    {
        echo "=== $(date -Iseconds) ==="
        "${KC[@]}" top pods -A --containers 2>&1
        echo
    } >> "${dir}/top-pods-containers.log"
    echo "  ok   -> cluster/top-pods-containers.log (appended)"

    # --- 12: describe of every node, central copy ---
    for node in "${ALL_NODES[@]}"; do
        capture "${dir}/node-describe/${node}.txt" "${KC[@]}" describe node "$node"
    done
}

# ----------------------------------------------------------------------------
# 13: everything else that might help (broad, catch-all cluster state)
# ----------------------------------------------------------------------------
collect_extra_cluster_state() {
    local dir="${OUTPUT_DIR}/cluster/extra"
    mkdir -p "$dir"
    log_info "Collecting extra cluster state..."

    capture "${dir}/cluster-info.txt"        "${KC[@]}" cluster-info
    capture "${dir}/version.txt"             "${KC[@]}" version
    capture "${dir}/api-resources.txt"       "${KC[@]}" api-resources
    capture "${dir}/api-versions.txt"        "${KC[@]}" api-versions
    capture "${dir}/nodes-wide.txt"          "${KC[@]}" get nodes -o wide
    capture "${dir}/all-pods-wide.txt"       "${KC[@]}" get pods -A -o wide
    capture "${dir}/crds.txt"                "${KC[@]}" get crd
    capture "${dir}/storageclasses.txt"      "${KC[@]}" get storageclass
    capture "${dir}/pv.txt"                  "${KC[@]}" get pv
    capture "${dir}/pdb-all.txt"             "${KC[@]}" get pdb -A
    capture "${dir}/hpa-all.txt"             "${KC[@]}" get hpa -A
    capture "${dir}/componentstatuses.txt"   "${KC[@]}" get componentstatuses
    capture "${dir}/healthz.txt"             "${KC[@]}" get --raw='/healthz?verbose'
    "${KC[@]}" cluster-info dump --output-directory="${dir}/cluster-info-dump" >/dev/null 2>&1 \
        && echo "  ok   -> cluster/extra/cluster-info-dump/" \
        || echo "  FAIL -> cluster/extra/cluster-info-dump/"
}

# ----------------------------------------------------------------------------
# Live streaming (watch mode only): tail -f pod logs + journalctl -f on nodes
# ----------------------------------------------------------------------------
declare -A STREAMED_PODS=()   # tracks "ns/pod" -> already has a live stream running

# Starts one self-reconnecting live-tail for a single pod. kubectl logs -f does NOT
# automatically resume after the container it's watching restarts (confirmed: a
# crash/restart just ends the stream) - so this wraps it in its own retry loop,
# reconnecting within ~2s any time the container restarts or the connection drops.
# This is what actually catches a CrashLoopBackOff's full history, not just the
# first crash.
start_pod_stream() {
    local ns="$1" pod="$2"
    local livedir="${OUTPUT_DIR}/namespaces/${ns}/live"
    mkdir -p "$livedir"
    (
        while true; do
            if ! "${KC[@]}" get pod "$pod" -n "$ns" >/dev/null 2>&1; then
                echo "[$(date '+%H:%M:%S')] --- pod ${ns}/${pod} no longer exists, stopping this stream ---" >> "${livedir}/${pod}.log"
                break
            fi
            echo "[$(date '+%H:%M:%S')] --- (re)connecting log stream for ${ns}/${pod} ---" >> "${livedir}/${pod}.log"
            "${KC[@]}" logs -f -n "$ns" "$pod" --all-containers=true --prefix=true --timestamps \
                >> "${livedir}/${pod}.log" 2>&1
            sleep 2   # container restarted / stream dropped - loop reconnects, picking up the new instance
        done
    ) &
    BG_PIDS+=("$!")
    STREAMED_PODS["${ns}/${pod}"]=1
}

start_live_streams() {
    [[ "$STREAM_LIVE_LOGS" != "true" ]] && return 0
    log_info "Starting live log streams (background, auto-reconnect on drop)..."

    for ns in "${NAMESPACES_TO_MONITOR[@]}"; do
        "${KC[@]}" get namespace "$ns" >/dev/null 2>&1 || continue
        local pods
        mapfile -t pods < <("${KC[@]}" get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        for pod in "${pods[@]}"; do
            [[ -z "$pod" ]] && continue
            start_pod_stream "$ns" "$pod"
        done
    done

    for node in "${ALL_NODES[@]}"; do
        [[ "$NODE_ACCESS_METHOD" == "none" ]] && continue
        local ldir="${OUTPUT_DIR}/nodes/${node}/live"
        mkdir -p "$ldir"
        if [[ "$PLATFORM_TYPE" == "rke1" ]]; then
            ( while true; do
                  node_exec "$node" "docker logs -f --tail=20 --timestamps ${RKE1_KUBELET_CONTAINER_NAME}" >> "${ldir}/kubelet-live.log" 2>&1
                  sleep 5
              done ) &
        else
            ( while true; do
                  node_exec "$node" "journalctl -u kubelet -f --no-pager" >> "${ldir}/kubelet-live.log" 2>&1
                  sleep 5
              done ) &
        fi
        BG_PIDS+=("$!")
        ( while true; do
              node_exec "$node" "journalctl -k -f --no-pager" >> "${ldir}/kernel-live.log" 2>&1
              sleep 5
          done ) &
        BG_PIDS+=("$!")
    done
    log_info "Started ${#BG_PIDS[@]} background stream(s)."
}

# Called every snapshot pass in watch mode. Picks up pods that didn't exist when
# start_live_streams first ran - e.g. a controller replacing a crashed pod with a
# brand-new pod name (a plain restart keeps the same pod/name, which start_pod_stream's
# own retry loop already handles; this covers the "new pod object entirely" case).
# Does not disturb any already-running stream.
ensure_new_pod_streams() {
    [[ "$STREAM_LIVE_LOGS" != "true" ]] && return 0
    local ns pod pods
    for ns in "${NAMESPACES_TO_MONITOR[@]}"; do
        "${KC[@]}" get namespace "$ns" >/dev/null 2>&1 || continue
        mapfile -t pods < <("${KC[@]}" get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        for pod in "${pods[@]}"; do
            [[ -z "$pod" ]] && continue
            if [[ -z "${STREAMED_PODS[${ns}/${pod}]:-}" ]]; then
                log_info "New pod detected: ${ns}/${pod} - starting live log stream for it"
                start_pod_stream "$ns" "$pod"
            fi
        done
    done
}

# ----------------------------------------------------------------------------
# Multi-day safety: cap unbounded live-log growth, warn on low disk
# ----------------------------------------------------------------------------
rotate_live_logs() {
    local f size_mb cap="${LIVE_LOG_MAX_MB}"
    while IFS= read -r -d '' f; do
        size_mb=$(( $(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0) / 1048576 ))
        if [[ "$size_mb" -ge "$cap" ]]; then
            tail -c "$((cap * 1048576 / 2))" "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f"
            echo "[$(date '+%H:%M:%S')] --- log rotated here, older lines removed (exceeded ${cap}MB) ---" >> "$f"
        fi
    done < <(find "$OUTPUT_DIR" -path '*/live/*.log' -print0 2>/dev/null)
}

check_disk_space() {
    local avail_mb
    avail_mb=$(df -Pm "$OUTPUT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$avail_mb" && "$avail_mb" -lt "$DISK_SPACE_WARN_MB" ]]; then
        log_warn "Low disk space: only ${avail_mb}MB free under ${OUTPUT_ROOT} (warn threshold ${DISK_SPACE_WARN_MB}MB)."
    fi
}

# ----------------------------------------------------------------------------
# One full snapshot pass (all sections, gated by COLLECT_* toggles)
# ----------------------------------------------------------------------------
run_snapshot() {
    log_info "==== snapshot pass: $(date -Iseconds) ===="
    "${KC[@]}" cluster-info >/dev/null 2>&1 && API_REACHABLE=true || API_REACHABLE=false

    [[ "$COLLECT_NODE_LOGS" == "true" || "$COLLECT_NODE_METRICS" == "true" || "$COLLECT_CONTAINER_RUNTIME" == "true" ]] \
        && collect_all_nodes

    if [[ "$API_REACHABLE" == "true" ]]; then
        [[ "$COLLECT_NAMESPACES" == "true" ]]          && collect_all_namespaces
        [[ "$COLLECT_CLUSTER_WIDE" == "true" ]]        && collect_cluster_wide
        [[ "$COLLECT_EXTRA_CLUSTER_STATE" == "true" ]] && collect_extra_cluster_state
    else
        log_warn "API server unreachable this pass - namespace/cluster-wide/extra-state collection skipped. Node-level data (if NODE_ACCESS_METHOD=ssh) is unaffected."
    fi
    log_info "==== snapshot pass complete ===="
}

write_manifest() {
    {
        echo "k8s-monitor run"
        echo "started:  $(date -Iseconds)"
        echo "mode:     $MODE"
        echo "context:  ${KUBE_CONTEXT:-<current>}"
        echo "namespaces monitored: ${NAMESPACES_TO_MONITOR[*]}"
        echo "nodes: ${ALL_NODES[*]}"
        echo
        echo "--- directory tree ---"
        find "$OUTPUT_DIR" -maxdepth 3 | sort
    } > "${OUTPUT_DIR}/MANIFEST.txt"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    preflight_checks
    discover_nodes
    setup_node_access

    if [[ "$MODE" == "watch" ]]; then
        start_live_streams
        local elapsed=0
        local since_restart=0
        while true; do
            run_snapshot
            ensure_new_pod_streams
            rotate_live_logs
            check_disk_space
            write_manifest
            if [[ "$WATCH_MINUTES" != "0" && "$elapsed" -ge $((WATCH_MINUTES * 60)) ]]; then
                log_info "Reached WATCH_MINUTES=${WATCH_MINUTES}, stopping."
                break
            fi
            sleep "$WATCH_INTERVAL_SECONDS"
            elapsed=$((elapsed + WATCH_INTERVAL_SECONDS))
            since_restart=$((since_restart + WATCH_INTERVAL_SECONDS))
            if [[ "$since_restart" -ge "$STREAM_RESTART_INTERVAL_SECONDS" ]]; then
                log_info "Refreshing live streams and helper pods (periodic self-heal)..."
                stop_live_streams
                setup_node_access   # idempotent: recreates any missing/evicted debug pods
                start_live_streams
                since_restart=0
            fi
        done
    else
        run_snapshot
        write_manifest
    fi
}

main "$@"

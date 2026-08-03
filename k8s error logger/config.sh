#!/usr/bin/env bash
# ============================================================================
# config.sh — ALL tunable settings for k8s-monitor.sh live here.
#
# HOW TO USE THIS FILE
#   - Section 1 below is the short list of things you actually need to check
#     before your first run.
#   - Everything after that is grouped by what it affects, in the same order
#     the script runs in, with a comment on every line saying:
#       WHAT it does, WHERE in k8s-monitor.sh it's used, WHICH output file(s)
#       it controls.
#   - Anything here can also be overridden on the command line without
#     editing the file, e.g.:
#       CUSTOM_NAMESPACE=billing WATCH_MINUTES=30 ./k8s-monitor.sh
#
# TABLE OF CONTENTS
#   1. REQUIRED — check these before running
#   2. Kubernetes CLI connection
#   3. Namespaces to inspect
#   4. Node access method (kubelet/dmesg/kernel/crictl)
#   5. Container runtime (crictl)
#   6. Output location
#   7. Run mode (snapshot vs watch)
#   8. Section on/off switches
#   9. Performance
#   10. Long-running / multi-day watch mode
# ============================================================================


# ============================================================================
# 1. REQUIRED — check/edit these before your first run
# ============================================================================
# Everything in this section has a real, cluster-specific answer. Everything
# after Section 1 has a sane default and is safe to leave alone.

# Your app's namespace to inspect (item #4 from the original request).
# WHERE USED: added to NAMESPACES_TO_MONITOR in Section 3 below.
CUSTOM_NAMESPACE="${CUSTOM_NAMESPACE:-CHANGE-ME-namespace}"

# "kubectl" for vanilla Kubernetes, "oc" for OpenShift.
# WHERE USED: every API call in k8s-monitor.sh goes through the $KC array,
# which is built from this variable.
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

# How the script reaches node-level data (kubelet/dmesg/kernel/crictl).
# "kubectl-debug" = no SSH. Script creates a helper pod per node (default).
#                   Only k8s API writes this script makes: creates+deletes
#                   one namespace and one pod per node, both self-owned.
# "ssh"           = script SSHes directly into every node. Zero k8s API
#                   writes at all, but needs SSH network access to nodes.
# "none"          = fully read-only AND zero node connections of any kind.
#                   Every kubectl call becomes a plain get/describe/logs/top.
#                   Trade-off: kubelet log, kernel log, dmesg, VM metrics,
#                   and crictl data (items #1, #7, #9, #10, #11) are skipped
#                   entirely - that data only exists on the node itself and
#                   there's no API-level GET for it. Namespaces, events,
#                   yaml dumps, top nodes/pods, node describe, and the extra
#                   cluster state (items #2,3,4,5,6,8,9,12,13) are unaffected.
# WHERE USED: node_exec(), setup_node_access() in k8s-monitor.sh.
# See Section 4 below for the settings that go with kubectl-debug/ssh.
NODE_ACCESS_METHOD="${NODE_ACCESS_METHOD:-ssh}"

# Image for the per-node helper pod (only matters if NODE_ACCESS_METHOD=kubectl-debug).
# In a private/air-gapped cluster this MUST be an image your nodes can
# actually pull — point it at your internal registry/mirror.
# WHERE USED: setup_node_access() — the pod spec's spec.containers[0].image.
NODE_DEBUG_IMAGE="${NODE_DEBUG_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

# Platform style. Changes HOW node-level data is collected, since this
# differs significantly between distributions:
#   "standard" = kubelet runs as a systemd service (journalctl -u kubelet),
#                container runtime is containerd or cri-o (crictl). This is
#                the normal case for kubeadm, RKE2, K3s, EKS/GKE/AKS, etc.
#   "rke1"     = Rancher RKE1. ALL Kubernetes components (kubelet included)
#                run as plain Docker containers on each node, not systemd
#                services - so kubelet logs come from `docker logs kubelet`
#                instead of journalctl, and the runtime to inspect is plain
#                Docker instead of crictl. Regular application pods still
#                work completely normally either way (kubectl logs/exec/top
#                go through the API server, unaffected by this setting) -
#                this only changes how the two node-level sections work.
# WHERE USED: collect_node_data(), start_live_streams() in k8s-monitor.sh.
PLATFORM_TYPE="${PLATFORM_TYPE:-rke1}"

# RKE1-only: the Docker container name RKE gave the kubelet container on
# each node. Almost always "kubelet" (RKE's default naming convention) -
# confirm with `docker ps --format '{{.Names}}'` on one of your nodes if
# unsure. Unused when PLATFORM_TYPE=standard.
RKE1_KUBELET_CONTAINER_NAME="${RKE1_KUBELET_CONTAINER_NAME:-kubelet}"

# Container runtime socket on your nodes — containerd vs cri-o.
# Only used when PLATFORM_TYPE=standard (RKE1 uses plain docker commands
# instead, ignoring this entirely - see PLATFORM_TYPE above).
#   containerd -> unix:///run/containerd/containerd.sock
#   cri-o      -> unix:///run/crio/crio.sock
# WHERE USED: every crictl call inside collect_node_data() in k8s-monitor.sh.
# OUTPUT: nodes/<node>/container-runtime/*
RUNTIME_ENDPOINT="${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}"


# ============================================================================
# 2. KUBERNETES CLI CONNECTION
# ============================================================================

# Which kubeconfig context to use. Empty = whatever "kubectl config
# current-context" currently points to — no --context flag is added.
# WHERE USED: $KC array construction, near the top of k8s-monitor.sh.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"


# ============================================================================
# 3. NAMESPACES TO INSPECT
# ============================================================================
# Each namespace listed here gets: events.txt, yaml/all-resources.yaml, and
# per-pod describe.txt + per-container logs (current + --previous).
# WHERE USED: collect_namespace_data() / collect_all_namespaces().
# OUTPUT: namespaces/<namespace>/...

NAMESPACES_TO_MONITOR=(
    "kube-system"        # item #2 from the original request
    "ingress-nginx"      # item #3 from the original request
    "${CUSTOM_NAMESPACE}"  # item #4 — pulled from Section 1 above
)


# ============================================================================
# 4. NODE ACCESS METHOD — settings for whichever method you picked in Section 1
# ============================================================================

# --- Only used when NODE_ACCESS_METHOD=kubectl-debug (the default) ---

# Namespace the script creates to hold the per-node helper pods.
# WHERE USED: setup_node_access() / cleanup() in k8s-monitor.sh.
DEBUG_NAMESPACE="${DEBUG_NAMESPACE:-k8s-monitor-debug}"

# true = leave the helper pods running after the script exits (faster on
# repeated re-runs, since pods don't need to be recreated each time).
# false (default) = delete the whole DEBUG_NAMESPACE on exit.
# WHERE USED: cleanup() in k8s-monitor.sh.
KEEP_DEBUG_NAMESPACE="${KEEP_DEBUG_NAMESPACE:-false}"

# --- Only used when NODE_ACCESS_METHOD=ssh ---

# User to SSH in as on every node.
SSH_USER="${SSH_USER:-root}"

# Private key used for that SSH connection.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

# Extra ssh(1) options applied to every connection.
# ServerAliveInterval/ServerAliveCountMax matter here specifically: the live
# kubelet/kernel tail streams (journalctl -f) hold an SSH session open
# continuously. Without a keepalive, a quiet node with no new log lines for
# a while could have that connection silently dropped by a NAT/firewall/proxy
# somewhere on the network path, with neither side noticing - these two
# options make ssh actively probe every 30s and give up (so the script's own
# retry loop can reconnect) after 3 missed probes (~90s), instead of hanging
# indefinitely on a dead connection.
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3}"
# WHERE USED (all three above): node_exec() in k8s-monitor.sh.

# Optional: space-separated node hostnames/IPs to use INSTEAD of discovering
# nodes via the Kubernetes API. Leave empty for normal API-based discovery
# (the default, and the only option when NODE_ACCESS_METHOD=kubectl-debug,
# which needs the API regardless).
#
# Why you'd set this: if the API server itself is down/unreachable, the
# script normally can't even start (it needs `kubectl get nodes` just to
# know which nodes exist). Setting this lets it skip that dependency and
# still collect node-level data (kubelet/kernel/dmesg/VM-metrics/crictl) via
# SSH even with the whole control plane down - exactly the "cluster stopped
# working entirely" scenario. Namespace/events/yaml/top/describe data still
# can't be collected without a working API, no matter what - that data only
# exists inside the API server itself.
# Example: STATIC_NODE_LIST="node1.internal node2.internal node3.internal"
# WHERE USED: discover_nodes(), preflight_checks() in k8s-monitor.sh.
STATIC_NODE_LIST="${STATIC_NODE_LIST:-}"


# ============================================================================
# 5. CONTAINER RUNTIME (crictl) — item #11 from the original request
# ============================================================================
# RUNTIME_ENDPOINT itself lives in Section 1 since it's cluster-specific.

# crictl binary name/path, in case it's not on PATH as plain "crictl"
# (e.g. installed at a custom location on your nodes/helper image).
CRICTL_BIN="${CRICTL_BIN:-crictl}"

# How many lines of `crictl logs` to keep per container, so a noisy
# container doesn't produce a multi-GB dump.
# WHERE USED: collect_node_data() -> container-runtime/logs/<id>.log
CRICTL_LOG_TAIL_LINES="${CRICTL_LOG_TAIL_LINES:-500}"


# ============================================================================
# 6. OUTPUT LOCATION
# ============================================================================

# Parent folder for every run. Each run gets its own timestamped
# sub-folder underneath this (see OUTPUT_DIR below), so re-running never
# overwrites a previous collection.
OUTPUT_ROOT="${OUTPUT_ROOT:-./k8s-monitor-output}"

# Timestamp used to name this run's folder. You normally don't need to
# touch this — it's generated automatically.
RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# The actual folder everything gets written to for this run.
# Every function in k8s-monitor.sh writes under $OUTPUT_DIR.
OUTPUT_DIR="${OUTPUT_DIR:-${OUTPUT_ROOT}/${RUN_TIMESTAMP}}"


# ============================================================================
# 7. RUN MODE — one-shot snapshot vs continuous monitoring
# ============================================================================

# "snapshot" = collect everything once and exit.
# "watch"    = repeat the full collection on a loop AND (if
#              STREAM_LIVE_LOGS=true) tail pod/kubelet/kernel logs live
#              in the background the whole time.
# WHERE USED: main() in k8s-monitor.sh.
MODE="${MODE:-watch}"

# In "watch" mode, how often (seconds) to repeat the full snapshot pass
# (events, top nodes/pods, describes, yaml dumps, etc).
# WHERE USED: main()'s loop.
WATCH_INTERVAL_SECONDS="${WATCH_INTERVAL_SECONDS:-300}"

# In "watch" mode, how long to run in total before stopping on its own.
# 0 = run forever until you press Ctrl+C.
# WHERE USED: main()'s loop.
WATCH_MINUTES="${WATCH_MINUTES:-10080}"

# In "watch" mode, also start background `tail -f`-style streams for pod
# logs, kubelet, and kernel log, so you get continuous log files instead
# of just periodic snapshots. Each stream auto-reconnects within seconds if
# it drops (container restart, connection blip) - this is what actually
# captures a CrashLoopBackOff's full history across every restart, since
# `kubectl logs -f` itself does not resume automatically after a container
# restarts. New pods (e.g. a controller replacing a crashed one) are picked
# up within one WATCH_INTERVAL_SECONDS too, not just at the next full restart.
# WHERE USED: start_live_streams(), start_pod_stream(), ensure_new_pod_streams()
# in k8s-monitor.sh.
# OUTPUT: namespaces/<ns>/live/<pod>.log, nodes/<node>/live/{kubelet,kernel}-live.log
STREAM_LIVE_LOGS="${STREAM_LIVE_LOGS:-true}"

# How far back each log-collecting command looks on every snapshot pass
# (used as `--since` for kubectl logs and journalctl).
# WHERE USED: collect_node_data(), collect_namespace_data().
LOG_LOOKBACK="${LOG_LOOKBACK:-1h}"


# ============================================================================
# 8. SECTION ON/OFF SWITCHES — turn whole categories of collection on or off
# ============================================================================
# Every one of these maps to one function call inside run_snapshot() in
# k8s-monitor.sh, and to one top-level folder under $OUTPUT_DIR.

# kubelet.log, kernel-journal.log, dmesg.log, container-engine.log
# OUTPUT: nodes/<node>/*.log
COLLECT_NODE_LOGS="${COLLECT_NODE_LOGS:-true}"

# uptime/top/free/vmstat/df/iostat on every node — item #7
# OUTPUT: nodes/<node>/vm-metrics.txt
COLLECT_NODE_METRICS="${COLLECT_NODE_METRICS:-true}"

# crictl ps/pods/images/stats/info/inspect/logs — item #11
# OUTPUT: nodes/<node>/container-runtime/*
COLLECT_CONTAINER_RUNTIME="${COLLECT_CONTAINER_RUNTIME:-true}"

# Everything under NAMESPACES_TO_MONITOR — items #2, #3, #4
# OUTPUT: namespaces/<ns>/*
COLLECT_NAMESPACES="${COLLECT_NAMESPACES:-true}"

# All-namespace events, top nodes/pods(+containers), node describes — items #5, #6, #8, #9, #12
# OUTPUT: cluster/*
COLLECT_CLUSTER_WIDE="${COLLECT_CLUSTER_WIDE:-true}"

# cluster-info dump, api-resources, CRDs, PV, storageclasses, HPA/PDB, healthz — item #13
# OUTPUT: cluster/extra/*
COLLECT_EXTRA_CLUSTER_STATE="${COLLECT_EXTRA_CLUSTER_STATE:-true}"

# Also fetch `kubectl logs --previous` for every container (captures the
# log of a container that just crashed/restarted), on top of current logs.
# OUTPUT: namespaces/<ns>/pods/<pod>/<container>-previous.log
KEEP_PREVIOUS_CONTAINER_LOGS="${KEEP_PREVIOUS_CONTAINER_LOGS:-true}"


# ============================================================================
# 9. PERFORMANCE
# ============================================================================

# How many nodes to collect from at the same time. Higher = faster overall
# run, but more simultaneous load against the API server / your nodes.
# WHERE USED: collect_all_nodes() in k8s-monitor.sh.
MAX_PARALLEL_NODE_JOBS="${MAX_PARALLEL_NODE_JOBS:-4}"


# ============================================================================
# 10. LONG-RUNNING / MULTI-DAY WATCH MODE
# ============================================================================
# These only matter when MODE=watch and you're leaving it running for a long
# time (hours to days). For a short run you can ignore this whole section.

# How often (seconds) to kill and restart the live tail streams, and
# re-apply the per-node helper pods (kubectl-debug method only).
# Why this exists: a long-lived `kubectl exec`/`ssh` stream can get dropped
# by an idle timeout on a load balancer/proxy somewhere in front of the API
# server, and a node reboot can evict its helper pod - neither is detected
# or recovered from on its own otherwise. This periodic refresh re-creates
# anything missing (kubectl apply is a no-op if the pod is already fine) and
# reconnects all the live streams. Default: 1 hour.
# WHERE USED: main()'s watch loop in k8s-monitor.sh.
STREAM_RESTART_INTERVAL_SECONDS="${STREAM_RESTART_INTERVAL_SECONDS:-3600}"

# Cap on how large any single live-tail log file is allowed to grow before
# it's rotated (oldest content trimmed, newest kept). Without this, a noisy
# pod's live log or a chatty kernel ring buffer could fill your disk over a
# multi-day run. Default: 200MB per file.
# WHERE USED: rotate_live_logs() in k8s-monitor.sh.
# APPLIES TO: namespaces/<ns>/live/*.log, nodes/<node>/live/*.log
LIVE_LOG_MAX_MB="${LIVE_LOG_MAX_MB:-200}"

# If free space under OUTPUT_ROOT drops below this many MB, a warning is
# logged to the console each snapshot pass (the run itself is not stopped -
# check on it if you see this repeatedly during a multi-day run).
# WHERE USED: check_disk_space() in k8s-monitor.sh.
DISK_SPACE_WARN_MB="${DISK_SPACE_WARN_MB:-2048}"

# For a multi-day run, consider also raising WATCH_INTERVAL_SECONDS
# (Section 7 above) from its 60s default to something like 300-900s.
# The live tail streams already give you continuous log coverage; the
# periodic snapshot pass is for state that needs re-sampling (events, top,
# yaml, describe) - re-dumping ALL of that every single minute for days is
# usually more API/disk load than it's worth.

# scripts

Useful scripts to use.

## docker-image-pull

`docker-image-pull-from-txt-file.sh` — reads a list of images (in `docker images` table format) from a text file, pulls each one for `linux/amd64`, and saves it as a gzipped `.tgz` tarball for later loading elsewhere (e.g. air-gapped environments).

## k8s error logger

`k8s-monitor.sh` (configured via `config.sh`) — collects a broad diagnostic bundle from a Kubernetes/OpenShift cluster for troubleshooting: kubelet/kernel/dmesg logs and VM metrics per node, per-namespace pod logs/events/yaml, cluster-wide events and top nodes/pods, container-runtime (crictl/docker) state, and general cluster state (CRDs, storage classes, PVs, etc.). Supports a one-shot snapshot or a continuous "watch" mode with live-tailed, auto-reconnecting pod/node logs, useful for catching intermittent issues like CrashLoopBackOff over a multi-day run.

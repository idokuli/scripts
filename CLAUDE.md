# scripts

Grab-bag of standalone, useful shell scripts. Each subdirectory is independent —
no shared code or build system between them.

## docker-image-pull

`docker-image-pull-from-txt-file.sh` — reads a list of images (in `docker images`
table format, first column only) from a text file, pulls each one for
`linux/amd64`, and saves it as a gzipped `.tgz` tarball (one per image) into an
output directory. Useful for bundling images to move into an air-gapped/private
environment.

Usage: `./docker-image-pull-from-txt-file.sh [images_file] [output_dir]`
(defaults: `imagesid.txt`, `./tgz`).

## k8s error logger

`k8s-monitor.sh` + `config.sh` — collects a broad diagnostic bundle from a
Kubernetes/OpenShift cluster for troubleshooting. All tunables live in
`config.sh` (read its Section 1 "REQUIRED" block before first run — namespace,
`kubectl`/`oc`, node access method, platform type, container runtime endpoint).

Collects, per run:
- per-node: kubelet/kernel/dmesg/container-engine logs, VM metrics, crictl/docker
  container-runtime state
- per-namespace (configurable list): events, full resource yaml dump, per-pod
  describe + per-container logs (current + `--previous`)
- cluster-wide: all events, `top nodes`/`top pods`, node describes, and a broad
  "everything else" dump (CRDs, storage classes, PVs, HPA/PDB, healthz, etc.)

Two modes: `MODE=snapshot` (default one-shot) or `MODE=watch` (repeats on an
interval and live-tails pod/kubelet/kernel logs in the background, with
auto-reconnect on drop — built for catching intermittent issues like
CrashLoopBackOff over a multi-day run). Node access is via `kubectl-debug`
(helper pod per node, default), `ssh`, or `none` (fully read-only, skips
node-level data).

Requires `kubectl`/`oc` and `jq`; bash 4+ (macOS's default `/bin/bash` is 3.2 —
use a Homebrew bash or run from Linux).

#!/usr/bin/env bash
# Pulls all images listed in imagesid.txt (docker images table output) as
# linux/amd64 and saves each one as its own .tgz.
#
# Usage:
#   ./pull_and_save_images.sh [images_file] [output_dir]
#
# Default images_file: imagesid.txt (same format as `docker images`, e.g.:
#   IMAGE                    ID             DISK USAGE   CONTENT SIZE   EXTRA
#   alpine/git:v2.54.0       697cb1c85aef        143MB         38.6MB
#   ...
# Only the first column (IMAGE:TAG) is used; header and blank lines are skipped.

set -euo pipefail

IMAGES_FILE="${1:-imagesid.txt}"
OUT_DIR="${2:-./tgz}"
PLATFORM="linux/amd64"

if [[ ! -f "$IMAGES_FILE" ]]; then
  echo "Error: file not found: $IMAGES_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# skip header line and blank lines, take first column only
tail -n +2 "$IMAGES_FILE" | while IFS= read -r line || [[ -n "$line" ]]; do
  image="$(echo "$line" | awk '{print $1}')"
  [[ -z "$image" ]] && continue

  echo "==> Pulling $image ($PLATFORM)"
  docker pull --platform="$PLATFORM" "$image"

  # turn "alpine/git:v2.54.0" into "alpine_git_v2.54.0.tgz"
  safe_name="$(echo "$image" | tr '/:' '__').tgz"
  out_path="$OUT_DIR/$safe_name"

  echo "==> Saving $image -> $out_path"
  docker save "$image" | gzip > "$out_path"

done

echo "Done. Saved files in $OUT_DIR:"
ls -lh "$OUT_DIR"

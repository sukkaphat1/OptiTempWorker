#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: repack_rootfs.sh SOURCE_ROOTFS OUTPUT_ROOTFS" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_rootfs="$(readlink -f "$1")"
output_rootfs="$(readlink -m "$2")"
work="$(mktemp -d -t opti-repack-XXXXXX)"
case "$work" in
  /tmp/opti-repack-*) ;;
  *) echo "unsafe temporary path: $work" >&2; exit 90 ;;
esac
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT

mkdir -p "$(dirname "$output_rootfs")" "$work/rootfs"
tar -xzf "$source_rootfs" -C "$work/rootfs"
install -m 0755 \
  "$repo_root/linux/overlay/usr/local/lib/opti-temporary-worker/control.py" \
  "$work/rootfs/usr/local/lib/opti-temporary-worker/control.py"
tar --numeric-owner --xattrs --acls --one-file-system \
  -C "$work/rootfs" -czf "$output_rootfs" .
(cd "$(dirname "$output_rootfs")" && sha256sum "$(basename "$output_rootfs")" >"$(basename "$output_rootfs").sha256")
echo "Repacked $output_rootfs"

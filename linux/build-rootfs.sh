#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$repo_root/artifacts}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "build-rootfs.sh must run as root (GitHub Actions uses sudo)." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$repo_root/versions.env"
work="$(mktemp -d -t opti-wsl-rootfs-XXXXXX)"
rootfs="$work/rootfs"
unmount_runtime() {
  mountpoint -q "$rootfs/dev/pts" && umount -lf "$rootfs/dev/pts" || true
  mountpoint -q "$rootfs/dev" && umount -lf "$rootfs/dev" || true
  mountpoint -q "$rootfs/sys" && umount -lf "$rootfs/sys" || true
  mountpoint -q "$rootfs/proc" && umount -lf "$rootfs/proc" || true
}
cleanup() {
  unmount_runtime
  rm -rf "$work"
}
trap cleanup EXIT

command -v debootstrap >/dev/null || {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap ca-certificates curl
}

debootstrap --variant=minbase --arch=amd64 \
  --include=systemd,systemd-sysv,dbus,kmod,ca-certificates,curl,gnupg,iproute2,iptables,procps,unzip,git,python3,python3-venv \
  "$DEBIAN_SUITE" "$rootfs" https://deb.debian.org/debian

mount -t proc proc "$rootfs/proc"
mount --rbind /sys "$rootfs/sys"
mount --make-rslave "$rootfs/sys"
mount --rbind /dev "$rootfs/dev"
mount --make-rslave "$rootfs/dev"
cp /etc/resolv.conf "$rootfs/etc/resolv.conf"

install -d "$rootfs/usr/share/keyrings"
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${DEBIAN_SUITE}.noarmor.gpg" \
  -o "$rootfs/usr/share/keyrings/tailscale-archive-keyring.gpg"
printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian %s main\n' \
  "$DEBIAN_SUITE" >"$rootfs/etc/apt/sources.list.d/tailscale.list"

chroot "$rootfs" /bin/bash -euxo pipefail <<CHROOT
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends tailscale
python3 -m venv /opt/opti-runtime/.venv
/opt/opti-runtime/.venv/bin/python -m pip install --upgrade pip setuptools wheel
/opt/opti-runtime/.venv/bin/python -m pip install \
  --index-url https://download.pytorch.org/whl/cpu "torch==${TORCH_VERSION}"
CHROOT

install -m 0644 "$repo_root/requirements-worker.txt" "$rootfs/tmp/opti-requirements-worker.txt"
chroot "$rootfs" /opt/opti-runtime/.venv/bin/python -m pip install -r /tmp/opti-requirements-worker.txt
rm -f "$rootfs/tmp/opti-requirements-worker.txt"

cp -a "$repo_root/linux/overlay/." "$rootfs/"
chmod 0755 "$rootfs/usr/local/sbin/opti-temporary-worker"
chmod 0755 "$rootfs/usr/local/sbin/opti-wsl-keepalive"
chmod 0755 "$rootfs/usr/local/lib/opti-temporary-worker/control.py"
install -d -m 0700 "$rootfs/var/lib/opti-temporary-worker"
install -d -m 0755 "$rootfs/var/log/opti-temporary-worker" "$rootfs/var/cache/opti-temporary-worker"
: >"$rootfs/etc/machine-id"
rm -f "$rootfs/var/lib/dbus/machine-id"

chroot "$rootfs" /opt/opti-runtime/.venv/bin/python - <<'PY'
import importlib.metadata as metadata
import numpy, torch, RocketSim, rlgym_sim, requests, psutil
assert numpy.__version__ == "1.26.4"
assert torch.__version__.split("+")[0] == "2.10.0"
assert metadata.version("rocketsim") == "2.2.1"
assert metadata.version("rlgym-sim") == "1.2.6"
assert not torch.cuda.is_available()
print("Pinned Opti CPU runtime verified")
PY

chroot "$rootfs" apt-get clean
rm -rf "$rootfs/var/lib/apt/lists/"* "$rootfs/var/cache/apt/archives/"*.deb
find "$rootfs" -type d -name __pycache__ -prune -exec rm -rf {} +

# Runtime bind mounts are needed by chroot package installation but must not be
# present while creating the portable WSL import tar. Apart from avoiding live
# `/sys` changes during tar, this guarantees the archive contains no host view.
unmount_runtime
archive="$output/opti-temporary-worker-rootfs.tar.gz"
tar --numeric-owner --xattrs --acls --one-file-system -C "$rootfs" -czf "$archive" .
(cd "$output" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")
echo "Created $archive"

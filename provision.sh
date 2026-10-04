#!/usr/bin/env bash
# provision.sh -- one-shot provisioning of the kernel build container data.
#
# Usage: ./provision.sh <CONTAINER_DATA>
#
# Hard constraints (do not relax):
#   * the base image is the stock docker.io/library/ubuntu:26.04 pulled from
#     the default registry -- no persistent image is built or committed
#   * everything installed by apt lands on disk under CONTAINER_DATA only:
#     a throwaway container runs the installation, is exported with
#     `podman export`, and the tarball is unpacked to CONTAINER_DATA/rootfs
#     (an existing rootfs from an earlier provision is rebuilt from scratch)
#
# Contents: packages.list (with a clang-21 -> clang fallback), an arm64
# static busybox extracted from the busybox-static:arm64 deb at
# /opt/busybox-arm64/bin/busybox, and /opt/build-env.txt recording the toolchain
# choice and every package version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${1:?usage: provision.sh <CONTAINER_DATA>}"

BASE="docker.io/library/ubuntu:26.04"
NAME="sm8850-provision-$$"

command -v podman >/dev/null 2>&1 || { echo "provision.sh: podman not found" >&2; exit 1; }
[ -f "${HERE}/packages.list" ] || { echo "provision.sh: packages.list missing" >&2; exit 1; }

# The build container must run NATIVE x86_64: kernel host tools (conf,
# fixdep, ...) built by it are exec'd directly.  A shared host can have the
# ubuntu:26.04 tag overwritten by a foreign-arch pull; detect that and
# recover under a local alias, preserving the foreign image under its own
# alias instead of clobbering it.
if ! podman run --rm --entrypoint /bin/uname "${BASE}" -m 2>/dev/null | grep -q '^x86_64$'; then
    echo "[provision] ${BASE} on this host is not amd64 (tag overwritten by a foreign-arch pull?)" >&2
    podman tag "${BASE}" localhost/ubuntu-26.04-foreign 2>/dev/null || true
    LOCAL="localhost/iceland-base:ubuntu-26.04-amd64"
    if ! podman image exists "${LOCAL}"; then
        id="$(podman pull --quiet --arch amd64 "${BASE}")" || { echo "provision.sh: amd64 pull failed" >&2; exit 1; }
        podman tag "${id}" "${LOCAL}"
    fi
    BASE="${LOCAL}"
    echo "[provision] using ${BASE}" >&2
fi

mkdir -p "${DATA}"
WORK="$(mktemp -d "${DATA}/provision.XXXXXX")"
cleanup() { podman rm -f -t 0 "${NAME}" >/dev/null 2>&1 || true; rm -rf "${WORK}"; }
trap cleanup EXIT

echo "[provision] running one-shot stock ${BASE} container to install the build environment" >&2
podman run --name "${NAME}" \
    -v "${HERE}/packages.list:/packages.list:ro" \
    --entrypoint /bin/bash \
    "${BASE}" -euo pipefail -c '
# ---- inside the throwaway container -------------------------------------
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND LC_ALL=C TZ=UTC

apt-get update

# install everything from packages.list; if versioned toolchain packages
# (the -21 suffixes) are missing from the archive, retry with the version
# stripped (clang-21 -> clang) and record the substitution
PKGS="$(grep -E -v "^[[:space:]]*(#|$)" /packages.list | xargs)"
TOOLCHAIN="versioned as listed in packages.list (${PKGS})"
if ! apt-get install -y --no-install-recommends ${PKGS}; then
    FALLBACK="$(for p in ${PKGS}; do printf "%s " "${p%%-[0-9]*}"; done)"
    echo "NOTE: packages.list install failed; retrying with: ${FALLBACK}" >&2
    apt-get install -y --no-install-recommends ${FALLBACK}
    TOOLCHAIN="fallback, version suffixes stripped (${FALLBACK})"
fi

# versioned toolchain packages do not provide the unversioned command names
# kbuild expects with LLVM=1; provide them via /usr/local/bin symlinks
for t in clang clang++ lld ld.lld \
         llvm-ar llvm-as llvm-nm llvm-objcopy llvm-objdump \
         llvm-profdata llvm-ranlib llvm-readelf llvm-strip llvm-config; do
    command -v "$t" >/dev/null 2>&1 || [ ! -x "/usr/bin/$t-21" ] \
        || ln -sf "/usr/bin/$t-21" "/usr/local/bin/$t"
done

# ---- arm64 static busybox for the debug initrd --------------------------
# extracted, not installed; Ubuntu merged-usr debs unpack the binary to
# usr/bin/busybox, so locate it and normalize to bin/busybox (a real file,
# not a symlink)
dpkg --add-architecture arm64
apt-get update
mkdir -p /opt/busybox-arm64 /tmp/busybox-dl
cd /tmp/busybox-dl
apt-get download busybox-static:arm64
dpkg -x busybox-static_*_arm64.deb /opt/busybox-arm64
bb="$(find /opt/busybox-arm64 -type f -name busybox -print -quit)"
[ -n "${bb}" ] || { echo "ERROR: no busybox binary in the arm64 deb" >&2; exit 1; }
mkdir -p /opt/busybox-arm64/bin
mv "${bb}" /opt/busybox-arm64/bin/busybox
chmod 0755 /opt/busybox-arm64/bin/busybox
file /opt/busybox-arm64/bin/busybox
file /opt/busybox-arm64/bin/busybox | grep -q aarch64
file /opt/busybox-arm64/bin/busybox | grep -q "statically linked"

# ---- record the build environment ---------------------------------------
{
    echo "base-image: docker.io/library/ubuntu:26.04 (stock, one-shot container)"
    echo "toolchain: ${TOOLCHAIN}"
    echo "busybox-arm64-deb: $(cd /tmp/busybox-dl && ls busybox-static_*_arm64.deb)"
    echo
    echo "clang: $(clang --version | head -1)"
    echo "ld.lld: $(ld.lld --version | head -1)"
    echo "busybox(file): $(file -b /opt/busybox-arm64/bin/busybox)"
    echo
    dpkg-query -W -f="\${binary:Package}\t\${Version}\n" $(grep -E -v "^[[:space:]]*(#|$)" /packages.list | xargs) busybox-static:arm64 2>/dev/null || true
} > /opt/build-env.txt

# ---- cleanup -------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/busybox-dl /var/tmp/*
'

echo "[provision] exporting the container rootfs" >&2
podman export "${NAME}" -o "${WORK}/rootfs.tar"

echo "[provision] unpacking to ${DATA}/rootfs" >&2
rm -rf "${DATA}/rootfs"
mkdir -p "${DATA}/rootfs"
# rootless unpack: keep modes, ignore ownership and any device nodes from
# the image layout (podman provides /dev at runtime)
tar -xf "${WORK}/rootfs.tar" -C "${DATA}/rootfs" --no-same-owner \
    --exclude='dev/*' --exclude='./dev/*' \
    || { echo "provision.sh: rootfs unpack failed" >&2; exit 1; }

[ -x "${DATA}/rootfs/usr/bin/bash" ] || { echo "provision.sh: unpacked rootfs has no /usr/bin/bash" >&2; exit 1; }
[ -f "${DATA}/rootfs/opt/busybox-arm64/bin/busybox" ] || { echo "provision.sh: busybox missing in unpacked rootfs" >&2; exit 1; }
cp "${DATA}/rootfs/opt/build-env.txt" "${DATA}/build-env.txt"

echo "[provision] done: ${DATA}/rootfs (+ build-env.txt)" >&2

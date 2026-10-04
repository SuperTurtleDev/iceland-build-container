#!/usr/bin/env bash
# runin.sh -- the single entry point into the sm8850 kernel build container.
#
# Usage:
#   CONTAINER_DATA=<directory> [EXTRA_MOUNTS="-v host:container[:ro] ..."] \
#       ./runin.sh <cmdline...>
#
# CONTAINER_DATA holds the provisioned container data:
#   CONTAINER_DATA/rootfs       unpacked root filesystem (used via
#                               `podman run --rootfs`)
#   CONTAINER_DATA/commit       identity of the podman_container repo state
#                               (HEAD, plus a dirty suffix when uncommitted
#                               changes exist) that provisioned the rootfs;
#                               a mismatch triggers a fresh provision
#   CONTAINER_DATA/build-env.txt copy of /opt/build-env.txt from provisioning
#                               (toolchain choice + package versions)
#
# The container data is reprovisioned from scratch whenever the recorded
# identity does not match the current state of this repository.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "${CONTAINER_DATA:-}" ] || { echo "runin.sh: CONTAINER_DATA is not set" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || { echo "runin.sh: podman not found" >&2; exit 1; }
[ $# -ge 1 ] || { echo "runin.sh: nothing to run" >&2; exit 1; }

# Identity of this repository: HEAD; a "-dirty-<hash>" suffix derived from the
# porcelain status makes uncommitted changes (e.g. provision tweaks) trigger a
# reprovision as well.
repo_identity() {
    local head status_hash
    head="$(git -C "${HERE}" rev-parse HEAD 2>/dev/null || printf 'nogit')"
    if [ -n "$(git -C "${HERE}" status --porcelain 2>/dev/null)" ]; then
        status_hash="$(git -C "${HERE}" status --porcelain 2>/dev/null | LC_ALL=C sort \
            | sha256sum | cut -c1-12)"
        printf '%s-dirty-%s\n' "${head}" "${status_hash}"
    else
        printf '%s\n' "${head}"
    fi
}

CURRENT="$(repo_identity)"

if [ ! -f "${CONTAINER_DATA}/commit" ] || [ "$(cat "${CONTAINER_DATA}/commit")" != "${CURRENT}" ]; then
    echo "[runin] (re)provisioning ${CONTAINER_DATA} for repo state ${CURRENT}" >&2
    bash "${HERE}/provision.sh" "${CONTAINER_DATA}"
    printf '%s\n' "${CURRENT}" > "${CONTAINER_DATA}/commit"
fi

# NOTE: podman (pflag) stops parsing options at the first positional
# argument; with --rootfs that positional is the rootfs path, so all options
# (the mounts) must come before it.
exec podman run --rm ${EXTRA_MOUNTS:-} --rootfs "${CONTAINER_DATA}/rootfs" "$@"

#!/usr/bin/env bash
# runin.sh -- the single entry point into the sm8850 kernel build container.
#
# Usage:
#   CONTAINER_DATA=<directory> [CONTAINER_ARCH=amd64|arm64] \
#       [EXTRA_MOUNTS="-v host:container[:ro] ..."] ./runin.sh <cmdline...>
#
# CONTAINER_ARCH (default amd64) selects the provisioned rootfs architecture
# (see provision.sh); each architecture needs its own CONTAINER_DATA.
#
# CONTAINER_DATA holds the provisioned container data:
#   CONTAINER_DATA/rootfs       unpacked root filesystem (used via
#                               `podman run --rootfs`)
#   CONTAINER_DATA/commit       identity of the podman_container repo state
#                               (HEAD, plus a dirty suffix when uncommitted
#                               changes exist) and the architecture that
#                               provisioned the rootfs; a mismatch triggers
#                               a fresh provision
#   CONTAINER_DATA/build-env.txt copy of /opt/build-env.txt from provisioning
#                               (toolchain choice + package versions)
#
# The container data is reprovisioned from scratch whenever the recorded
# identity does not match the current state of this repository.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "${CONTAINER_DATA:-}" ] || { echo "runin.sh: CONTAINER_DATA is not set" >&2; exit 1; }
CONTAINER_ARCH="${CONTAINER_ARCH:-amd64}"
command -v podman >/dev/null 2>&1 || { echo "runin.sh: podman not found" >&2; exit 1; }
[ $# -ge 1 ] || { echo "runin.sh: nothing to run" >&2; exit 1; }

# Identity of this repository: HEAD; a "-dirty-<hash>" suffix derived from
# the porcelain status AND the content of the changes (tracked diff plus
# untracked files) makes every uncommitted edit -- e.g. adding a package to
# packages*.list -- trigger a reprovision as well.  Content must be part of
# the hash: the porcelain status alone does not change when an already-dirty
# or untracked file is edited further.
repo_identity() {
    local head status_hash
    head="$(git -C "${HERE}" rev-parse HEAD 2>/dev/null || printf 'nogit')"
    if [ -n "$(git -C "${HERE}" status --porcelain 2>/dev/null)" ]; then
        status_hash="$(
            {
                git -C "${HERE}" status --porcelain 2>/dev/null | LC_ALL=C sort
                git -C "${HERE}" diff 2>/dev/null
                git -C "${HERE}" ls-files --others --exclude-standard -z 2>/dev/null \
                    | xargs -0 -r sha256sum 2>/dev/null
            } | sha256sum | cut -c1-12)"
        printf '%s-dirty-%s\n' "${head}" "${status_hash}"
    else
        printf '%s\n' "${head}"
    fi
}

CURRENT="$(repo_identity) ${CONTAINER_ARCH}"

if [ ! -f "${CONTAINER_DATA}/commit" ] || [ "$(cat "${CONTAINER_DATA}/commit")" != "${CURRENT}" ]; then
    echo "[runin] (re)provisioning ${CONTAINER_DATA} for repo state ${CURRENT}" >&2
    bash "${HERE}/provision.sh" "${CONTAINER_DATA}" "${CONTAINER_ARCH}"
    printf '%s\n' "${CURRENT}" > "${CONTAINER_DATA}/commit"
fi

# NOTE: podman (pflag) stops parsing options at the first positional
# argument; with --rootfs that positional is the rootfs path, so all options
# (the mounts) must come before it.
exec podman run --rm ${EXTRA_MOUNTS:-} --rootfs "${CONTAINER_DATA}/rootfs" "$@"

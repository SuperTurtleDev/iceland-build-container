# podman_container

Self-contained build container provisioning for the OnePlus Pad 4 (SM8850,
iceland) mainline kernel. No persistent image is ever built: the build
environment is provisioned as plain on-disk data and run through
`podman run --rootfs`.

## Layout

- `runin.sh`      the only entry point (see below)
- `provision.sh`  one-shot provisioning of `CONTAINER_DATA` (called
                  automatically by `runin.sh`; not usually invoked by hand)
- `packages.list` everything apt installs into the container

## runin.sh

```
CONTAINER_DATA=<directory> [EXTRA_MOUNTS="-v host:container[:ro] ..."] \
    ./runin.sh <cmdline...>
```

Example (kernel metarepo build stages):

```
CONTAINER_DATA=$OUT/podman-data \
EXTRA_MOUNTS="-v $META:/work/src:ro -v $OUT:/work/out" \
    ./runin.sh bash /work/src/scripts/build-kernel.sh
```

## CONTAINER_DATA semantics

| file/dir                  | meaning |
|---------------------------|---------|
| `rootfs/`                 | unpacked container root filesystem, executed via `podman run --rootfs` |
| `commit`                  | identity of the `podman_container` repo state that provisioned the data: the HEAD commit hash, plus a `-dirty-<hash>` suffix when the repository has uncommitted changes |
| `build-env.txt`           | copy of `/opt/build-env.txt`: toolchain choice, clang/lld/busybox versions, every package version installed by apt |

`runin.sh` reprovisions `CONTAINER_DATA` from scratch whenever `commit` is
missing or does not match the current repository state (a new HEAD or any
uncommitted change triggers it). Otherwise the existing data is reused as is.

## Provisioning

`provision.sh` runs a one-shot **stock** `docker.io/library/ubuntu:26.04`
container that

1. installs everything from `packages.list` (falling back from `clang-21`
   & co. to the unversioned names if the archive lacks them, recording the
   choice),
2. provides the unversioned toolchain command names (`clang`, `ld.lld`,
   `llvm-*`) as symlinks when only versioned packages were installed,
3. extracts an arm64 static busybox from the `busybox-static:arm64` deb to
   `/opt/busybox-arm64/bin/busybox` (normalizing the merged-usr
   `usr/bin/busybox` path, verifying it is a statically linked aarch64 ELF),
4. writes `/opt/build-env.txt` with the package versions and cleans the apt
   caches.

The finished container is exported with `podman export` and unpacked into
`CONTAINER_DATA/rootfs` — everything apt installed lands on disk under
`CONTAINER_DATA`, nothing is committed to the podman image store.

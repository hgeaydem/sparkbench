#!/usr/bin/env bash
# Ensure a working `docker` CLI for the engines and services.
#
#  - RHEL: podman + podman-docker (Red Hat's official docker -> podman shim).
#          Containers run ROOTLESS as SPARK_USER; nvidia-container-toolkit
#          provides the --gpus hook. The engine launch lines (--gpus all,
#          --privileged, --ipc=host, --network host) are unchanged and work
#          as-is with this setup.
#  - debian/ubuntu: docker.io (or any existing docker install).
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common.sh
source "${INSTALL_DIR}/common.sh"

nvidia_hook_present() {
  local d
  for d in /usr/share/containers/oci/hooks.d /etc/containers/oci/hooks.d \
           "${HOME}/.config/containers/oci/hooks.d"; do
    [[ -f "${d}/nvidia-hook.json" ]] && return 0
  done
  return 1
}

case "${SPARK_DISTRO}" in
  rhel)
    if ! command -v podman >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
      # podman-docker provides the `docker` CLI as a podman shim
      pkg_install podman podman-docker
    fi
    if ! dnf -q list installed nvidia-container-toolkit >/dev/null 2>&1 && ! nvidia_hook_present; then
      # GPU passthrough for --gpus all (hook + nvidia-ctk)
      pkg_install nvidia-container-toolkit
    fi
    ensure_rootless_subuids
    echo "container runtime: podman (rootless, ${SPARK_USER}) + podman-docker shim"
    ;;
  *)
    if ! command -v docker >/dev/null 2>&1; then
      pkg_install docker.io
    fi
    echo "container runtime: docker"
    ;;
esac

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker CLI is present but cannot talk to the daemon/runtime" >&2
  exit 1
fi

if nvidia_hook_present || command -v nvidia-ctk >/dev/null 2>&1; then
  echo "nvidia container hook: present (--gpus all will work)"
else
  echo "WARN: nvidia-container-toolkit hook not found — --gpus containers will fail" >&2
fi

#!/usr/bin/env bash
# Python venv at /opt/spark/venv — the shebang for every API entrypoint
# (spark-gpu-api, spark-hf-api, spark-inference-api, ...), the `hf` CLI, and
# the yaml/config checks in the engine modules.
#
#  - RHEL: `python3 -m venv` ships with ensurepip (no python3-venv package).
#  - debian: python3-venv + python3-pip packages.
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common.sh
source "${INSTALL_DIR}/common.sh"

VENV="${SPARK_ROOT}/venv"

if [[ -x "${VENV}/bin/python" ]] && "${VENV}/bin/python" -c "import yaml, huggingface_hub" 2>/dev/null; then
  echo "venv already OK: ${VENV}"
  exit 0
fi

case "${SPARK_DISTRO}" in
  rhel) pkg_install python3 ;;
  *)    pkg_install python3-venv python3-pip ;;
esac

if [[ ! -x "${VENV}/bin/python" ]]; then
  python3 -m venv "${VENV}"
fi

"${VENV}/bin/python" -m pip install --quiet --upgrade pip
"${VENV}/bin/python" -m pip install --quiet pyyaml huggingface_hub

echo "venv ready: ${VENV} ($( "${VENV}/bin/python" --version 2>&1 ))"

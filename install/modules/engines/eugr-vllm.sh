#!/usr/bin/env bash
# eugr/spark-vllm-docker + Qwen3.6 NVFP4 local recipe
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common.sh
source "${INSTALL_DIR}/common.sh"
STAGING="${SPARK_STAGING}"
REPO="${SPARK_ROOT}/vendor/spark-vllm-docker"
REPO_URL="https://github.com/eugr/spark-vllm-docker.git"

echo "==> Sync services, scripts, docs"
mkdir -p "${SPARK_ROOT}/vendor" "${SPARK_ROOT}/services"
if [[ "${STAGING}" != "${SPARK_ROOT}" ]]; then
  cp "${STAGING}/services/eugr-qwen36-local.yaml" "${SPARK_ROOT}/services/"
  cp "${STAGING}/scripts/spark-eugr" "${SPARK_ROOT}/scripts/"
fi
chmod +x "${SPARK_ROOT}/scripts/spark-eugr"
# CLI: install/modules/core/cli.sh → spark engine eugr

echo "==> Stop stock vLLM container (if running)"
docker stop spark-vllm-qwen36 2>/dev/null || true
docker rm spark-vllm-qwen36 2>/dev/null || true

echo "==> Clone or update eugr/spark-vllm-docker"
pkg_install git
if [[ -d "${REPO}/.git" ]]; then
  git -C "${REPO}" pull --ff-only
else
  git clone --depth 1 "${REPO_URL}" "${REPO}"
fi
chown -R "${SPARK_USER}:${SPARK_USER}" "${REPO}"

# RHEL container-tools enforce short-name resolution: a non-interactive
# `docker pull eugr/spark-vllm:latest` fails ("cannot prompt without a TTY").
# Normalize the prebuilt runner image to a fully-qualified docker.io name.
# Idempotent: the `"` anchor does not match already-qualified values.
sed -i -e 's|"eugr/spark-vllm-b12x:|"docker.io/eugr/spark-vllm-b12x:|' \
       -e 's|"eugr/spark-vllm:|"docker.io/eugr/spark-vllm:|' "${REPO}/build-and-copy.sh"

echo "==> Build vllm-node image (downloads prebuilt wheels when available)"
sudo -u "${SPARK_USER}" bash -lc "cd '${REPO}' && ./build-and-copy.sh"

if [[ "${SPARK_ENGINE_INSTALL_ONLY:-0}" == "1" ]]; then
  echo
  echo "Done (install only: SPARK_ENGINE_INSTALL_ONLY=1 — engine NOT started)."
  echo "  Start later:  spark engine eugr up"
  exit 0
fi

echo "==> Start Qwen3.6 NVFP4 via eugr recipe (daemon)"
sudo -u "${SPARK_USER}" "${SPARK_ROOT}/scripts/spark-eugr" up

echo
echo "Done."
echo "  Build/run logs: spark engine eugr logs"
echo "  Status:         spark engine eugr status"
echo "  Chat UI:        http://sparky:3000"
echo "  vLLM API:       http://sparky:8000/v1"

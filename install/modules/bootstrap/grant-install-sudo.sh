#!/usr/bin/env bash
# One-time: enter sudo password once, then install runs without prompting again.
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common.sh
source "${INSTALL_DIR}/common.sh"

SUDOERS="/etc/sudoers.d/spark-install"
RULE="${SPARK_USER} ALL=(ALL) NOPASSWD: ${SPARK_STAGING}/install/spark-install, ${SPARK_ROOT}/install/spark-install, ${SPARK_STAGING}/install/modules/*/*.sh, ${SPARK_ROOT}/install/modules/*/*.sh"

echo "This will:"
echo "  1. Allow passwordless sudo for install/spark-install and install/modules/*/*.sh (user: ${SPARK_USER})"
echo "  2. Run the Netdata + portal base module"
echo

# Rewrite the rule unless it is already exactly present — this also covers
# re-deploys under a different SPARK_USER (e.g. a previous trial account).
if [ -f "$SUDOERS" ] && grep -qxF "$RULE" "$SUDOERS" 2>/dev/null; then
  echo "OK: sudoers rule already present"
else
  echo "$RULE" | sudo tee "$SUDOERS" >/dev/null
  sudo chmod 440 "$SUDOERS"
  sudo visudo -cf "$SUDOERS"
  echo "OK: sudoers rule added ($SUDOERS)"
fi

sudo bash "${SPARK_ROOT}/install/modules/core/portal-base.sh"

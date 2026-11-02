#!/usr/bin/env bash
# Auto-refresh model inventory: systemd timer + inotify + nginx no-cache
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common.sh
source "${INSTALL_DIR}/common.sh"

echo "==> Sync portal + scripts"
mkdir -p "${SPARK_ROOT}/portal/archive/v1"
cp "${SPARK_STAGING}/portal/archive/v1/models.html" "${SPARK_ROOT}/portal/archive/v1/" 2>/dev/null \
  || cp "${SPARK_STAGING}/portal/models.html" "${SPARK_ROOT}/portal/archive/v1/" 2>/dev/null || true
cp "${SPARK_STAGING}/scripts/spark-inventory-refresh.sh" "${SPARK_STAGING}/scripts/spark-inventory-watch.sh" "${SPARK_ROOT}/scripts/"
chmod +x "${SPARK_ROOT}/scripts/spark-inventory-refresh.sh" "${SPARK_ROOT}/scripts/spark-inventory-watch.sh"


echo "==> Runtime dir + CLI"
mkdir -p "${SPARK_ROOT}/run"
chmod 1777 "${SPARK_ROOT}/run"
# CLI: install/modules/core/cli.sh → spark models inventory

echo "==> nginx: portal + API proxies (via common.sh)"
maybe_write_nginx_portal_site

echo "==> Install inotify-tools (optional watcher)"
if ! command -v inotifywait >/dev/null 2>&1; then
  case "${SPARK_DISTRO}" in
    rhel)
      # inotify-tools lives in EPEL (preconfigured on the GB10 RHEL image)
      if ! dnf -q list available inotify-tools >/dev/null 2>&1; then
        echo "WARN: inotify-tools not available (EPEL repo missing?) — refresh falls back to timer only" >&2
        exit 0
      fi
      dnf -y install inotify-tools >/dev/null
      ;;
    *)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y -qq inotify-tools
      ;;
  esac
fi

echo "==> systemd: periodic refresh (every 2 min)"
cat > /etc/systemd/system/spark-inventory-refresh.service <<'UNIT'
[Unit]
Description=Rebuild Spark model inventory JSON
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/spark/scripts/spark-inventory-refresh.sh
Nice=10
IOSchedulingClass=idle
UNIT

cat > /etc/systemd/system/spark-inventory-refresh.timer <<'TIMER'
[Unit]
Description=Refresh Spark model inventory every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
TIMER

echo "==> systemd: inotify watcher (debounced on /models changes)"
cat > /etc/systemd/system/spark-inventory-watch.service <<'WATCH'
[Unit]
Description=Watch /models and rebuild inventory (debounced)
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/opt/spark/scripts/spark-inventory-watch.sh
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
WATCH

systemctl daemon-reload
systemctl enable --now spark-inventory-refresh.timer
systemctl enable --now spark-inventory-watch.service

"${SPARK_ROOT}/scripts/spark-inventory-refresh.sh" || true

echo
echo "Done."
echo "  Timer:  spark-inventory-refresh.timer (every 2 min)"
echo "  Watch:  spark-inventory-watch.service (/models inotify)"
echo "  Page:   http://sparky/models.html (polls JSON every 30s)"

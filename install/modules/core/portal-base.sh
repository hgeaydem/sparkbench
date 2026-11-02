#!/usr/bin/env bash
# Portal foundation: netdata (telemetry) + nginx serving /opt/spark/portal
# with all API proxy routes.
#
# Distro-aware via install/common.sh helpers:
#  - RHEL:   dnf, firewalld, /etc/nginx/conf.d, SELinux labels
#  - debian: apt, ufw, /etc/nginx/sites-enabled symlink
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common.sh
source "${INSTALL_DIR}/common.sh"

# --- Netdata (system telemetry, port 19999) ------------------------------------
if command -v netdata >/dev/null 2>&1; then
  echo "netdata already installed"
else
  curl -s https://my-netdata.io/kickstart.sh | bash >/dev/null 2>&1 \
    || echo "WARN: netdata install failed (continuing)"
fi
# Expose netdata on the LAN (it binds 127.0.0.1 by default).
if [[ -f /etc/netdata/conf.d/web.conf ]]; then
  grep -qE '^  bind: "0\.0\.0\.0"' /etc/netdata/conf.d/web.conf \
    || sed -i 's/^  bind: "127.0.0.1"/  bind: "0.0.0.0"/' /etc/netdata/conf.d/web.conf
fi
systemctl enable --now netdata >/dev/null 2>&1 || true

# --- nginx + rsync --------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
  pkg_install nginx rsync
fi

# Firewall: portal (:80) + netdata (:19999) — no-op if no firewall is active.
firewall_open_port 80 "spark portal"
firewall_open_port 19999 "netdata"

mkdir -p "${SPARK_ROOT}/portal"

if [[ ! -f /etc/nginx/nginx.conf ]]; then
  echo "ERROR: nginx not configured (missing /etc/nginx/nginx.conf)" >&2
  exit 1
fi

# Writes the site (conf.d on RHEL / sites-available on debian), retires the
# stock default site, labels content for SELinux, tests and reloads.
write_nginx_portal_site

# --- Verify --------------------------------------------------------------------
echo "nginx test:"
nginx -t

if curl -fsS -m 5 http://127.0.0.1:8765/api/gpu >/dev/null 2>&1; then
  echo "gpu-api OK on 8765"
fi

SERVER_NAME=$(grep -oP 'server_name \K.*' /etc/nginx/nginx.conf 2>/dev/null || \
  grep -oP 'server_name \K.*' "$(nginx_site_path)" 2>/dev/null || echo "")
if [[ -n "$SERVER_NAME" ]] && echo "$SERVER_NAME" | grep -q "$SPARK_HOST"; then
  echo "server_name includes $SPARK_HOST: $SERVER_NAME"
fi
echo "OK"

# Shared install helpers — source from install/modules/*/*.sh (do not execute directly).
# SPARK_INSTALL_BATCH=1 defers nginx until spark-install finalizes a bundled run.
#
# Host identity (optional): /etc/spark/host.env or $SPARK_ROOT/host.env (gitignored).
# Copy install/host.env.example. Secrets stay in /etc/spark/smb-credentials-models.
_SPARK_ROOT="${SPARK_ROOT:-/opt/spark}"
for _host_env in /etc/spark/host.env "${_SPARK_ROOT}/host.env"; do
  if [[ -f "$_host_env" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$_host_env"
    set +a
    break
  fi
done
unset _host_env _SPARK_ROOT

SPARK_ROOT="${SPARK_ROOT:-/opt/spark}"
if [[ -z "${SPARK_USER:-}" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    SPARK_USER="${SUDO_USER}"
  else
    SPARK_USER="${SPARK_RUN_USER:-spark}"
  fi
fi
SPARK_STAGING="${SPARK_STAGING:-${SPARK_ROOT}}"
SPARK_HOST="${SPARK_HOST:-sparky}"
# Set SPARK_LAN_IP to your Spark's LAN IP if you want nginx to also serve on
# that address (server_name). Leave blank to serve on hostname + default_server.
SPARK_LAN_IP="${SPARK_LAN_IP:-}"
SPARK_SHELF_MOUNT="${SPARK_SHELF_MOUNT:-/mnt/model-shelf}"

# --- distro detection ----------------------------------------------------------
# debian : Debian/Ubuntu (apt, ufw, nginx sites-enabled layout)
# rhel   : RHEL/Fedora/CentOS/Rocky/Alma (dnf, firewalld, nginx conf.d, SELinux,
#          podman + podman-docker shim, rootless containers)
SPARK_DISTRO="debian"
if [[ -r /etc/os-release ]]; then
  _os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  _os_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
  case "${_os_id} ${_os_like}" in
    *rhel*|*fedora*|*centos*|*rocky*|*alma*) SPARK_DISTRO="rhel" ;;
  esac
  unset _os_id _os_like
fi

# Install packages, distro-aware.
pkg_install() {
  if [[ "$SPARK_DISTRO" == "rhel" ]]; then
    dnf -y install "$@"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "$@"
  fi
}

# Open a TCP port on whichever firewall is active (ufw on Debian/Ubuntu,
# firewalld on RHEL). No-op when no firewall is running.
firewall_open_port() {
  local port="$1" comment="${2:-sparkbench}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" comment "${comment}" >/dev/null
    echo "  firewall (ufw): allowed ${port}/tcp (${comment})"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" --comment="${comment}" >/dev/null
    firewall-cmd --reload >/dev/null
    echo "  firewall (firewalld): opened ${port}/tcp (${comment})"
  fi
}

# SELinux prep for nginx serving /opt/spark/portal (RHEL only, no-op otherwise):
# label the content so httpd_t can read it, and let nginx proxy to the local APIs.
selinux_nginx_prep() {
  [[ "$SPARK_DISTRO" == "rhel" ]] || return 0
  command -v sestatus >/dev/null 2>&1 || return 0
  sestatus 2>/dev/null | awk '/Current mode/ {print $4}' | grep -q enforcing || return 0
  if command -v chcon >/dev/null 2>&1; then
    chcon -R -t httpd_sys_content_t "${SPARK_ROOT}/portal" 2>/dev/null || true
    # new files (e.g. models.json from the inventory refresh) inherit the dir label
  fi
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
  fi
  echo "  SELinux: portal labeled httpd_sys_content_t + httpd_can_network_connect on"
}

# Rootless podman needs a subuid/subgid range for the run user (RHEL only).
ensure_rootless_subuids() {
  [[ "$SPARK_DISTRO" == "rhel" ]] || return 0
  if ! grep -q "^${SPARK_USER}:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 524288-589823 --add-subgids 524288-589823 "${SPARK_USER}"
    echo "  added subuid/subgid range 524288-589823 for ${SPARK_USER} (rootless podman)"
  fi
}

shelf_mounted() {
  mountpoint -q "${SPARK_SHELF_MOUNT}" 2>/dev/null
}

install_batch_active() {
  [[ "${SPARK_INSTALL_BATCH:-}" == "1" ]]
}

# Defer nginx rewrite when spark-install batches modules (finalize once at end).
maybe_write_nginx_portal_site() {
  if install_batch_active; then
    return 0
  fi
  write_nginx_portal_site
}

# Where nginx reads its site config from, per distro:
#  - RHEL/fedora:  /etc/nginx/conf.d/*.conf (included by the stock nginx.conf)
#  - debian:       /etc/nginx/sites-available/ + sites-enabled symlink
nginx_site_path() {
  if [[ "$SPARK_DISTRO" == "rhel" ]]; then
    echo "/etc/nginx/conf.d/spark-portal.conf"
  else
    echo "/etc/nginx/sites-available/spark-portal"
  fi
}

write_nginx_portal_site() {
  local site
  site="$(nginx_site_path)"
  cat > "${site}" <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SPARK_HOST} ${SPARK_LAN_IP} _;

    root ${SPARK_ROOT}/portal;
    index index.html;

    location = /models.json {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        add_header Pragma "no-cache";
        try_files \$uri =404;
    }

    location /api/models/ {
        proxy_pass http://127.0.0.1:8766/api/models/;
        proxy_http_version 1.1;
        add_header Cache-Control "no-store";
    }

    location /api/shelf/ {
        proxy_pass http://127.0.0.1:8766/api/shelf/;
        proxy_http_version 1.1;
        add_header Cache-Control "no-store";
    }

    location /api/gpu {
        proxy_pass http://127.0.0.1:8765/api/gpu;
        proxy_http_version 1.1;
        add_header Cache-Control "no-store";
    }

    location /api/inference/ {
        proxy_pass http://127.0.0.1:8767/api/inference/;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        add_header Cache-Control "no-store";
    }

    location /api/hf/ {
        proxy_pass http://127.0.0.1:8768/api/hf/;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        add_header Cache-Control "no-store";
    }

    location /api/activity {
        proxy_pass http://127.0.0.1:8769;
        proxy_http_version 1.1;
        add_header Cache-Control "no-store";
    }

    location /api/benchmaster/ {
        proxy_pass http://127.0.0.1:8770/api/benchmaster/;
        proxy_http_version 1.1;
        proxy_read_timeout 3600s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
        add_header Cache-Control "no-store";
    }

    location ~* \.css$ {
        add_header Cache-Control "public, max-age=86400";
        try_files \$uri =404;
    }

    location ~* \.js$ {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        add_header Pragma "no-cache";
        try_files \$uri =404;
    }

    # Hermes agent dashboard (same-origin proxy — MagicDNS portal login works)
    location = /hermes {
        return 308 /hermes/;
    }

    location /hermes/ {
        proxy_pass http://127.0.0.1:9119/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Prefix /hermes;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_request_buffering off;
        add_header Cache-Control "no-store";
    }

    # Archived UIs (deprecated; see portal/archive/README.md)
    location ^~ /archive/v3/ {
        add_header X-Spark-Portal-Archive "v3" always;
        try_files \$uri \$uri/ /archive/v3/index.html;
    }

    location ^~ /archive/v1/ {
        add_header X-Spark-Portal-Archive "v1" always;
        try_files \$uri \$uri/ /archive/v1/index.html;
    }

    # Bookmarks from the /v2 beta period
    location = /v2 {
        return 308 /;
    }

    location ^~ /v2/ {
        rewrite ^/v2/?(.*)\$ /\$1 permanent;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
  if [[ "$SPARK_DISTRO" == "rhel" ]]; then
    # stock RHEL nginx ships conf.d/default.conf with its own default_server
    if [[ -f /etc/nginx/conf.d/default.conf ]]; then
      mv -f /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
    fi
  else
    ln -sf "${site}" /etc/nginx/sites-enabled/spark-portal
    rm -f /etc/nginx/sites-enabled/default
  fi
  nginx -t
  selinux_nginx_prep
  systemctl reload nginx
}
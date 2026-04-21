#!/bin/bash
################################################################################
# Script for installing Odoo 17/18/19 on Ubuntu 22.04 / 24.04
# Based on: Yenthe Van Ginneken's install script
# Modified by: vitraining
#-------------------------------------------------------------------------------
# Features:
#   - Support Odoo 17.0, 18.0, 19.0
#   - Python virtual environment (venv)
#   - Auto install PostgreSQL 16 + PgBouncer
#   - Nginx reverse proxy with virtual host
#   - Cloudflare SSL (Origin Certificate .pem + .key)
#   - Systemd service (modern, replaces init.d)
#-------------------------------------------------------------------------------
# Usage:
#   1. Edit the variables below to match your environment
#   2. sudo chmod +x odoo_install.sh
#   3. sudo ./odoo_install.sh
################################################################################

################################################################################
#                         USER CONFIGURATION VARIABLES
################################################################################

# ---- Odoo Version (17.0, 18.0, or 19.0) ----
OE_VERSION="19.0"

# ---- System User ----
OE_USER="odoo"
OE_HOME="/${OE_USER}"
OE_HOME_EXT="/${OE_USER}/${OE_USER}-server"

# ---- Odoo Ports ----
OE_PORT="8069"
LONGPOLLING_PORT="8072"
WEBSOCKET_PORT="8072"

# ---- Enterprise ----
IS_ENTERPRISE="False"

# ---- Wkhtmltopdf ----
INSTALL_WKHTMLTOPDF="True"

# ---- Super Admin Password ----
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="True"

# ---- Config file name ----
OE_CONFIG="${OE_USER}-server"

# ---- Domain & Nginx ----
WEBSITE_NAME="odoo.example.com"

# ---- Cloudflare SSL (Wildcard / General Certificate) ----
# Uses a shared certificate for all subdomains of the root domain.
# Example: if WEBSITE_NAME="test.xerpium.com", the script will look for:
#   /etc/ssl/cloudflare/xerpium.com/cloudflare_origin.pem
#   /etc/ssl/cloudflare/xerpium.com/cloudflare_origin.key
# You can override ROOT_DOMAIN below if auto-detection doesn't work.
ROOT_DOMAIN=""  # Leave empty to auto-detect from WEBSITE_NAME
SSL_CERT_FILENAME="cloudflare_origin.pem"
SSL_KEY_FILENAME="cloudflare_origin.key"

# ---- PgBouncer ----
PGBOUNCER_PORT="6432"
PGBOUNCER_POOL_MODE="transaction"
PGBOUNCER_MAX_CLIENT_CONN="200"
PGBOUNCER_DEFAULT_POOL_SIZE="20"

# ---- Workers (for production) ----
# Set 0 for development, (2 * CPU_CORES) + 1 for production
OE_WORKERS="0"
OE_MAX_CRON_THREADS="2"

################################################################################
#                         DO NOT EDIT BELOW THIS LINE
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

print_step() {
    echo -e "${GREEN}---- $1 ----${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# ---- Validate Odoo version ----
case "$OE_VERSION" in
    15.0|16.0|17.0|18.0|19.0)
        echo -e "${GREEN}Installing Odoo version: ${OE_VERSION}${NC}"
        ;;
    *)
        print_error "Unsupported Odoo version: $OE_VERSION. Supported versions: 15.0, 16.0, 17.0, 18.0, 19.0"
        exit 1
        ;;
esac

# ---- Auto-detect Root Domain from WEBSITE_NAME ----
# Extracts the root domain (last 2 parts) from WEBSITE_NAME.
# e.g.: test.xerpium.com → xerpium.com
#        erp.client.xerpium.com → xerpium.com
if [ -z "$ROOT_DOMAIN" ]; then
    # Extract last two parts of the domain
    ROOT_DOMAIN=$(echo "$WEBSITE_NAME" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
fi

# Build SSL certificate paths from root domain
SSL_CERTIFICATE_FILE="/etc/ssl/cloudflare/${ROOT_DOMAIN}/${SSL_CERT_FILENAME}"
SSL_CERTIFICATE_KEY="/etc/ssl/cloudflare/${ROOT_DOMAIN}/${SSL_KEY_FILENAME}"

# Extract subdomain from WEBSITE_NAME (for database name)
# e.g.: install.xerpium.com → install
#        erp.client.xerpium.com → erp.client
OE_DB_NAME=$(echo "$WEBSITE_NAME" | sed "s/.${ROOT_DOMAIN}//")

echo -e "${GREEN}Domain           : ${WEBSITE_NAME}${NC}"
echo -e "${GREEN}Root Domain      : ${ROOT_DOMAIN}${NC}"
echo -e "${GREEN}Database Name    : ${OE_DB_NAME}${NC}"
echo -e "${GREEN}SSL Certificate  : ${SSL_CERTIFICATE_FILE}${NC}"
echo -e "${GREEN}SSL Private Key  : ${SSL_CERTIFICATE_KEY}${NC}"

# ---- Architecture detection ----
detect_arch() {
    local arch_raw
    arch_raw="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch_raw" in
        amd64|x86_64)   ARCH_DEB="amd64";;
        i386|i686)      ARCH_DEB="i386";;
        arm64|aarch64)  ARCH_DEB="arm64";;
        armhf|armv7l)   ARCH_DEB="armhf";;
        *)              ARCH_DEB="$arch_raw";;
    esac
    UBUNTU_CODENAME="$(lsb_release -c -s 2>/dev/null || echo noble)"
    UBUNTU_RELEASE="$(lsb_release -r -s 2>/dev/null || echo 24.04)"
}

detect_arch

# ---- Wkhtmltopdf install helper ----
install_wkhtmltopdf_from_ubuntu() {
    sudo apt-get update -y
    if sudo apt-get install -y wkhtmltopdf; then
        echo "wkhtmltopdf installed from Ubuntu repositories ($ARCH_DEB)."
        return 0
    fi
    return 1
}

wkhtml_create_symlinks_if_needed() {
    if [ -x /usr/local/bin/wkhtmltopdf ] && ! command -v wkhtmltopdf >/dev/null 2>&1; then
        sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin || true
    fi
    if [ -x /usr/local/bin/wkhtmltoimage ] && ! command -v wkhtmltoimage >/dev/null 2>&1; then
        sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin || true
    fi
}

##############################################################################
# 1. UPDATE SERVER
##############################################################################
print_header "1. Update Server"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y software-properties-common curl wget gnupg2 lsb-release

##############################################################################
# 2. INSTALL POSTGRESQL 16
##############################################################################
print_header "2. Install PostgreSQL 16"

print_step "Adding PostgreSQL official repository"
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update -y

print_step "Installing PostgreSQL 16"
sudo apt-get install -y postgresql-16

# Start PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Wait for PostgreSQL to be ready
until sudo -u postgres pg_isready >/dev/null 2>&1; do sleep 1; done

if [ "$IS_ENTERPRISE" = "True" ]; then
    print_step "Installing pgvector for Enterprise AI features"
    sudo apt-get install -y postgresql-16-pgvector
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
fi

# Create Odoo PostgreSQL user with password (needed for PgBouncer md5 auth)
print_step "Creating PostgreSQL user: ${OE_USER}"
OE_DB_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
sudo -u postgres psql -c "CREATE USER ${OE_USER} WITH CREATEDB SUPERUSER PASSWORD '${OE_DB_PASSWORD}';" 2>/dev/null || \
sudo -u postgres psql -c "ALTER USER ${OE_USER} WITH PASSWORD '${OE_DB_PASSWORD}';"

# Configure PostgreSQL for md5 authentication (needed for PgBouncer)
PG_HBA_FILE=$(sudo -u postgres psql -t -P format=unaligned -c 'SHOW hba_file;' | head -1 | xargs)
if ! sudo grep -q "host.*all.*${OE_USER}.*md5" "$PG_HBA_FILE" 2>/dev/null; then
    print_step "Configuring PostgreSQL pg_hba.conf for md5 auth"
    # Add md5 auth line before the first existing host line
    sudo sed -i "/^# IPv4 local connections:/a host    all             ${OE_USER}          127.0.0.1/32            md5" "$PG_HBA_FILE"
    sudo systemctl restart postgresql
fi

echo -e "${GREEN}PostgreSQL 16 installed and configured.${NC}"

##############################################################################
# 3. INSTALL PGBOUNCER
##############################################################################
print_header "3. Install PgBouncer"

sudo apt-get install -y pgbouncer

# Stop PgBouncer before reconfiguring
sudo systemctl stop pgbouncer 2>/dev/null || true

# Detect which user the systemd service runs PgBouncer as (postgres on Ubuntu 24.04, pgbouncer on older)
PGBOUNCER_SVC_USER=$(grep -oP '^User=\K.*' /lib/systemd/system/pgbouncer.service 2>/dev/null || echo "postgres")
print_step "PgBouncer systemd runs as user: ${PGBOUNCER_SVC_USER}"

# Ensure log and run directories exist with correct ownership BEFORE config
sudo mkdir -p /var/log/pgbouncer
sudo chown ${PGBOUNCER_SVC_USER}:${PGBOUNCER_SVC_USER} /var/log/pgbouncer
sudo chmod 755 /var/log/pgbouncer

sudo mkdir -p /var/run/pgbouncer
sudo chown ${PGBOUNCER_SVC_USER}:${PGBOUNCER_SVC_USER} /var/run/pgbouncer

print_step "Configuring PgBouncer (scram-sha-256 + auth_query)"

# Get the SCRAM-SHA-256 password hash from PostgreSQL for userlist
SCRAM_HASH=$(sudo -u postgres psql -t -A -c "SELECT rolpassword FROM pg_authid WHERE rolname='${OE_USER}';")

# Create PgBouncer userlist.txt with SCRAM hash
sudo bash -c "cat > /etc/pgbouncer/userlist.txt" <<EOF
"${OE_USER}" "${SCRAM_HASH}"
EOF

# Create PgBouncer configuration
sudo bash -c "cat > /etc/pgbouncer/pgbouncer.ini" <<EOF
;;; PgBouncer configuration for Odoo ${OE_VERSION}

[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = ${PGBOUNCER_PORT}
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=\$1
auth_user = ${OE_USER}

;; Pool settings
pool_mode = ${PGBOUNCER_POOL_MODE}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3

;; Timeouts
server_reset_query = DISCARD ALL
server_check_delay = 30
server_check_query = SELECT 1
server_lifetime = 3600
server_idle_timeout = 600
client_idle_timeout = 0
client_login_timeout = 60
query_timeout = 0
query_wait_timeout = 120

;; Logging
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
admin_users = ${OE_USER}
stats_users = ${OE_USER}

;; Low-level tuning
pkt_buf = 4096
max_packet_size = 2147483647
listen_backlog = 128
tcp_defer_accept = 45
tcp_keepalive = 1
tcp_keepcnt = 0
tcp_keepidle = 0
tcp_keepintvl = 0
EOF

# Set config file permissions matching systemd service user
sudo chown ${PGBOUNCER_SVC_USER}:${PGBOUNCER_SVC_USER} /etc/pgbouncer/pgbouncer.ini
sudo chmod 640 /etc/pgbouncer/pgbouncer.ini
sudo chown ${PGBOUNCER_SVC_USER}:${PGBOUNCER_SVC_USER} /etc/pgbouncer/userlist.txt
sudo chmod 640 /etc/pgbouncer/userlist.txt

# Start and enable PgBouncer
sudo systemctl restart pgbouncer
sudo systemctl enable pgbouncer

echo -e "${GREEN}PgBouncer installed and configured on port ${PGBOUNCER_PORT}.${NC}"

##############################################################################
# 4. INSTALL SYSTEM DEPENDENCIES
##############################################################################
print_header "4. Install System Dependencies"

print_step "Installing core build dependencies"
sudo apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    python3-wheel \
    python3-setuptools \
    python3-cffi \
    build-essential \
    libpq-dev \
    libxslt1-dev \
    libzip-dev \
    libldap2-dev \
    libsasl2-dev \
    libpng-dev \
    libjpeg-dev \
    libffi-dev \
    libssl-dev \
    libxml2-dev \
    zlib1g-dev \
    node-less \
    gdebi \
    xfonts-75dpi \
    xfonts-base

print_step "Installing nodeJS, NPM, and rtlcss"
sudo apt-get install -y nodejs npm
sudo npm install -g rtlcss

##############################################################################
# 5. INSTALL WKHTMLTOPDF
##############################################################################
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
    print_header "5. Install wkhtmltopdf"
    print_step "Architecture detected: $ARCH_DEB"

    if install_wkhtmltopdf_from_ubuntu; then
        :
    else
        print_warning "Could not install wkhtmltopdf from Ubuntu repositories."
    fi

    wkhtml_create_symlinks_if_needed

    if command -v wkhtmltopdf >/dev/null 2>&1; then
        echo -e "${GREEN}wkhtmltopdf available at: $(command -v wkhtmltopdf)${NC}"
    else
        print_warning "wkhtmltopdf was not installed. You can install it manually later."
    fi
else
    print_step "Skipping wkhtmltopdf installation (user choice)"
fi

##############################################################################
# 6. CREATE ODOO SYSTEM USER
##############################################################################
print_header "6. Create Odoo System User"

sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER 2>/dev/null || true
sudo adduser $OE_USER sudo 2>/dev/null || true

print_step "Creating log directory"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

##############################################################################
# 7. INSTALL ODOO SOURCE CODE
##############################################################################
print_header "7. Install Odoo ${OE_VERSION} Source Code"

print_step "Cloning Odoo ${OE_VERSION} from GitHub"
sudo git clone --depth 1 --branch ${OE_VERSION} https://www.github.com/odoo/odoo $OE_HOME_EXT/

if [ "$IS_ENTERPRISE" = "True" ]; then
    print_step "Installing Odoo Enterprise"
    sudo su $OE_USER -c "mkdir -p $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch ${OE_VERSION} https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "TIP: Press ctrl+c to stop this script."
        echo "-------------------------------------------------------------"
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch ${OE_VERSION} https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done
    echo -e "${GREEN}Enterprise code cloned to $OE_HOME/enterprise/addons${NC}"
fi

print_step "Creating custom addons directory"
sudo su $OE_USER -c "mkdir -p $OE_HOME/custom/addons"

##############################################################################
# 8. SETUP PYTHON VIRTUAL ENVIRONMENT
##############################################################################
print_header "8. Setup Python Virtual Environment"

VENV_DIR="$OE_HOME/venv"
VENV_PIP="$VENV_DIR/bin/pip"
VENV_PYTHON="$VENV_DIR/bin/python"

print_step "Creating virtual environment at ${VENV_DIR}"
sudo python3 -m venv ${VENV_DIR} --system-site-packages
sudo chown -R $OE_USER:$OE_USER ${VENV_DIR}

print_step "Upgrading pip, setuptools, wheel in venv"
sudo su - $OE_USER -c "${VENV_PIP} install --upgrade pip setuptools wheel"

print_step "Installing Odoo ${OE_VERSION} Python requirements"
sudo su - $OE_USER -c "${VENV_PIP} install -r https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt"

# Version-specific dependencies
print_step "Installing version-specific dependencies for Odoo ${OE_VERSION}"
case "$OE_VERSION" in
    15.0|16.0|17.0|18.0|19.0)
        sudo su - $OE_USER -c "${VENV_PIP} install phonenumbers pyopenssl psycopg2-binary"
        ;;
esac

if [ "$IS_ENTERPRISE" = "True" ]; then
    print_step "Installing Enterprise-specific libraries"
    sudo su - $OE_USER -c "${VENV_PIP} install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL pdfminer.six"
    sudo npm install -g less less-plugin-clean-css
fi

echo -e "${GREEN}Python virtual environment created at ${VENV_DIR}${NC}"

##############################################################################
# 9. SET PERMISSIONS
##############################################################################
print_header "9. Set File Permissions"

sudo chown -R $OE_USER:$OE_USER $OE_HOME/*

##############################################################################
# 10. CREATE ODOO CONFIGURATION FILE
##############################################################################
print_header "10. Create Odoo Configuration"

if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi

# Determine addons_path based on Enterprise vs Community
if [ "$IS_ENTERPRISE" = "True" ]; then
    ADDONS_PATH="${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
else
    ADDONS_PATH="${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
fi

# Determine gevent/websocket port parameter based on version
# Odoo 17+ uses --gevent-port for websocket
GEVENT_PORT_LINE="gevent_port = ${WEBSOCKET_PORT}"

sudo bash -c "cat > /etc/${OE_CONFIG}.conf" <<EOF
[options]
;; ---- Odoo ${OE_VERSION} Server Configuration ----

;; Admin
admin_passwd = ${OE_SUPERADMIN}

;; Network
http_port = ${OE_PORT}
${GEVENT_PORT_LINE}
proxy_mode = True

;; Database (via PgBouncer)
db_host = 127.0.0.1
db_port = ${PGBOUNCER_PORT}
db_user = ${OE_USER}
db_password = ${OE_DB_PASSWORD}
; db_name = False
; db_filter = ^%h$
; list_db = False

;; Paths
addons_path = ${ADDONS_PATH}
data_dir = ${OE_HOME}/.local/share/Odoo

;; Logging
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
log_level = info
log_handler = :INFO
logrotate = True

;; Workers (set workers > 0 for production)
workers = ${OE_WORKERS}
max_cron_threads = ${OE_MAX_CRON_THREADS}

;; Memory Limits (adjust based on server RAM)
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = -1
limit_request = 8192

;; Security
; server_wide_modules = base,web
EOF

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

# Create data directory
sudo mkdir -p ${OE_HOME}/.local/share/Odoo
sudo chown -R $OE_USER:$OE_USER ${OE_HOME}/.local

echo -e "${GREEN}Odoo configuration created at /etc/${OE_CONFIG}.conf${NC}"

##############################################################################
# 11. CREATE STARTUP SCRIPT
##############################################################################
print_header "11. Create Startup Script"

sudo bash -c "cat > $OE_HOME_EXT/start.sh" <<EOF
#!/bin/bash
# Start Odoo ${OE_VERSION} using Python from virtual environment
sudo -u ${OE_USER} ${VENV_PYTHON} ${OE_HOME_EXT}/odoo-bin --config=/etc/${OE_CONFIG}.conf
EOF
sudo chmod 755 $OE_HOME_EXT/start.sh

##############################################################################
# 12. CREATE SYSTEMD SERVICE
##############################################################################
print_header "12. Create Systemd Service"

sudo bash -c "cat > /etc/systemd/system/${OE_CONFIG}.service" <<EOF
[Unit]
Description=Odoo ${OE_VERSION} - ${OE_USER}
Documentation=https://www.odoo.com/documentation/${OE_VERSION}/
Requires=postgresql.service pgbouncer.service
After=network.target postgresql.service pgbouncer.service

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}

# Virtual environment Python
ExecStart=${VENV_PYTHON} ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
ExecStop=/bin/kill -SIGTERM \$MAINPID

# Restart on failure
Restart=on-failure
RestartSec=5

# Working directory
WorkingDirectory=${OE_HOME_EXT}

# Security hardening
StandardOutput=journal+console
StandardError=journal+console
NoNewPrivileges=true
PrivateTmp=true

# Resource limits
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${OE_CONFIG}.service

echo -e "${GREEN}Systemd service created: ${OE_CONFIG}.service${NC}"

##############################################################################
# 13. INSTALL & CONFIGURE NGINX
##############################################################################
print_header "13. Install & Configure Nginx"

sudo apt-get install -y nginx

print_step "Creating Nginx virtual host for ${WEBSITE_NAME}"

# Build upstream name from OE_USER
UPSTREAM_NAME="${OE_USER}-backend"
UPSTREAM_WS="${OE_USER}-websocket"

sudo bash -c "cat > /etc/nginx/sites-available/${WEBSITE_NAME}" <<'NGINX_CONF'
##############################################################################
# Nginx configuration for Odoo - Generated by odoo_install.sh
##############################################################################

# Odoo backend upstream
upstream UPSTREAM_NAME_PLACEHOLDER {
    server 127.0.0.1:OE_PORT_PLACEHOLDER;
}

# Odoo websocket/longpolling upstream
upstream UPSTREAM_WS_PLACEHOLDER {
    server 127.0.0.1:WEBSOCKET_PORT_PLACEHOLDER;
}

# Map to detect websocket upgrade
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Redirect HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name WEBSITE_NAME_PLACEHOLDER;

    # Redirect all HTTP traffic to HTTPS
    return 301 https://$host$request_uri;
}

# HTTPS Server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name WEBSITE_NAME_PLACEHOLDER;

    # ---- Cloudflare Origin SSL Certificate ----
    ssl_certificate     SSL_CERTIFICATE_FILE_PLACEHOLDER;
    ssl_certificate_key SSL_CERTIFICATE_KEY_PLACEHOLDER;

    # SSL Settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # ---- Proxy Headers ----
    proxy_set_header X-Forwarded-Host   $host;
    proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto  $scheme;
    proxy_set_header X-Real-IP          $remote_addr;
    proxy_set_header X-Client-IP        $remote_addr;
    proxy_set_header HTTP_X_FORWARDED_HOST $remote_addr;

    # ---- Security Headers ----
    add_header X-Frame-Options          "SAMEORIGIN"       always;
    add_header X-XSS-Protection         "1; mode=block"    always;
    add_header X-Content-Type-Options   "nosniff"          always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=63072000" always;

    # ---- Logging ----
    access_log /var/log/nginx/OE_USER_PLACEHOLDER-access.log;
    error_log  /var/log/nginx/OE_USER_PLACEHOLDER-error.log;

    # ---- Proxy Buffer ----
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;

    # ---- Timeouts ----
    proxy_read_timeout    900s;
    proxy_connect_timeout 900s;
    proxy_send_timeout    900s;

    # ---- Upstream failover ----
    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;

    # ---- MIME types ----
    types {
        text/less less;
        text/scss scss;
    }

    # ---- Gzip Compression ----
    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types
        text/css
        text/less
        text/plain
        text/xml
        application/xml
        application/json
        application/javascript
        application/pdf
        image/jpeg
        image/png
        image/svg+xml
        font/woff
        font/woff2;
    gzip_vary on;

    # ---- Client Settings ----
    client_header_buffer_size 4k;
    large_client_header_buffers 4 64k;
    client_max_body_size 0;

    # ---- Odoo Web Client ----
    location / {
        proxy_pass http://UPSTREAM_NAME_PLACEHOLDER;
        proxy_redirect off;
    }

    # ---- Websocket (Odoo 17+) ----
    location /websocket {
        proxy_pass http://UPSTREAM_WS_PLACEHOLDER;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400;
    }

    # ---- Legacy Longpolling (Odoo 16 and earlier) ----
    location /longpolling {
        proxy_pass http://UPSTREAM_WS_PLACEHOLDER;
    }

    # ---- Static Files with cache ----
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 7d;
        proxy_pass http://UPSTREAM_NAME_PLACEHOLDER;
        add_header Cache-Control "public, no-transform";
    }

    # ---- Cache static data in memory ----
    location ~ /[a-zA-Z0-9_-]*/static/ {
        proxy_cache_valid 200 302 60m;
        proxy_cache_valid 404 1m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://UPSTREAM_NAME_PLACEHOLDER;
    }
}
NGINX_CONF

# Replace placeholders with actual values
sudo sed -i "s|UPSTREAM_NAME_PLACEHOLDER|${UPSTREAM_NAME}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|UPSTREAM_WS_PLACEHOLDER|${UPSTREAM_WS}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|OE_PORT_PLACEHOLDER|${OE_PORT}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|WEBSOCKET_PORT_PLACEHOLDER|${WEBSOCKET_PORT}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|WEBSITE_NAME_PLACEHOLDER|${WEBSITE_NAME}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|SSL_CERTIFICATE_FILE_PLACEHOLDER|${SSL_CERTIFICATE_FILE}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|SSL_CERTIFICATE_KEY_PLACEHOLDER|${SSL_CERTIFICATE_KEY}|g" /etc/nginx/sites-available/${WEBSITE_NAME}
sudo sed -i "s|OE_USER_PLACEHOLDER|${OE_USER}|g" /etc/nginx/sites-available/${WEBSITE_NAME}

# Enable site
sudo ln -sf /etc/nginx/sites-available/${WEBSITE_NAME} /etc/nginx/sites-enabled/${WEBSITE_NAME}

# Remove default site
sudo rm -f /etc/nginx/sites-enabled/default

# Create SSL directory for Cloudflare certificates (per root domain)
sudo mkdir -p /etc/ssl/cloudflare/${ROOT_DOMAIN}

echo -e "${GREEN}Nginx virtual host created for ${WEBSITE_NAME}${NC}"

##############################################################################
# 14. CLOUDFLARE SSL CERTIFICATE SETUP
##############################################################################
print_header "14. Cloudflare SSL Certificate Setup"

if [ -f "$SSL_CERTIFICATE_FILE" ] && [ -f "$SSL_CERTIFICATE_KEY" ]; then
    echo -e "${GREEN}SSL certificate files found:${NC}"
    echo "  Certificate: ${SSL_CERTIFICATE_FILE}"
    echo "  Private Key: ${SSL_CERTIFICATE_KEY}"

    # Set proper permissions
    sudo chmod 644 ${SSL_CERTIFICATE_FILE}
    sudo chmod 600 ${SSL_CERTIFICATE_KEY}
    sudo chown root:root ${SSL_CERTIFICATE_FILE}
    sudo chown root:root ${SSL_CERTIFICATE_KEY}

    # Test Nginx config
    if sudo nginx -t 2>&1; then
        echo -e "${GREEN}Nginx configuration is valid.${NC}"
        sudo systemctl restart nginx
    else
        print_error "Nginx configuration test failed! Please check your SSL files."
    fi
else
    print_warning "SSL certificate files not found at the configured paths:"
    echo "  Certificate: ${SSL_CERTIFICATE_FILE}"
    echo "  Private Key: ${SSL_CERTIFICATE_KEY}"
    echo ""
    echo "Please place your Cloudflare Origin Certificate files at the paths above."
    echo "You can generate them from Cloudflare Dashboard → SSL/TLS → Origin Server."
    echo ""
    echo "After placing the files, run:"
    echo "  sudo chmod 644 ${SSL_CERTIFICATE_FILE}"
    echo "  sudo chmod 600 ${SSL_CERTIFICATE_KEY}"
    echo "  sudo nginx -t && sudo systemctl restart nginx"
    echo ""

    # Start Nginx anyway (it will fail on SSL but at least the config is ready)
    print_warning "Nginx will NOT start until SSL certificates are in place."
fi

sudo systemctl enable nginx

##############################################################################
# 15. START SERVICES
##############################################################################
print_header "15. Starting Services"

print_step "Starting PostgreSQL"
sudo systemctl start postgresql

print_step "Starting PgBouncer"
sudo systemctl restart pgbouncer

print_step "Starting Nginx"
if [ -f "$SSL_CERTIFICATE_FILE" ] && [ -f "$SSL_CERTIFICATE_KEY" ]; then
    sudo systemctl restart nginx
else
    print_warning "Nginx not started — waiting for SSL certificates."
fi

##############################################################################
# 16. CREATE ODOO DATABASE
##############################################################################
print_header "16. Create Odoo Database: ${OE_DB_NAME}"

print_step "Initializing database '${OE_DB_NAME}' (this may take 1-3 minutes)..."

# Create and initialize the database using odoo-bin
# --stop-after-init: exits after initializing so we can start the service normally after
sudo su - ${OE_USER} -c "${VENV_PYTHON} ${OE_HOME_EXT}/odoo-bin \
    -c /etc/${OE_CONFIG}.conf \
    -d ${OE_DB_NAME} \
    -i base \
    --without-demo=all \
    --stop-after-init" 2>&1 | tail -5

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Database '${OE_DB_NAME}' created successfully.${NC}"
else
    print_warning "Database creation may have encountered issues. Check logs."
fi

# Update Odoo config to filter to this database
sudo sed -i "s|; db_name = False|db_name = ${OE_DB_NAME}|" /etc/${OE_CONFIG}.conf
sudo sed -i "s|; db_filter = .*|db_filter = ^${OE_DB_NAME}$|" /etc/${OE_CONFIG}.conf

print_step "Starting Odoo service"
sudo systemctl start ${OE_CONFIG}.service

##############################################################################
# 17. SUMMARY
##############################################################################
print_header "Installation Complete!"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ODOO ${OE_VERSION} INSTALLATION SUMMARY                  ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Odoo Version      : ${OE_VERSION}                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Domain            : ${WEBSITE_NAME}                        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Database          : ${OE_DB_NAME}                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Odoo Port         : ${OE_PORT}                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Websocket Port    : ${WEBSOCKET_PORT}                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  System User       : ${OE_USER}                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}--- PostgreSQL ---${NC}                                         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  DB User           : ${OE_USER}                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  DB Password       : ${OE_DB_PASSWORD}                        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Direct Port       : 5432                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}--- PgBouncer ---${NC}                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Port              : ${PGBOUNCER_PORT}                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Pool Mode         : ${PGBOUNCER_POOL_MODE}                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Config            : /etc/pgbouncer/pgbouncer.ini            ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}--- Python ---${NC}                                             ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Venv              : ${VENV_DIR}                         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Python            : ${VENV_PYTHON}                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}--- Nginx ---${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Config            : /etc/nginx/sites-available/${WEBSITE_NAME}  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  SSL Cert          : ${SSL_CERTIFICATE_FILE}       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  SSL Key           : ${SSL_CERTIFICATE_KEY}        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}--- Odoo ---${NC}                                               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Config File       : /etc/${OE_CONFIG}.conf                 ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Log File          : /var/log/${OE_USER}/${OE_CONFIG}.log    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Addons Path       : ${OE_HOME}/custom/addons               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Super Admin Pass  : ${OE_SUPERADMIN}                        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Code Location     : ${OE_HOME_EXT}                         ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}Service Management Commands:${NC}                                ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Start Odoo     : sudo systemctl start ${OE_CONFIG}          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Stop Odoo      : sudo systemctl stop ${OE_CONFIG}           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Restart Odoo   : sudo systemctl restart ${OE_CONFIG}        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Status Odoo    : sudo systemctl status ${OE_CONFIG}         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Start PgBouncer: sudo systemctl start pgbouncer             ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Restart Nginx  : sudo systemctl restart nginx               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}View Logs:${NC}                                                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Odoo   : tail -f /var/log/${OE_USER}/${OE_CONFIG}.log       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Nginx  : tail -f /var/log/nginx/${OE_USER}-error.log        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  PgBouncer: tail -f /var/log/pgbouncer/pgbouncer.log         ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ ! -f "$SSL_CERTIFICATE_FILE" ] || [ ! -f "$SSL_CERTIFICATE_KEY" ]; then
    echo ""
    print_warning "IMPORTANT: SSL certificates not found. Nginx is NOT running."
    echo "Place your Cloudflare Origin Certificate files and restart Nginx:"
    echo ""
    echo "  1. Copy certificate:  sudo cp /path/to/your/cert.pem ${SSL_CERTIFICATE_FILE}"
    echo "  2. Copy private key:  sudo cp /path/to/your/key.key ${SSL_CERTIFICATE_KEY}"
    echo "  3. Set permissions:   sudo chmod 644 ${SSL_CERTIFICATE_FILE}"
    echo "                        sudo chmod 600 ${SSL_CERTIFICATE_KEY}"
    echo "  4. Test & restart:    sudo nginx -t && sudo systemctl restart nginx"
    echo ""
fi
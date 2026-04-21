#!/bin/bash
################################################################################
# Odoo Remote Deployment Tool
# by: vitraining
#-------------------------------------------------------------------------------
# Run this script from your LOCAL machine (Mac/Linux).
# It will:
#   1. Prompt for server & Odoo configuration
#   2. Upload the install script + SSL certificates to the server
#   3. SSH into the server and execute the installation
#   4. Verify services are running
#-------------------------------------------------------------------------------
# Requirements:
#   - SSH key-based access to the target server
#   - odoo_install.sh in the same directory as this script
#   - ssl/cloudflare_origin.pem and ssl/cloudflare_origin.key in ssl/ folder
################################################################################

set -e

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Script directory (where deploy.sh and odoo_install.sh live) ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/odoo_install.sh"

# ---- Helper functions ----
print_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║           ODOO DEPLOYMENT TOOL - VITRAINING                ║"
    echo "║                                                            ║"
    echo "║   Deploy Odoo 15-19 to remote Ubuntu server via SSH        ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
    echo ""
}

print_step() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_progress() {
    echo -e "  ${YELLOW}⟳${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗ $1${NC}"
}

print_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

prompt_input() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local value

    if [ -n "$default_value" ]; then
        echo -ne "  ${BOLD}${prompt_text}${NC} [${CYAN}${default_value}${NC}]: "
    else
        echo -ne "  ${BOLD}${prompt_text}${NC}: "
    fi
    read value
    value="${value:-$default_value}"
    eval "$var_name=\"$value\""
}

prompt_file() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local value

    while true; do
        if [ -n "$default_value" ]; then
            echo -ne "  ${BOLD}${prompt_text}${NC} [${CYAN}${default_value}${NC}]: "
        else
            echo -ne "  ${BOLD}${prompt_text}${NC}: "
        fi
        read value
        value="${value:-$default_value}"

        # Expand ~ to $HOME
        value="${value/#\~/$HOME}"

        if [ -f "$value" ]; then
            eval "$var_name=\"$value\""
            break
        else
            print_error "File not found: $value"
            echo ""
        fi
    done
}

prompt_choice() {
    local var_name="$1"
    local prompt_text="$2"
    local choices="$3"
    local default_value="$4"
    local value

    while true; do
        echo -ne "  ${BOLD}${prompt_text}${NC} (${choices}) [${CYAN}${default_value}${NC}]: "
        read value
        value="${value:-$default_value}"

        if echo "$choices" | grep -qw "$value"; then
            eval "$var_name=\"$value\""
            break
        else
            print_error "Invalid choice: $value. Options: $choices"
        fi
    done
}

prompt_yes_no() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local value

    while true; do
        echo -ne "  ${BOLD}${prompt_text}${NC} [${CYAN}${default_value}${NC}]: "
        read value
        value="${value:-$default_value}"
        value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

        case "$value" in
            y|yes) eval "$var_name=\"True\""; break;;
            n|no)  eval "$var_name=\"False\""; break;;
            *)     print_error "Please answer y or n";;
        esac
    done
}

# ---- Validate prerequisites ----
check_prerequisites() {
    print_section "Checking Prerequisites"

    # Check odoo_install.sh exists
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        print_error "odoo_install.sh not found at: $INSTALL_SCRIPT"
        echo "       Place odoo_install.sh in the same directory as deploy.sh"
        exit 1
    fi
    print_step "odoo_install.sh found"

    # Check ssh available
    if ! command -v ssh &>/dev/null; then
        print_error "ssh command not found"
        exit 1
    fi
    print_step "ssh available"

    # Check scp available
    if ! command -v scp &>/dev/null; then
        print_error "scp command not found"
        exit 1
    fi
    print_step "scp available"

    # Check jq available (needed for Cloudflare API)
    if ! command -v jq &>/dev/null; then
        print_info "jq not found. Installing jq..."
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS: try brew, then curl binary
            if command -v brew &>/dev/null; then
                brew install jq
            else
                echo -e "  ${YELLOW}⚠  brew not found. Downloading jq binary...${NC}"
                JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"
                if [[ "$(uname -m)" == "arm64" ]]; then
                    JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64"
                fi
                curl -sL "$JQ_URL" -o /usr/local/bin/jq 2>/dev/null || curl -sL "$JQ_URL" -o "${SCRIPT_DIR}/jq"
                chmod +x /usr/local/bin/jq 2>/dev/null || chmod +x "${SCRIPT_DIR}/jq"
                export PATH="${SCRIPT_DIR}:$PATH"
            fi
        else
            sudo apt-get install -y jq 2>/dev/null || sudo yum install -y jq 2>/dev/null || true
        fi
        if command -v jq &>/dev/null; then
            print_step "jq installed successfully"
        else
            print_error "Could not install jq. Cloudflare DNS update will be skipped."
        fi
    else
        print_step "jq available"
    fi
}

# ---- Test SSH connection ----
test_ssh_connection() {
    local ssh_opts="$1"
    local ssh_target="$2"

    print_progress "Testing SSH connection to ${ssh_target}..."

    if ssh $ssh_opts -o ConnectTimeout=10 -o BatchMode=yes "$ssh_target" "echo 'SSH OK'" &>/dev/null; then
        print_step "SSH connection successful"
        return 0
    else
        print_error "SSH connection failed to ${ssh_target}"
        echo ""
        echo -e "  ${YELLOW}Troubleshooting tips:${NC}"
        echo "    1. Check if the SSH key is correct and has proper permissions (chmod 600)"
        echo "    2. Check if the SSH key is added to the server's authorized_keys"
        echo "    3. Check if the server IP and port are correct"
        echo "    4. Try manually: ssh ${ssh_opts} ${ssh_target}"
        echo ""
        return 1
    fi
}

################################################################################
#                              MAIN FLOW
################################################################################

print_banner
check_prerequisites

# ====================================================================
# STEP 1: Server Connection Details
# ====================================================================
print_section "1. Server Connection"

prompt_input  SERVER_IP       "Server IP / Hostname"  ""
prompt_input  SSH_USER        "SSH User"              "root"
prompt_input  SSH_PORT        "SSH Port"              "22"
prompt_file   SSH_KEY         "SSH Private Key Path"  "$HOME/.ssh/id_rsa"

# Build SSH options
SSH_OPTS="-i ${SSH_KEY} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new"
SSH_TARGET="${SSH_USER}@${SERVER_IP}"
SCP_OPTS="-i ${SSH_KEY} -P ${SSH_PORT} -o StrictHostKeyChecking=accept-new"

# Test connection
echo ""
if ! test_ssh_connection "$SSH_OPTS" "$SSH_TARGET"; then
    echo -ne "  ${BOLD}Retry? (y/n)${NC}: "
    read retry
    if [ "$retry" != "y" ]; then
        echo "Aborted."
        exit 1
    fi
    # Re-prompt connection details
    prompt_input  SERVER_IP       "Server IP / Hostname"  "$SERVER_IP"
    prompt_input  SSH_USER        "SSH User"              "$SSH_USER"
    prompt_input  SSH_PORT        "SSH Port"              "$SSH_PORT"
    prompt_file   SSH_KEY         "SSH Private Key Path"  "$SSH_KEY"

    SSH_OPTS="-i ${SSH_KEY} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new"
    SSH_TARGET="${SSH_USER}@${SERVER_IP}"
    SCP_OPTS="-i ${SSH_KEY} -P ${SSH_PORT} -o StrictHostKeyChecking=accept-new"

    if ! test_ssh_connection "$SSH_OPTS" "$SSH_TARGET"; then
        print_error "SSH connection still failing. Aborting."
        exit 1
    fi
fi

# ====================================================================
# STEP 2: Odoo Configuration
# ====================================================================
print_section "2. Odoo Configuration"

prompt_choice  OE_VERSION      "Odoo Version"           "15 16 17 18 19"  "18"
OE_VERSION="${OE_VERSION}.0"

prompt_input   WEBSITE_NAME    "Domain Name"            "odoo.example.com"
prompt_input   OE_PORT         "Odoo HTTP Port"         "8069"
prompt_input   LONGPOLLING_PORT "Websocket/Longpolling Port" "8072"
prompt_yes_no  IS_ENTERPRISE   "Install Enterprise?"    "n"
prompt_input   OE_WORKERS      "Workers (0=dev)"        "0"

# ====================================================================
# STEP 3: SSL Certificates & Cloudflare DNS
# ====================================================================
print_section "3. Cloudflare DNS & SSL Certificates"

# Auto-detect root domain
AUTO_ROOT_DOMAIN=$(echo "$WEBSITE_NAME" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')

prompt_input  ROOT_DOMAIN      "Root Domain (for SSL folder)" "$AUTO_ROOT_DOMAIN"

# Auto-detect SSL files from local ssl/ folder
SSL_DIR="${SCRIPT_DIR}/ssl"
LOCAL_SSL_PEM="${SSL_DIR}/cloudflare_origin.pem"
LOCAL_SSL_KEY="${SSL_DIR}/cloudflare_origin.key"

echo ""
SSL_OK=true

if [ ! -d "$SSL_DIR" ]; then
    print_error "SSL folder not found: ${SSL_DIR}"
    echo -e "  ${YELLOW}⚠  Please create the 'ssl/' folder next to deploy.sh and place your certificate files:${NC}"
    echo "       mkdir -p ${SSL_DIR}"
    echo "       cp /path/to/cloudflare_origin.pem ${SSL_DIR}/"
    echo "       cp /path/to/cloudflare_origin.key ${SSL_DIR}/"
    SSL_OK=false
fi

if [ "$SSL_OK" = true ] && [ ! -f "$LOCAL_SSL_PEM" ]; then
    print_error "Certificate file not found: ${LOCAL_SSL_PEM}"
    SSL_OK=false
fi

if [ "$SSL_OK" = true ] && [ ! -f "$LOCAL_SSL_KEY" ]; then
    print_error "Private key file not found: ${LOCAL_SSL_KEY}"
    SSL_OK=false
fi

if [ "$SSL_OK" = false ]; then
    echo ""
    echo -e "  ${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  SSL certificate files are missing!                   ║${NC}"
    echo -e "  ${RED}║                                                       ║${NC}"
    echo -e "  ${RED}║  Expected files in ssl/ folder:                       ║${NC}"
    echo -e "  ${RED}║    • ssl/cloudflare_origin.pem                        ║${NC}"
    echo -e "  ${RED}║    • ssl/cloudflare_origin.key                        ║${NC}"
    echo -e "  ${RED}║                                                       ║${NC}"
    echo -e "  ${RED}║  Get them from: Cloudflare Dashboard                  ║${NC}"
    echo -e "  ${RED}║    → SSL/TLS → Origin Server → Create Certificate    ║${NC}"
    echo -e "  ${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi

print_step "SSL certificate : ${LOCAL_SSL_PEM}"
print_step "SSL private key : ${LOCAL_SSL_KEY}"
echo ""
echo -e "  ${BLUE}ℹ${NC} Will be uploaded to server at:"
echo -e "     /etc/ssl/cloudflare/${ROOT_DOMAIN}/cloudflare_origin.pem"
echo -e "     /etc/ssl/cloudflare/${ROOT_DOMAIN}/cloudflare_origin.key"
echo ""

# Cloudflare DNS Update
prompt_input CLOUDFLARE_API_TOKEN "Cloudflare API Token (kosongkan jika skip setting DNS)" ""

if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
    if ! command -v jq &>/dev/null; then
        print_error "'jq' command is required for Cloudflare API. Skipping DNS update."
    else
        print_progress "Configuring Cloudflare DNS for ${WEBSITE_NAME}..."
        
        ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}" \
          -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
          -H "Content-Type: application/json" | jq -r '.result[0].id')
        
        if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
            print_error "Cloudflare Zone not found for ${ROOT_DOMAIN}. Please check API Token."
        else
            # Check existing A record with the exact same server IP
            A_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&content=$SERVER_IP" \
              -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
              -H "Content-Type: application/json")
            A_NAME=$(echo "$A_RECORD" | jq -r '.result[0].name')
            
            # Check existing record for the subdomain
            EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$WEBSITE_NAME" \
              -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
              -H "Content-Type: application/json")
            RECORD_ID=$(echo "$EXISTING" | jq -r '.result[0].id')
            RECORD_TYPE=$(echo "$EXISTING" | jq -r '.result[0].type')
            CURRENT_CONTENT=$(echo "$EXISTING" | jq -r '.result[0].content')
            
            if [ "$A_NAME" != "null" ] && [ -n "$A_NAME" ]; then
                TARGET_TYPE="CNAME"
                TARGET_CONTENT="$A_NAME"
                echo -e "  ${BLUE}ℹ${NC} Will use CNAME -> $A_NAME for $SERVER_IP"
            else
                TARGET_TYPE="A"
                TARGET_CONTENT="$SERVER_IP"
                echo -e "  ${BLUE}ℹ${NC} Will use A -> $SERVER_IP"
            fi
            
            if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "" ]; then
                echo -e "  ${BLUE}ℹ${NC} DNS Record not found. Creating..."
                curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                    -H "Content-Type: application/json" \
                    --data "{
                      \"type\": \"$TARGET_TYPE\",
                      \"name\": \"$WEBSITE_NAME\",
                      \"content\": \"$TARGET_CONTENT\",
                      \"ttl\": 1,
                      \"proxied\": true
                    }" > /dev/null
                print_step "Cloudflare DNS Configured: $TARGET_TYPE created"
            else
                if [[ "$RECORD_TYPE" == "$TARGET_TYPE" && "$CURRENT_CONTENT" == "$TARGET_CONTENT" ]]; then
                    print_step "Cloudflare DNS Record is already up-to-date ($TARGET_TYPE -> $TARGET_CONTENT)"
                else
                    echo -e "  ${YELLOW}⚠${NC} Existing record is different. Updating..."
                    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                        -H "Content-Type: application/json" \
                        --data "{
                          \"type\": \"$TARGET_TYPE\",
                          \"name\": \"$WEBSITE_NAME\",
                          \"content\": \"$TARGET_CONTENT\",
                          \"ttl\": 1,
                          \"proxied\": true
                        }" > /dev/null
                    print_step "Cloudflare DNS Configured: updated to $TARGET_TYPE -> $TARGET_CONTENT"
                fi
            fi
        fi
    fi
fi

# ====================================================================
# STEP 4: PgBouncer Configuration
# ====================================================================
print_section "4. PgBouncer Configuration"

prompt_input   PGBOUNCER_PORT           "PgBouncer Port"          "6432"
prompt_choice  PGBOUNCER_POOL_MODE      "Pool Mode"               "transaction session"  "transaction"
prompt_input   PGBOUNCER_MAX_CLIENT_CONN "Max Client Connections" "200"
prompt_input   PGBOUNCER_DEFAULT_POOL_SIZE "Default Pool Size"    "20"

# ====================================================================
# STEP 5: Additional Options
# ====================================================================
print_section "5. Additional Options"

prompt_yes_no  GENERATE_RANDOM_PASSWORD "Generate Random Admin Password?" "y"

if [ "$GENERATE_RANDOM_PASSWORD" = "False" ]; then
    prompt_input  OE_SUPERADMIN  "Admin Password"  "admin"
else
    OE_SUPERADMIN="admin"
fi

prompt_yes_no  INSTALL_WKHTMLTOPDF  "Install wkhtmltopdf?"  "y"

# Auto-extract subdomain for DB name preview
AUTO_DB_NAME=$(echo "$WEBSITE_NAME" | sed "s/.${ROOT_DOMAIN}//")
prompt_yes_no  AUTO_CREATE_DB  "Auto create database '${AUTO_DB_NAME}'?"  "y"

# ====================================================================
# STEP 6: Review Summary
# ====================================================================
print_section "6. Deployment Summary"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}Server${NC}                                                     ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}    Host         : ${CYAN}${SERVER_IP}${NC}"
echo -e "${BLUE}║${NC}    SSH User     : ${CYAN}${SSH_USER}${NC}"
echo -e "${BLUE}║${NC}    SSH Port     : ${CYAN}${SSH_PORT}${NC}"
echo -e "${BLUE}║${NC}    SSH Key      : ${CYAN}${SSH_KEY}${NC}"
echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}Odoo${NC}                                                       ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}    Version      : ${CYAN}${OE_VERSION}${NC}"
echo -e "${BLUE}║${NC}    Domain       : ${CYAN}${WEBSITE_NAME}${NC}"
echo -e "${BLUE}║${NC}    HTTP Port    : ${CYAN}${OE_PORT}${NC}"
echo -e "${BLUE}║${NC}    WS Port      : ${CYAN}${LONGPOLLING_PORT}${NC}"
echo -e "${BLUE}║${NC}    Enterprise   : ${CYAN}${IS_ENTERPRISE}${NC}"
echo -e "${BLUE}║${NC}    Workers      : ${CYAN}${OE_WORKERS}${NC}"
echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}SSL (Cloudflare)${NC}                                             ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}    Root Domain  : ${CYAN}${ROOT_DOMAIN}${NC}"
echo -e "${BLUE}║${NC}    Local Files  : ${CYAN}ssl/cloudflare_origin.pem${NC}"
echo -e "${BLUE}║${NC}                   ${CYAN}ssl/cloudflare_origin.key${NC}"
echo -e "${BLUE}║${NC}    Remote Path  : ${CYAN}/etc/ssl/cloudflare/${ROOT_DOMAIN}/${NC}"
echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}  ${BOLD}PgBouncer${NC}                                                    ${BLUE}║${NC}"
echo -e "${BLUE}║${NC}    Port         : ${CYAN}${PGBOUNCER_PORT}${NC}"
echo -e "${BLUE}║${NC}    Pool Mode    : ${CYAN}${PGBOUNCER_POOL_MODE}${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

echo ""
echo -ne "  ${BOLD}${YELLOW}Proceed with deployment? (y/n)${NC}: "
read CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo ""
    echo "  Deployment cancelled."
    exit 0
fi

# ====================================================================
# STEP 7: Prepare Install Script
# ====================================================================
print_section "7. Preparing Installation"

# Create temp directory for modified script
TEMP_DIR=$(mktemp -d)
TEMP_SCRIPT="${TEMP_DIR}/odoo_install.sh"

# Copy install script to temp
cp "$INSTALL_SCRIPT" "$TEMP_SCRIPT"

# Replace configuration variables in the script using sed
# Using | as delimiter to avoid conflicts with paths
print_progress "Configuring install script with your settings..."

sed -i.bak "s|^OE_VERSION=.*|OE_VERSION=\"${OE_VERSION}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^WEBSITE_NAME=.*|WEBSITE_NAME=\"${WEBSITE_NAME}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^OE_PORT=.*|OE_PORT=\"${OE_PORT}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^LONGPOLLING_PORT=.*|LONGPOLLING_PORT=\"${LONGPOLLING_PORT}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^WEBSOCKET_PORT=.*|WEBSOCKET_PORT=\"${LONGPOLLING_PORT}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^IS_ENTERPRISE=.*|IS_ENTERPRISE=\"${IS_ENTERPRISE}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^OE_WORKERS=.*|OE_WORKERS=\"${OE_WORKERS}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^INSTALL_WKHTMLTOPDF=.*|INSTALL_WKHTMLTOPDF=\"${INSTALL_WKHTMLTOPDF}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^GENERATE_RANDOM_PASSWORD=.*|GENERATE_RANDOM_PASSWORD=\"${GENERATE_RANDOM_PASSWORD}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^OE_SUPERADMIN=.*|OE_SUPERADMIN=\"${OE_SUPERADMIN}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^ROOT_DOMAIN=.*|ROOT_DOMAIN=\"${ROOT_DOMAIN}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^PGBOUNCER_PORT=.*|PGBOUNCER_PORT=\"${PGBOUNCER_PORT}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^PGBOUNCER_POOL_MODE=.*|PGBOUNCER_POOL_MODE=\"${PGBOUNCER_POOL_MODE}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^PGBOUNCER_MAX_CLIENT_CONN=.*|PGBOUNCER_MAX_CLIENT_CONN=\"${PGBOUNCER_MAX_CLIENT_CONN}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^PGBOUNCER_DEFAULT_POOL_SIZE=.*|PGBOUNCER_DEFAULT_POOL_SIZE=\"${PGBOUNCER_DEFAULT_POOL_SIZE}\"|" "$TEMP_SCRIPT"
sed -i.bak "s|^AUTO_CREATE_DB=.*|AUTO_CREATE_DB=\"${AUTO_CREATE_DB}\"|" "$TEMP_SCRIPT"

# Remove sed backup files
rm -f "${TEMP_SCRIPT}.bak"

print_step "Install script configured"

# ====================================================================
# STEP 8: Upload Files to Server
# ====================================================================
print_section "8. Uploading Files to Server"

# Create remote directories
print_progress "Creating remote directories..."
ssh $SSH_OPTS "$SSH_TARGET" "mkdir -p /tmp/odoo-deploy && mkdir -p /etc/ssl/cloudflare/${ROOT_DOMAIN}"
print_step "Remote directories created"

# Upload install script
print_progress "Uploading install script..."
scp $SCP_OPTS "$TEMP_SCRIPT" "${SSH_TARGET}:/tmp/odoo-deploy/odoo_install.sh"
print_step "Install script uploaded"

# Upload SSL certificates
print_progress "Uploading SSL certificate (.pem)..."
scp $SCP_OPTS "$LOCAL_SSL_PEM" "${SSH_TARGET}:/etc/ssl/cloudflare/${ROOT_DOMAIN}/cloudflare_origin.pem"
print_step "SSL certificate uploaded"

print_progress "Uploading SSL private key (.key)..."
scp $SCP_OPTS "$LOCAL_SSL_KEY" "${SSH_TARGET}:/etc/ssl/cloudflare/${ROOT_DOMAIN}/cloudflare_origin.key"
print_step "SSL private key uploaded"

# Set SSL permissions on server
print_progress "Setting SSL file permissions..."
ssh $SSH_OPTS "$SSH_TARGET" "chmod 644 /etc/ssl/cloudflare/${ROOT_DOMAIN}/cloudflare_origin.pem && chmod 600 /etc/ssl/cloudflare/${ROOT_DOMAIN}/cloudflare_origin.key && chown root:root /etc/ssl/cloudflare/${ROOT_DOMAIN}/*"
print_step "SSL permissions configured"

# ====================================================================
# STEP 9: Run Installation on Server
# ====================================================================
print_section "9. Running Installation on Server"

echo -e "  ${YELLOW}This may take 10-30 minutes depending on server speed.${NC}"
echo -e "  ${YELLOW}Live output from server:${NC}"
echo ""
echo -e "${BLUE}════════════════════ SERVER OUTPUT ════════════════════${NC}"
echo ""

# Make script executable and run it
ssh $SSH_OPTS -t "$SSH_TARGET" "chmod +x /tmp/odoo-deploy/odoo_install.sh && bash /tmp/odoo-deploy/odoo_install.sh"
INSTALL_EXIT_CODE=$?

echo ""
echo -e "${BLUE}══════════════════ END SERVER OUTPUT ══════════════════${NC}"
echo ""

if [ $INSTALL_EXIT_CODE -ne 0 ]; then
    print_error "Installation failed with exit code: $INSTALL_EXIT_CODE"
    print_info "Check the server output above for errors."
    print_info "You can also SSH into the server to debug:"
    echo "       ssh ${SSH_OPTS} ${SSH_TARGET}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

print_step "Installation completed successfully"

# ====================================================================
# STEP 10: Verify Services
# ====================================================================
print_section "10. Verifying Services"

echo -e "  ${YELLOW}Checking services on remote server...${NC}"
echo ""

# Check each service
SERVICES=("postgresql" "pgbouncer" "odoo-server" "nginx")
ALL_OK=true

for svc in "${SERVICES[@]}"; do
    STATUS=$(ssh $SSH_OPTS "$SSH_TARGET" "systemctl is-active $svc 2>/dev/null || echo 'inactive'")
    if [ "$STATUS" = "active" ]; then
        print_step "$svc: ${GREEN}active${NC}"
    else
        print_error "$svc: ${RED}${STATUS}${NC}"
        ALL_OK=false
    fi
done

# Check if Odoo port is listening
echo ""
PORT_CHECK=$(ssh $SSH_OPTS "$SSH_TARGET" "ss -tlnp | grep ':${OE_PORT}' | head -1" 2>/dev/null || true)
if [ -n "$PORT_CHECK" ]; then
    print_step "Odoo port ${OE_PORT}: ${GREEN}listening${NC}"
else
    print_info "Odoo port ${OE_PORT}: not yet listening (may still be starting)"
fi

# Check Nginx SSL
NGINX_CHECK=$(ssh $SSH_OPTS "$SSH_TARGET" "nginx -t 2>&1" || true)
if echo "$NGINX_CHECK" | grep -q "successful"; then
    print_step "Nginx config: ${GREEN}valid${NC}"
else
    print_error "Nginx config: check needed"
fi

# ====================================================================
# STEP 11: Final Summary
# ====================================================================
echo ""
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                            ║${NC}"
echo -e "${GREEN}║              🎉 DEPLOYMENT COMPLETE! 🎉                    ║${NC}"
echo -e "${GREEN}║                                                            ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}Access your Odoo:${NC}                                        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    🌐 https://${WEBSITE_NAME}${NC}"
echo -e "${GREEN}║${NC}    🔧 http://${SERVER_IP}:${OE_PORT} (direct)${NC}"
echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"

if [ "$AUTO_CREATE_DB" = "True" ]; then
    # Retrieve the admin password from server
    REMOTE_ADMIN_PASS=$(ssh $SSH_OPTS "$SSH_TARGET" "grep ^admin_passwd /etc/odoo-server.conf 2>/dev/null | awk -F' = ' '{print \$2}'" 2>/dev/null || echo "(check /etc/odoo-server.conf)")
    echo -e "${GREEN}║${NC}  ${BOLD}Database:${NC}                                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    DB Name       : ${CYAN}${AUTO_DB_NAME}${NC}"
    echo -e "${GREEN}║${NC}    Admin Password: ${CYAN}${REMOTE_ADMIN_PASS}${NC}"
    echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"
fi

echo -e "${GREEN}║${NC}  ${BOLD}SSH to server:${NC}                                           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_TARGET}${NC}"
echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}Service commands (on server):${NC}                             ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    sudo systemctl restart odoo-server${NC}"
echo -e "${GREEN}║${NC}    sudo systemctl status odoo-server${NC}"
echo -e "${GREEN}║${NC}    tail -f /var/log/odoo/odoo-server.log${NC}"
echo -e "${GREEN}║${NC}                                                            ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$ALL_OK" = false ]; then
    echo -e "  ${YELLOW}⚠  Some services are not running. SSH into the server to check.${NC}"
fi

# ====================================================================
# CLEANUP
# ====================================================================
rm -rf "$TEMP_DIR"

echo -e "  ${GREEN}Temporary files cleaned up.${NC}"
echo ""

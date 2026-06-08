#!/usr/bin/env bash
# =============================================================================
# import-from-softaculous.sh
# Restores a MediaWiki Softaculous backup (.tar.gz) into the Docker Compose
# project defined in this directory.
#
# USAGE:
#   ./import-from-softaculous.sh /path/to/backup.tar.gz
#
# REQUIREMENTS (host machine):
#   - bash, tar, grep, sed, mktemp  (standard on Linux/WSL/Git Bash)
#   - docker (with Compose v2, or standalone docker-compose v1)
#
# COMPATIBILITY: Linux, WSL, Git Bash on Windows
# =============================================================================

set -euo pipefail

# ----------- Colour helpers --------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
hr()   { echo -e "${BOLD}-------------------------------------------------------${NC}"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

# ----------- Helpers ---------------------------------------------------------

# Convert a Git Bash /d/foo path to D:/foo for Docker Desktop on Windows.
# Only converts when MSYS_NO_PATHCONV=1 is set (auto-conversion disabled)
# and we're on a Windows drive path. On Linux/WSL paths pass through unchanged.
to_docker_path() {
    local path="$1"
    if [[ "${MSYS_NO_PATHCONV:-0}" == "1" && "$path" =~ ^/([a-zA-Z])/(.*) ]]; then
        echo "${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
    else
        echo "$path"
    fi
}

# Read a value from .env
env_get() { grep "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'"; }

# Set or update a key in .env
env_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

# Parse a $wgXxx = "value"; line from LocalSettings.php
parse_ls() {
    grep -m1 "^\\\$${1}\s*=" "$LOCAL_SETTINGS" \
        | sed "s/.*=\s*['\"\`]\(.*\)['\"\`]\s*;.*/\1/"
}

# Run a command in the background with a spinner
run_with_spinner() {
    local msg="$1"; shift
    local _spinners=('|' '/' '-' '\')
    local _i=0 _pid _exit_code

    "$@" &
    _pid=$!
    printf "  %s... " "$msg"
    while kill -0 "$_pid" 2>/dev/null; do
        printf "\r  %s... %s" "$msg" "${_spinners[$(( _i % 4 ))]}"
        (( _i++ )) || true
        sleep 0.1
    done
    wait "$_pid" && _exit_code=0 || _exit_code=$?
    if [[ "$_exit_code" -eq 0 ]]; then
        printf "\r\033[2K  %s... done\n" "$msg"
    else
        printf "\r\033[2K  %s... failed\n" "$msg"
        return "$_exit_code"
    fi
}

# Run the correct MediaWiki update script depending on version
# maintenance/run.php was introduced in 1.40; older versions use update.php directly
mw_update() {
    if docker exec -i "$MW_CONTAINER" test -f /var/www/html/maintenance/run.php 2>/dev/null; then
        docker exec -i "$MW_CONTAINER" php maintenance/run.php update --quick
    else
        docker exec -i "$MW_CONTAINER" php maintenance/update.php --quick
    fi
}

# Copy LocalSettings.php into the container
deploy_local_settings() {
    docker cp "$(to_docker_path "$LOCAL_SETTINGS")" "$MW_CONTAINER:/var/www/html/LocalSettings.php"
    docker exec "$MW_CONTAINER" chown www-data:www-data /var/www/html/LocalSettings.php
    ok "LocalSettings.php deployed to container."
}

# Reapply all Docker-specific settings to LocalSettings.php
rewrite_local_settings() {
    sed -i \
        -e "s|^\(\$wgDBserver\s*=\s*\).*|\1\"db\";|" \
        -e "s|^\(\$wgDBname\s*=\s*\).*|\1\"${SRC_DB_NAME}\";|" \
        -e "s|^\(\$wgDBuser\s*=\s*\).*|\1\"${SRC_DB_USER}\";|" \
        -e "s|^\(\$wgDBpassword\s*=\s*\).*|\1\"${SRC_DB_PASS}\";|" \
        "$LOCAL_SETTINGS"
    sed -i "s|^\(\$wgServer\s*=\s*\).*|\1\"${WG_SERVER}\";|" "$LOCAL_SETTINGS"
    if grep -q "wgTmpDirectory" "$LOCAL_SETTINGS"; then
        sed -i 's|^\(\$wgTmpDirectory\s*=\s*\).*|\1"$IP/tmp";|' "$LOCAL_SETTINGS"
    else
        echo '' >> "$LOCAL_SETTINGS"
        echo '$wgTmpDirectory = "$IP/tmp";' >> "$LOCAL_SETTINGS"
    fi
    ok "\$wgDBserver rewritten to 'db'."
    ok "\$wgServer set to $WG_SERVER"
    ok "\$wgTmpDirectory set to \$IP/tmp"
}

# ----------- Resolve paths ---------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

# ----------- Arguments -------------------------------------------------------
BACKUP_FILE="${1:-}"
[[ -n "$BACKUP_FILE" ]] || die "Usage: $0 /path/to/softaculous-backup.tar.gz"
[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: $BACKUP_FILE"
BACKUP_FILE="$(cd "$(dirname "$BACKUP_FILE")" && pwd)/$(basename "$BACKUP_FILE")"

WORK_DIR="$PROJECT_DIR/.work"
mkdir -p "$WORK_DIR"
trap 'log "Cleaning up..."; rm -rf "$WORK_DIR"' EXIT

# Also add .work to .gitignore if not already there
grep -q '^\.work' "$PROJECT_DIR/.gitignore" 2>/dev/null || echo '.work/' >> "$PROJECT_DIR/.gitignore"

# Auto-create .env from .env.example if missing
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$PROJECT_DIR/.env.example" ]]; then
        cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
        ok ".env not found — copied from .env.example"
    else
        warn ".env and .env.example both missing — creating empty .env"
        touch "$ENV_FILE"
    fi
fi

# Ensure docker/extension-updates.txt and skin-updates.txt exist as files
if [[ ! -f "$PROJECT_DIR/docker/extension-updates.txt" ]]; then
    touch "$PROJECT_DIR/docker/extension-updates.txt"
    ok "Created docker/extension-updates.txt"
fi
if [[ ! -f "$PROJECT_DIR/docker/skin-updates.txt" ]]; then
    touch "$PROJECT_DIR/docker/skin-updates.txt"
    ok "Created docker/skin-updates.txt"
fi

cd "$PROJECT_DIR"

hr
echo -e "${BOLD}  MediaWiki Softaculous Import${NC}"
hr
log "Backup  : $BACKUP_FILE"
log "Project : $PROJECT_DIR"
echo ""

# =============================================================================
# Pre-flight — Fresh import or upgrade?
# =============================================================================
echo "  What would you like to do?"
echo "  1. Fresh import   (removes existing data and volumes)"
echo "  2. Upgrade        (keeps existing data, upgrades MediaWiki version)"
echo ""
while true; do
    read -r -p "  Your choice [1/2]: " import_mode
    echo ""
    if [[ "$import_mode" == "1" ]]; then
        # Fresh import — clean up existing state
        if [[ -f "$ENV_FILE" ]]; then
            # Read project name before deleting .env
            EXISTING_PROJECT=$(grep "^COMPOSE_PROJECT_NAME=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
            if [[ -n "$EXISTING_PROJECT" ]]; then
                log "Removing existing Docker stack '$EXISTING_PROJECT' and volumes..."
                COMPOSE_CMD=$(docker compose version &>/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
            COMPOSE_PROJECT_NAME="$EXISTING_PROJECT" $COMPOSE_CMD down -v 2>/dev/null || true
                ok "Volumes removed."
            fi
            rm -f "$ENV_FILE"
            ok "Removed .env"
        fi
        if [[ -f "$PROJECT_DIR/docker/extension-updates.txt" ]]; then
            rm -f "$PROJECT_DIR/docker/extension-updates.txt"
            touch "$PROJECT_DIR/docker/extension-updates.txt"
            ok "Reset docker/extension-updates.txt"
        fi
        # Re-create .env from example
        if [[ -f "$PROJECT_DIR/.env.example" ]]; then
            cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
            ok ".env reset from .env.example"
        else
            touch "$ENV_FILE"
        fi
        break
    elif [[ "$import_mode" == "2" ]]; then
        break
    else
        warn "Invalid choice — please enter 1 or 2."
        echo ""
    fi
done

# =============================================================================
# Step 1 — Read MediaWiki version from softver.txt, prompt user
# =============================================================================
log "Step 1/5 — Reading MediaWiki version..."

MW_VERSION_FULL=$(tar -xzf "$BACKUP_FILE" -O softver.txt 2>/dev/null | tr -d '[:space:]' || true)
if [[ -z "$MW_VERSION_FULL" ]]; then
    warn "softver.txt not found in backup — cannot detect version."
    MW_VERSION_FULL="unknown"
fi
MW_BACKUP_VERSION="$MW_VERSION_FULL"

# Fetch latest stable MediaWiki version if curl is available
MW_LATEST=""
if command -v curl &>/dev/null; then
    _tmp=$(mktemp)
    curl -sf --max-time 5 "https://releases.wikimedia.org/mediawiki/" \
        | grep -o 'href="[0-9]*\.[0-9]*/"' \
        | head -1 \
        | grep -o '[0-9]*\.[0-9]*' > "$_tmp" 2>/dev/null &
    _curl_pid=$!
    _spinners=('|' '/' '-' '\')
    _i=0
    printf "  Fetching latest MediaWiki version... "
    while kill -0 "$_curl_pid" 2>/dev/null; do
        printf "\r  Fetching latest MediaWiki version... %s" "${_spinners[$(( _i % 4 ))]}"
        (( _i++ )) || true
        sleep 0.1
    done
    printf "\r\033[2K  Fetching latest MediaWiki version... done\n"
    MW_LATEST=$(cat "$_tmp")
    rm -f "$_tmp"
fi

echo ""
[[ -n "$MW_LATEST" ]] && echo "  Latest stable MediaWiki version: $MW_LATEST"
echo "  Enter a newer wiki version to upgrade, or press Enter to keep the backup version."
read -r -p "  MediaWiki version [$MW_VERSION_FULL]: " MW_VERSION_INPUT
echo ""
MW_VERSION_FULL="${MW_VERSION_INPUT:-$MW_VERSION_FULL}"
UPGRADING=$([[ -n "$MW_VERSION_INPUT" && "$MW_VERSION_INPUT" != "$MW_BACKUP_VERSION" ]] && echo "yes" || echo "no")

# Strip patch version for Docker image tag (e.g. "1.37.1" → "1.37")
MW_VERSION=$(echo "$MW_VERSION_FULL" | sed 's/\([0-9]*\.[0-9]*\)\..*/\1/')
env_set "MEDIAWIKI_VERSION" "$MW_VERSION"
ok "Using MediaWiki $MW_VERSION_FULL → MEDIAWIKI_VERSION=$MW_VERSION set in .env"

# Warn about potential intermediate upgrade steps
if [[ "$UPGRADING" == "yes" ]]; then
    echo ""
    warn "Upgrading from $MW_BACKUP_VERSION to $MW_VERSION_FULL."
    echo ""
    echo "  MediaWiki only supports upgrades from up to two LTS releases ago."
    echo "  Older versions require upgrading in multiple steps."
    echo "  Strategy: pick the LTS version closest to (but below) your target"
    echo "  as your intermediate step — this minimises the number of jumps."
    echo "  For example: to reach 1.45 from 1.37, go via 1.43 (not 1.39)."
    echo ""
    echo "  LTS releases: https://www.mediawiki.org/wiki/Version_lifecycle"
    echo ""
    while true; do
        echo "  Make a choice:"
        echo "  1. Upgrade to $MW_VERSION_FULL"
        echo "  2. Choose another version"
        echo ""
        read -r -p "  Your choice [1/2]: " upgrade_choice
        echo ""
        if [[ "$upgrade_choice" == "1" ]]; then
            break
        elif [[ "$upgrade_choice" == "2" ]]; then
            read -r -p "  MediaWiki version: " MW_VERSION_INPUT
            echo ""
            MW_VERSION_FULL="${MW_VERSION_INPUT:-$MW_VERSION_FULL}"
            MW_VERSION=$(echo "$MW_VERSION_FULL" | sed 's/\([0-9]*\.[0-9]*\)\..*/\1/')
            env_set "MEDIAWIKI_VERSION" "$MW_VERSION"
            ok "Using MediaWiki $MW_VERSION_FULL → MEDIAWIKI_VERSION=$MW_VERSION set in .env"
            break
        else
            warn "Invalid choice — please enter 1 or 2."
            echo ""
        fi
    done
fi

# Prompt for MariaDB version
CURRENT_MARIADB=$(env_get "MARIADB_VERSION" || true)
CURRENT_MARIADB="${CURRENT_MARIADB:-10.11}"
echo ""
echo "  Please visit https://www.mediawiki.org/wiki/Compatibility#Database for MariaDB version requirements."
read -r -p "  MariaDB version [$CURRENT_MARIADB]: " MARIADB_INPUT
echo ""
MARIADB_VERSION="${MARIADB_INPUT:-$CURRENT_MARIADB}"
env_set "MARIADB_VERSION" "$MARIADB_VERSION"
ok "Using MariaDB $MARIADB_VERSION → MARIADB_VERSION=$MARIADB_VERSION set in .env"

# Prompt for HTTP port
CURRENT_PORT=$(env_get "HTTP_PORT" || true)
CURRENT_PORT="${CURRENT_PORT:-80}"
read -r -p "  HTTP port [$CURRENT_PORT]: " PORT_INPUT
echo ""
HTTP_PORT="${PORT_INPUT:-$CURRENT_PORT}"
env_set "HTTP_PORT" "$HTTP_PORT"
ok "Using HTTP port $HTTP_PORT → HTTP_PORT=$HTTP_PORT set in .env"

# Prompt for project name
DEFAULT_PROJECT="mw_$(echo "${MW_VERSION}" | tr "." "_")_${HTTP_PORT}"
CURRENT_PROJECT=$(env_get "COMPOSE_PROJECT_NAME" || true)
CURRENT_PROJECT="${CURRENT_PROJECT:-$DEFAULT_PROJECT}"
echo "  Project name controls container/volume naming."
read -r -p "  Project name [$CURRENT_PROJECT]: " PROJECT_INPUT
echo ""
COMPOSE_PROJECT_NAME="${PROJECT_INPUT:-$CURRENT_PROJECT}"
env_set "COMPOSE_PROJECT_NAME" "$COMPOSE_PROJECT_NAME"
ok "Using project name: $COMPOSE_PROJECT_NAME"

# =============================================================================
# Step 2 — Extract LocalSettings.php, parse DB credentials
# =============================================================================
log "Step 2/5 — Extracting LocalSettings.php..."

LOCAL_SETTINGS="$PROJECT_DIR/docker/LocalSettings.php"

if ! { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^LocalSettings.php$"; then
    die "LocalSettings.php not found in backup."
fi

run_with_spinner "Extracting LocalSettings.php" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" LocalSettings.php
cp "$WORK_DIR/LocalSettings.php" "$LOCAL_SETTINGS"
ok "LocalSettings.php saved to $LOCAL_SETTINGS"

SRC_DB_SERVER=$(parse_ls "wgDBserver")
SRC_DB_NAME=$(parse_ls "wgDBname")
SRC_DB_USER=$(parse_ls "wgDBuser")
SRC_DB_PASS=$(parse_ls "wgDBpassword")

log "Parsed from LocalSettings.php:"
log "  server : $SRC_DB_SERVER  →  will be rewritten to 'db'"
log "  name   : $SRC_DB_NAME"
log "  user   : $SRC_DB_USER"

# Sync DB credentials into .env
env_set "MYSQL_DATABASE" "$SRC_DB_NAME"
env_set "MYSQL_USER"     "$SRC_DB_USER"
env_set "MYSQL_PASSWORD" "$SRC_DB_PASS"
ok "MYSQL_DATABASE / MYSQL_USER / MYSQL_PASSWORD synced to .env"

# Auto-generate MYSQL_ROOT_PASSWORD if not already set
DB_ROOT=$(env_get "MYSQL_ROOT_PASSWORD" || true)
if [[ -z "$DB_ROOT" ]]; then
    DB_ROOT=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
    env_set "MYSQL_ROOT_PASSWORD" "$DB_ROOT"
    ok "MYSQL_ROOT_PASSWORD not set — generated and saved to .env"
fi

# Prompt for server URL
WG_SERVER=$(parse_ls "wgServer")
WG_SERVER="${WG_SERVER:-http://localhost}"
read -r -p "  Server [$WG_SERVER]: " WG_SERVER_INPUT
echo ""
WG_SERVER="${WG_SERVER_INPUT:-$WG_SERVER}"
ok "Using server: $WG_SERVER"

# =============================================================================
# Step 3 — Start stack, wait for MariaDB
# =============================================================================
log "Step 3/5 — Starting Docker Compose stack..."

if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
else
    die "Docker not found. Is Docker installed and running?"
fi

$COMPOSE up -d db mediawiki

log "Waiting for MariaDB to be ready..."
RETRIES=30
until $COMPOSE exec -T db mariadb-admin ping -uroot -p"$DB_ROOT" --silent 2>/dev/null; do
    (( RETRIES-- )) || die "MariaDB did not become ready in time."
    echo -n "."
    sleep 2
done
echo ""
ok "MariaDB is ready."

MW_CONTAINER=$($COMPOSE ps -q mediawiki | head -1)
DB_CONTAINER=$($COMPOSE ps -q db | head -1)
[[ -n "$MW_CONTAINER" ]] || die "mediawiki container not found."
[[ -n "$DB_CONTAINER" ]]  || die "db container not found."

# =============================================================================
# Step 4 — Restore images, skins (and extensions if not upgrading)
# =============================================================================
log "Step 4/5 — Restoring files..."

if { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^images/"; then
    run_with_spinner "Extracting images" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" images/
    docker exec "$MW_CONTAINER" bash -c "rm -rf /var/www/html/images/* /var/www/html/images/.* 2>/dev/null || true"
    run_with_spinner "Copying images to container" docker cp "$(to_docker_path "$WORK_DIR")/images/." "$MW_CONTAINER:/var/www/html/images/"
    docker exec "$MW_CONTAINER" chown -R www-data:www-data /var/www/html/images/
    ok "images/ restored."
else
    warn "No images/ in backup — skipping."
fi

if [[ "$UPGRADING" == "no" ]]; then
    if { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^skins/"; then
        run_with_spinner "Extracting skins" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" skins/
        log "Copying missing skins to container (skipping existing ones)..."
        for skin_dir in "$WORK_DIR/skins/"/*/; do
            skin_name=$(basename "$skin_dir")
            if ! docker exec "$MW_CONTAINER" test -d "/var/www/html/skins/$skin_name" 2>/dev/null; then
                docker cp "$(to_docker_path "$skin_dir")" "$MW_CONTAINER:/var/www/html/skins/$skin_name"
                log "  Restored: $skin_name"
            fi
        done
        docker exec "$MW_CONTAINER" chown -R www-data:www-data /var/www/html/skins/
        ok "skins/ restored (existing skins preserved)."
    else
        warn "No skins/ in backup — skipping."
    fi
fi

if [[ "$UPGRADING" == "no" ]]; then
    if { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^extensions/"; then
        run_with_spinner "Extracting extensions" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" extensions/
        docker exec "$MW_CONTAINER" bash -c "rm -rf /var/www/html/extensions/* 2>/dev/null || true"
        run_with_spinner "Copying extensions to container" docker cp "$(to_docker_path "$WORK_DIR")/extensions/." "$MW_CONTAINER:/var/www/html/extensions/"
        docker exec "$MW_CONTAINER" chown -R www-data:www-data /var/www/html/extensions/
        ok "extensions/ restored."
    else
        warn "No extensions/ in backup — skipping."
    fi
else
    log "Upgrade detected — skipping extensions restore (will be updated after schema upgrade)."
fi

# =============================================================================
# Step 5 — Import SQL, rewrite LocalSettings.php
# =============================================================================
log "Step 5/5 — Importing database..."

if ! { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^softsql.sql$"; then
    die "softsql.sql not found in backup."
fi

# Check if database already has tables
DB_TABLE_COUNT=$(docker exec -i "$DB_CONTAINER" mariadb -uroot -p"$DB_ROOT" \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${SRC_DB_NAME}';" \
    --skip-column-names 2>/dev/null || echo "0")
DB_TABLE_COUNT=$(echo "$DB_TABLE_COUNT" | tr -d '[:space:]')

SKIP_SQL=false
if [[ "$DB_TABLE_COUNT" -gt 0 ]]; then
    echo ""
    warn "Database '$SRC_DB_NAME' already exists and has $DB_TABLE_COUNT tables."
    read -r -p "  Re-import SQL dump? This will wipe existing data. [y/N]: " reimport
    echo ""
    [[ "${reimport,,}" != "y" ]] && SKIP_SQL=true && log "Skipping SQL import — keeping existing database."
fi

if [[ "$SKIP_SQL" == "false" ]]; then
    run_with_spinner "Extracting SQL dump" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" softsql.sql

    docker exec -i "$DB_CONTAINER" mariadb -uroot -p"$DB_ROOT" \
        -e "DROP DATABASE IF EXISTS \`${SRC_DB_NAME}\`; CREATE DATABASE \`${SRC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    _sql_path="$(to_docker_path "$WORK_DIR")/softsql.sql"
    _db_spinners=('|' '/' '-' '\')
    _db_i=0
    printf "  Importing database... "
    docker exec -i "$DB_CONTAINER" mariadb -uroot -p"$DB_ROOT" "$SRC_DB_NAME" < "$_sql_path" &
    _pid=$!
    while kill -0 "$_pid" 2>/dev/null; do
        printf "\r  Importing database... %s" "${_db_spinners[$(( _db_i % 4 ))]}"
        (( _db_i++ )) || true
        sleep 0.1
    done
    wait "$_pid"
    printf "\r  Importing database... done\n"
    ok "Database imported."
fi

# Rewrite LocalSettings.php to point at Docker
rewrite_local_settings

if [[ "$UPGRADING" == "no" ]]; then
    # Deploy LocalSettings.php and create tmp dir
    deploy_local_settings
fi

# =============================================================================
# Upgrade steps (only when a newer MW version was selected)
# =============================================================================
if [[ "$UPGRADING" == "yes" ]]; then
    log "Upgrade detected ($MW_BACKUP_VERSION → $MW_VERSION_FULL) — pulling new image..."

    $COMPOSE pull mediawiki
    $COMPOSE up -d mediawiki
    log "Waiting for container to be ready..."
    sleep 3

    # Restore LocalSettings.php from backup and reapply Docker settings
    log "Restoring LocalSettings.php from backup..."
    run_with_spinner "Extracting LocalSettings.php" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" LocalSettings.php
    cp "$WORK_DIR/LocalSettings.php" "$LOCAL_SETTINGS"
    rewrite_local_settings
    ok "LocalSettings.php restored and updated."
    deploy_local_settings

    # Restore missing extensions from backup
    if { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^extensions/"; then
        run_with_spinner "Extracting extensions" tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" extensions/
        log "Copying missing extensions to container (skipping existing ones)..."
        for ext_dir in "$WORK_DIR/extensions/"/*/; do
            ext_name=$(basename "$ext_dir")
            if ! docker exec "$MW_CONTAINER" test -d "/var/www/html/extensions/$ext_name" 2>/dev/null; then
                docker cp "$(to_docker_path "$ext_dir")" "$MW_CONTAINER:/var/www/html/extensions/$ext_name"
                log "  Restored: $ext_name"
            fi
        done
        docker exec "$MW_CONTAINER" chown -R www-data:www-data /var/www/html/extensions/
        ok "extensions/ restored from backup (existing extensions preserved)."
    else
        warn "No extensions/ in backup — skipping."
    fi

    # Restore missing skins from backup
    if { tar -tzf "$BACKUP_FILE" 2>/dev/null || true; } | grep -q "^skins/"; then
        [[ ! -d "$WORK_DIR/skins" ]] && tar -xzf "$BACKUP_FILE" -C "$WORK_DIR" skins/
        log "Copying missing skins to container (skipping existing ones)..."
        for skin_dir in "$WORK_DIR/skins/"/*/; do
            skin_name=$(basename "$skin_dir")
            if ! docker exec "$MW_CONTAINER" test -d "/var/www/html/skins/$skin_name" 2>/dev/null; then
                docker cp "$(to_docker_path "$skin_dir")" "$MW_CONTAINER:/var/www/html/skins/$skin_name"
                log "  Restored: $skin_name"
            fi
        done
        docker exec "$MW_CONTAINER" chown -R www-data:www-data /var/www/html/skins/
        ok "skins/ restored (existing skins preserved)."
    fi

    $COMPOSE restart mediawiki

    log "Running extension and skin updater..."
    if ! docker exec -it "$MW_CONTAINER" bash /var/www/html/update-extensions-skins.sh; then
        echo ""
        warn "Extension/skin update failed or was incomplete."
        echo "  To retry manually, run:"
        echo "    docker exec -it $MW_CONTAINER bash /var/www/html/update-extensions-skins.sh"
        echo "  Or to reset and re-ask all:"
        echo "    docker exec -it $MW_CONTAINER bash /var/www/html/update-extensions-skins.sh --reset"
        echo ""
    fi

    # Run maintenance update to apply all schema changes
    log "Running final database schema update..."
    mw_update
    ok "Database schema updated."

    # Offer to create a backup and do another upgrade
    echo ""
    read -r -p "  Create a backup and upgrade to another version? [y/N]: " do_next
    echo ""
    if [[ "${do_next,,}" == "y" ]]; then
        log "Creating backup of current state..."
        NEXT_BACKUP="$PROJECT_DIR/mw-backup-${MW_VERSION}-$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
        if ! bash "$PROJECT_DIR/backup-mediawiki.sh" "$NEXT_BACKUP"; then
            echo ""
            warn "Backup failed."
            echo "  To retry manually, run:"
            echo "    bash $PROJECT_DIR/backup-mediawiki.sh"
            echo ""
        else
            ok "Backup created: $NEXT_BACKUP"
            log "Starting next upgrade..."
            bash "$PROJECT_DIR/import-from-softaculous.sh" "$NEXT_BACKUP"
        fi
    fi
fi

# =============================================================================
# Done
# =============================================================================
hr
ok "Import complete!"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "  1. docker compose restart mediawiki"
echo "  2. Open: http://localhost:$(env_get HTTP_PORT)"
echo ""

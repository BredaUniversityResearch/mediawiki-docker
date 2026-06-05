#!/usr/bin/env bash
# =============================================================================
# backup-mediawiki.sh
# Creates a Softaculous-compatible .tar.gz backup from the running Docker stack.
# The output can be used directly with import-from-softaculous.sh.
#
# USAGE:
#   ./backup-mediawiki.sh [output-file.tar.gz]
#
# If no output file is specified, it defaults to:
#   mw-backup-{version}-{date}.tar.gz
#
# COMPATIBILITY: Linux, WSL, Git Bash on Windows
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
hr()   { echo -e "${BOLD}-------------------------------------------------------${NC}"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

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
        printf "\r  %s... done\n" "$msg"
    else
        printf "\r  %s... failed\n" "$msg"
        return "$_exit_code"
    fi
}

to_docker_path() {
    local path="$1"
    if [[ "${MSYS_NO_PATHCONV:-0}" == "1" && "$path" =~ ^/([a-zA-Z])/(.*) ]]; then
        echo "${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
    else
        echo "$path"
    fi
}

# ----------- Resolve paths ---------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

[[ -f "$ENV_FILE" ]] || die ".env not found. Is the project set up?"

env_get() { grep "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'"; }

MW_VERSION=$(env_get "MEDIAWIKI_VERSION")
DB_ROOT=$(env_get "MYSQL_ROOT_PASSWORD")
DB_NAME=$(env_get "MYSQL_DATABASE")
DATE=$(date +%Y-%m-%d_%H-%M-%S)
OUTPUT_FILE="${1:-$PROJECT_DIR/mw-backup-${MW_VERSION}-${DATE}.tar.gz}"

WORK_DIR="$PROJECT_DIR/.work-backup"
mkdir -p "$WORK_DIR"
trap 'log "Cleaning up..."; rm -rf "$WORK_DIR"' EXIT

# Determine compose command
if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
else
    die "Docker not found."
fi

MW_CONTAINER=$($COMPOSE ps -q mediawiki | head -1)
DB_CONTAINER=$($COMPOSE ps -q db | head -1)
[[ -n "$MW_CONTAINER" ]] || die "mediawiki container not found. Is the stack running?"
[[ -n "$DB_CONTAINER" ]]  || die "db container not found. Is the stack running?"

hr
echo -e "${BOLD}  MediaWiki Backup${NC}"
hr
log "Version : $MW_VERSION"
log "Output  : $OUTPUT_FILE"
echo ""

# Create softver.txt
echo "$MW_VERSION" > "$WORK_DIR/softver.txt"
ok "softver.txt written: $MW_VERSION"

# Copy LocalSettings.php
cp "$PROJECT_DIR/docker/LocalSettings.php" "$WORK_DIR/LocalSettings.php"
ok "LocalSettings.php copied."

# Dump database
log "Dumping database '$DB_NAME'..."
_db_spinners=('|' '/' '-' '\')
_db_i=0
printf "  Dumping database... "
docker exec -i "$DB_CONTAINER" mariadb-dump -uroot -p"$DB_ROOT" \
    --single-transaction --routines --triggers "$DB_NAME" > "$WORK_DIR/softsql.sql" &
_pid=$!
while kill -0 "$_pid" 2>/dev/null; do
    printf "\r  Dumping database... %s" "${_db_spinners[$(( _db_i % 4 ))]}"
    (( _db_i++ )) || true
    sleep 0.1
done
wait "$_pid"
printf "\r  Dumping database... done\n"
ok "softsql.sql written."

# Copy files from container
for folder in images extensions skins; do
    run_with_spinner "Copying $folder from container" \
        docker cp "$MW_CONTAINER:/var/www/html/${folder}/." "$(to_docker_path "$WORK_DIR")/${folder}/"
    ok "$folder/ copied."
done

# Create the tar.gz
log "Creating archive..."
run_with_spinner "Archiving" tar -czf "$OUTPUT_FILE" -C "$WORK_DIR" \
    softver.txt softsql.sql LocalSettings.php images/ extensions/ skins/

hr
ok "Backup complete!"
echo ""
echo -e "  ${BOLD}Output file:${NC} $OUTPUT_FILE"
echo ""

#!/usr/bin/env bash
# =============================================================================
# update-extensions-skins.sh
# MediaWiki extension and skin updater — run inside the container via docker exec
#
# USAGE:
#   update-extensions-skins.sh           # Update all extensions and skins
#   update-extensions-skins.sh --reset   # Re-ask all (pre-fills saved URLs)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-/var/www/html/extensions}"
SKINS_DIR="${SKINS_DIR:-/var/www/html/skins}"
LOCAL_SETTINGS="/var/www/html/LocalSettings.php"
UPDATES_FILE="$SCRIPT_DIR/extension-updates.txt"
SKINS_UPDATES_FILE="$SCRIPT_DIR/skin-updates.txt"
UPDATES_EXAMPLE="$SCRIPT_DIR/extension-updates.txt.example"
WORK_DIR="/tmp/ext-update-$$"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
hr()   { echo -e "${BOLD}-------------------------------------------------------${NC}"; }

RESET=false
[[ "${1:-}" == "--reset" ]] && RESET=true

# -----------------------------------------------------------------------------
# Read MEDIAWIKI_VERSION from .env → REL format (e.g. "1.45" → "REL1_45")
# -----------------------------------------------------------------------------
mw_rel_version() {
    local ver=""
    [[ -f "$SCRIPT_DIR/.env" ]] && \
        ver=$(grep "^MEDIAWIKI_VERSION=" "$SCRIPT_DIR/.env" 2>/dev/null \
              | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')
    [[ -n "$ver" ]] && echo "REL$(echo "$ver" | tr '.' '_')" || echo ""
}

# -----------------------------------------------------------------------------
# Fetch .tar.gz URL from ExtensionDistributor (no spinner)
# -----------------------------------------------------------------------------
fetch_extension_url() {
    local ext_name="$1" rel_version="$2"
    command -v curl &>/dev/null || { echo ""; return; }
    curl -sI --max-time 5 \
        "https://www.mediawiki.org/wiki/Special:ExtensionDistributor?extdistname=${ext_name}&extdistversion=${rel_version}" \
        | grep -i "^refresh:" | grep -o 'https://[^ ]*' | tr -d '[:space:]' || true
}

fetch_skin_url() {
    local skin_name="$1" rel_version="$2"
    command -v curl &>/dev/null || { echo ""; return; }
    curl -sI --max-time 5 \
        "https://www.mediawiki.org/wiki/Special:SkinDistributor?extdistname=${skin_name}&extdistversion=${rel_version}" \
        | grep -i "^refresh:" | grep -o 'https://[^ ]*' | tr -d '[:space:]' || true
}

# -----------------------------------------------------------------------------
# Read saved URL for an extension from extension-updates.txt
# -----------------------------------------------------------------------------
saved_url() {
    local ext_name="$1"
    grep "^${ext_name}[[:space:]]" "$UPDATES_FILE" 2>/dev/null \
        | awk '{print $2}' | head -1 || true
}

saved_skin_url() {
    local skin_name="$1"
    grep "^${skin_name}[[:space:]]" "$SKINS_UPDATES_FILE" 2>/dev/null \
        | awk '{print $2}' | head -1 || true
}

# -----------------------------------------------------------------------------
# Save or update an entry in extension-updates.txt
# -----------------------------------------------------------------------------
save_url() {
    local ext_name="$1" url="$2"
    if grep -q "^${ext_name}[[:space:]]" "$UPDATES_FILE" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        grep -v "^${ext_name}[[:space:]]" "$UPDATES_FILE" > "$tmp" || true
        echo "${ext_name}    ${url}" >> "$tmp"
        cat "$tmp" > "$UPDATES_FILE"
        rm -f "$tmp"
    else
        echo "${ext_name}    ${url}" >> "$UPDATES_FILE"
    fi
}

save_skin_url() {
    local skin_name="$1" url="$2"
    if grep -q "^${skin_name}[[:space:]]" "$SKINS_UPDATES_FILE" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        grep -v "^${skin_name}[[:space:]]" "$SKINS_UPDATES_FILE" > "$tmp" || true
        echo "${skin_name}    ${url}" >> "$tmp"
        cat "$tmp" > "$SKINS_UPDATES_FILE"
        rm -f "$tmp"
    else
        echo "${skin_name}    ${url}" >> "$SKINS_UPDATES_FILE"
    fi
}

# -----------------------------------------------------------------------------
# Disable an extension in LocalSettings.php
# -----------------------------------------------------------------------------
disable_in_local_settings() {
    local ext_name="$1" load_fn="${2:-wfLoadExtension}"
    if grep -q "${load_fn}( '${ext_name}' )" "$LOCAL_SETTINGS" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        sed "s|^\(\s*\)${load_fn}( '${ext_name}' )|\1//${load_fn}( '${ext_name}' )|" "$LOCAL_SETTINGS" > "$tmp"
        cat "$tmp" > "$LOCAL_SETTINGS"
        rm -f "$tmp"
        ok "${ext_name} disabled in LocalSettings.php."
    fi
}

# -----------------------------------------------------------------------------
# Install an extension from a URL (tar.gz or zip)
# -----------------------------------------------------------------------------
install_extension() {
    local ext_name="$1" url="$2" base_dir="${3:-$EXTENSIONS_DIR}"
    local archive_file target_dir top_entries top_count

    mkdir -p "$WORK_DIR"
    trap 'rm -rf "$WORK_DIR"' EXIT

    archive_file="$(basename "$url" | sed 's/?.*//')"
    target_dir="$base_dir/$ext_name"

    log "Downloading $ext_name..."
    curl -fL --progress-bar -o "$WORK_DIR/$archive_file" "$url" \
        || die "Failed to download: $url"

    rm -rf "$target_dir"

    if [[ "$url" == *.zip ]]; then
        top_entries=$(unzip -Z1 "$WORK_DIR/$archive_file" | cut -d'/' -f1 | sort -u)
        top_count=$(echo "$top_entries" | wc -l)
        if [[ "$top_count" -eq 1 ]]; then
            unzip -q "$WORK_DIR/$archive_file" -d "$WORK_DIR"
            mv "$WORK_DIR/$(echo "$top_entries" | head -1)" "$target_dir"
        else
            mkdir -p "$target_dir"
            unzip -q "$WORK_DIR/$archive_file" -d "$target_dir"
        fi
    else
        top_entries=$(tar -tzf "$WORK_DIR/$archive_file" | cut -d'/' -f1 | sort -u)
        top_count=$(echo "$top_entries" | wc -l)
        if [[ "$top_count" -eq 1 ]]; then
            tar -xzf "$WORK_DIR/$archive_file" -C "$WORK_DIR"
            mv "$WORK_DIR/$(echo "$top_entries" | head -1)" "$target_dir"
        else
            mkdir -p "$target_dir"
            tar -xzf "$WORK_DIR/$archive_file" -C "$target_dir"
        fi
    fi

    rm -f "$WORK_DIR/$archive_file"
    ok "$ext_name updated."
}

# -----------------------------------------------------------------------------
# Prompt for URL and install, retrying on empty input or failed download
# -----------------------------------------------------------------------------
prompt_and_install() {
    local ext_name="$1" default_url="${2:-}"

    # If we have a default URL, try it automatically first
    if [[ -n "$default_url" ]]; then
        log "Downloading $ext_name from default URL..."
        if install_extension "$ext_name" "$default_url"; then
            save_url "$ext_name" "$default_url"
            (( success++ )) || true
            echo ""
            return 0
        else
            warn "Default URL failed — please enter a URL manually."
            echo ""
        fi
    fi

    # Fall back to manual prompt
    while true; do
        read -r -p "  Download URL (or - to skip): " url_input
        url="$url_input"
        echo ""

        if [[ -z "$url" ]]; then
            warn "No URL entered — please enter a URL or - to skip."
            continue
        fi

        if [[ "$url" == "-" ]]; then
            save_url "$ext_name" "-"
            log "$ext_name: marked as skip."
            read -r -p "  Disable $ext_name in LocalSettings.php? [y/N]: " disable_ext
            echo ""
            [[ "${disable_ext,,}" == "y" ]] && disable_in_local_settings "$ext_name"
            (( skipped++ )) || true
            return 0
        fi

        save_url "$ext_name" "$url"

        if install_extension "$ext_name" "$url"; then
            (( success++ )) || true
            echo ""
            return 0
        else
            warn "Download failed — please check the URL and try again."
        fi
    done
}

# Skin variant of prompt_and_install that uses SKINS_UPDATES_FILE
prompt_and_install_skin() {
    local ext_name="$1" default_url="${2:-}"

    # If we have a default URL, try it automatically first
    if [[ -n "$default_url" ]]; then
        log "Downloading skin $ext_name from default URL..."
        if install_extension "$ext_name" "$default_url" "$SKINS_DIR"; then
            save_skin_url "$ext_name" "$default_url"
            (( skin_success++ )) || true
            echo ""
            return 0
        else
            warn "Default URL failed — please enter a URL manually."
            echo ""
        fi
    fi

    # Fall back to manual prompt
    while true; do
        read -r -p "  Download URL (or - to skip): " url_input
        url="$url_input"
        echo ""

        if [[ -z "$url" ]]; then
            warn "No URL entered — please enter a URL or - to skip."
            continue
        fi

        if [[ "$url" == "-" ]]; then
            save_skin_url "$ext_name" "-"
            log "$ext_name: marked as skip."
            read -r -p "  Disable $ext_name in LocalSettings.php? [y/N]: " disable_ext
            echo ""
            [[ "${disable_ext,,}" == "y" ]] && disable_in_local_settings "$ext_name" "wfLoadSkin"
            (( skin_skipped++ )) || true
            return 0
        fi

        save_skin_url "$ext_name" "$url"

        if install_extension "$ext_name" "$url" "$SKINS_DIR"; then
            (( skin_success++ )) || true
            echo ""
            return 0
        else
            warn "Download failed — please check the URL and try again."
        fi
    done
}

# =============================================================================
# Main
# =============================================================================
hr
echo -e "${BOLD}  MediaWiki Extension & Skin Updater${NC}"
hr
echo ""

[[ -d "$EXTENSIONS_DIR" ]] || die "Extensions directory not found: $EXTENSIONS_DIR"


REL_VERSION=$(mw_rel_version)
[[ -n "$REL_VERSION" ]] && log "MediaWiki version: $REL_VERSION" \
                        || warn "MEDIAWIKI_VERSION not set in .env — cannot auto-fetch URLs"
echo ""

# Build list of all extension dirs, excluding already-skipped ones (unless --reset)
all_extensions=()
for ext_dir in "$EXTENSIONS_DIR"/*/; do
    [[ -d "$ext_dir" ]] || continue
    ext_name=$(basename "$ext_dir")
    _saved=$(saved_url "$ext_name")
    if [[ "$_saved" == "-" ]] && [[ "$RESET" == false ]]; then
        continue
    fi
    all_extensions+=("$ext_name")
done

# =============================================================================
# Phase 1 — Extensions without a version file
# =============================================================================
no_version=()
for ext_name in "${all_extensions[@]}"; do
    version_file="$EXTENSIONS_DIR/$ext_name/version"
    if [[ ! -f "$version_file" ]]; then
        no_version+=("$ext_name")
    fi
done

if [[ "${#no_version[@]}" -gt 0 ]]; then
    echo -e "${BOLD}Phase 1 — Extensions without a version file${NC}"
    echo "  These are likely bundled core extensions or manually installed ones."
    echo "  They will be skipped and not shown again."
    echo ""
    for ext_name in "${no_version[@]}"; do
        echo "    - $ext_name"
        save_url "$ext_name" "-"
    done
    echo ""
fi

# Build list of extensions with version files
versioned_extensions=()
for ext_name in "${all_extensions[@]}"; do
    version_file="$EXTENSIONS_DIR/$ext_name/version"
    [[ -f "$version_file" ]] || continue
    versioned_extensions+=("$ext_name")
done

# =============================================================================
# Phase 2 — Extensions incompatible with target MW version
# =============================================================================
incompatible=()
compatible=()

if [[ -n "$REL_VERSION" ]]; then
    echo -e "${BOLD}Phase 2 — Checking compatibility with $REL_VERSION...${NC}"
    for ext_name in "${versioned_extensions[@]}"; do
        version_file="$EXTENSIONS_DIR/$ext_name/version"
        ext_version=$(head -1 "$version_file" | tr -d '[:space:]' | cut -d: -f2)

        # Skip if already at target version
        if [[ "$ext_version" == "$REL_VERSION" ]] && [[ "$RESET" == false ]]; then
            ok "$ext_name: already at $REL_VERSION — skipping"
            continue
        fi

        log "Checking $ext_name..."
        url=$(fetch_extension_url "$ext_name" "$REL_VERSION")
        if [[ -z "$url" ]]; then
            incompatible+=("$ext_name")
        else
            compatible+=("$ext_name:$url")
        fi
    done
    echo ""

    if [[ "${#incompatible[@]}" -gt 0 ]]; then
        warn "The following extensions have no package for $REL_VERSION:"
        echo ""
        for ext_name in "${incompatible[@]}"; do
            echo "    - $ext_name"
        done
        echo ""
        echo "  Make a choice:"
        echo "  1. Disable them all in LocalSettings.php (skip next time)"
        echo "  2. I will enter a custom URL for each in Phase 3"
        echo ""
        while true; do
            read -r -p "  Your choice [1/2]: " incompat_choice
            echo ""
            if [[ "$incompat_choice" == "1" ]]; then
                for ext_name in "${incompatible[@]}"; do
                    disable_in_local_settings "$ext_name"
                    save_url "$ext_name" "-"
                done
                incompatible=()
                break
            elif [[ "$incompat_choice" == "2" ]]; then
                break
            else
                warn "Invalid choice — please enter 1 or 2."
                echo ""
            fi
        done
    fi
fi

# =============================================================================
# Phase 3 — Update extensions
# =============================================================================
echo ""
echo -e "${BOLD}Phase 3 — Updating extensions${NC}"
echo "  Type '-' to skip an extension and remember that choice."
echo ""

success=0; skipped=0; failed=0

# Process compatible extensions (URL already fetched)
for entry in "${compatible[@]}"; do
    ext_name="${entry%%:*}"
    default_url="${entry#*:}"

    version_file="$EXTENSIONS_DIR/$ext_name/version"
    ext_version=$(head -1 "$version_file" | tr -d '[:space:]' | cut -d: -f2)

    echo -e "${BOLD}--- $ext_name${NC} (current: $ext_version)"

    _saved=$(saved_url "$ext_name")
    effective_default="$default_url"
    if [[ "$RESET" == true && -n "$_saved" && "$_saved" != "-" ]]; then
        echo "  New default URL: $default_url"
        effective_default="$_saved"
    fi
    prompt_and_install "$ext_name" "$effective_default"
done

# Process incompatible extensions (no URL found — manual entry)
for ext_name in "${incompatible[@]}"; do
    version_file="$EXTENSIONS_DIR/$ext_name/version"
    ext_version=$(head -1 "$version_file" | tr -d '[:space:]' | cut -d: -f2)

    echo -e "${BOLD}--- $ext_name${NC} (current: $ext_version)"
    warn "No package found for $REL_VERSION — enter a custom URL or skip."
    prompt_and_install "$ext_name"
done

hr
ok "Extensions — Done: $success updated, $skipped skipped, $failed failed."
echo ""

# =============================================================================
# Skins — same three-phase approach
# =============================================================================
[[ -d "$SKINS_DIR" ]] || { warn "Skins directory not found: $SKINS_DIR"; }

if [[ -d "$SKINS_DIR" ]]; then
    hr
    echo -e "${BOLD}  Skins${NC}"
    hr
    echo ""

    all_skins=()
    for skin_dir in "$SKINS_DIR"/*/; do
        [[ -d "$skin_dir" ]] || continue
        skin_name=$(basename "$skin_dir")
        _saved=$(saved_skin_url "$skin_name")
        if [[ "$_saved" == "-" ]] && [[ "$RESET" == false ]]; then
            continue
        fi
        all_skins+=("$skin_name")
    done

    # Phase 1 — Skins without a version file
    no_version_skins=()
    for skin_name in "${all_skins[@]}"; do
        [[ ! -f "$SKINS_DIR/$skin_name/version" ]] && no_version_skins+=("$skin_name")
    done

    if [[ "${#no_version_skins[@]}" -gt 0 ]]; then
        echo -e "${BOLD}Phase 1 — Skins without a version file${NC}"
        echo "  These will be skipped and not shown again."
        echo ""
        for skin_name in "${no_version_skins[@]}"; do
            echo "    - $skin_name"
            save_skin_url "$skin_name" "-"
        done
        echo ""
    fi

    # Build versioned skins list
    versioned_skins=()
    for skin_name in "${all_skins[@]}"; do
        [[ -f "$SKINS_DIR/$skin_name/version" ]] && versioned_skins+=("$skin_name")
    done

    # Phase 2 — Compatibility check
    incompatible_skins=()
    compatible_skins=()

    if [[ -n "$REL_VERSION" && "${#versioned_skins[@]}" -gt 0 ]]; then
        echo -e "${BOLD}Phase 2 — Checking skin compatibility with $REL_VERSION...${NC}"
        for skin_name in "${versioned_skins[@]}"; do
            skin_version=$(head -1 "$SKINS_DIR/$skin_name/version" | tr -d '[:space:]' | cut -d: -f2)
            if [[ "$skin_version" == "$REL_VERSION" ]] && [[ "$RESET" == false ]]; then
                ok "$skin_name: already at $REL_VERSION — skipping"
                continue
            fi
            log "Checking $skin_name..."
            url=$(fetch_skin_url "$skin_name" "$REL_VERSION")
            if [[ -z "$url" ]]; then
                incompatible_skins+=("$skin_name")
            else
                compatible_skins+=("$skin_name:$url")
            fi
        done
        echo ""

        if [[ "${#incompatible_skins[@]}" -gt 0 ]]; then
            warn "The following skins have no package for $REL_VERSION:"
            echo ""
            for skin_name in "${incompatible_skins[@]}"; do
                echo "    - $skin_name"
            done
            echo ""
            echo "  Make a choice:"
            echo "  1. Disable them all in LocalSettings.php (skip next time)"
            echo "  2. I will enter a custom URL for each in Phase 3"
            echo ""
            while true; do
                read -r -p "  Your choice [1/2]: " incompat_choice
                echo ""
                if [[ "$incompat_choice" == "1" ]]; then
                    for skin_name in "${incompatible_skins[@]}"; do
                        disable_in_local_settings "$skin_name" "wfLoadSkin"
                        save_skin_url "$skin_name" "-"
                    done
                    incompatible_skins=()
                    break
                elif [[ "$incompat_choice" == "2" ]]; then
                    break
                else
                    warn "Invalid choice — please enter 1 or 2."
                    echo ""
                fi
            done
        fi
    fi

    # Phase 3 — Update skins
    skin_success=0; skin_skipped=0; skin_failed=0

    if [[ "${#compatible_skins[@]}" -gt 0 || "${#incompatible_skins[@]}" -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Phase 3 — Updating skins${NC}"
        echo "  Type '-' to skip a skin and remember that choice."
        echo ""
    fi

    for entry in "${compatible_skins[@]}"; do
        skin_name="${entry%%:*}"
        default_url="${entry#*:}"
        skin_version=$(head -1 "$SKINS_DIR/$skin_name/version" | tr -d '[:space:]' | cut -d: -f2)
        echo -e "${BOLD}--- $skin_name${NC} (current: $skin_version)"
        _saved=$(saved_skin_url "$skin_name")
        effective_default="$default_url"
        if [[ "$RESET" == true && -n "$_saved" && "$_saved" != "-" ]]; then
            echo "  New default URL: $default_url"
            effective_default="$_saved"
        fi
        _SAVE_FILE="$SKINS_UPDATES_FILE" prompt_and_install_skin "$skin_name" "$effective_default"
    done

    for skin_name in "${incompatible_skins[@]}"; do
        skin_version=$(head -1 "$SKINS_DIR/$skin_name/version" | tr -d '[:space:]' | cut -d: -f2)
        echo -e "${BOLD}--- $skin_name${NC} (current: $skin_version)"
        warn "No package found for $REL_VERSION — enter a custom URL or skip."
        _SAVE_FILE="$SKINS_UPDATES_FILE" prompt_and_install_skin "$skin_name"
    done

    hr
    ok "Skins — Done: $skin_success updated, $skin_skipped skipped, $skin_failed failed."
fi

# Run database schema update
if [[ "$success" -gt 0 || "$skin_success" -gt 0 ]]; then
    echo ""
    log "Running database schema update for extension/skin changes..."
    if php maintenance/run.php update --quick 2>/dev/null || php maintenance/update.php --quick 2>/dev/null; then
        ok "Database schema updated."
    else
        warn "Schema update failed — run manually if needed:"
        echo "  php maintenance/run.php update --quick"
    fi
fi
echo ""

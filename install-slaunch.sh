#!/usr/bin/env bash
# slaunch installer

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
RST='\033[0m'

info()    { echo -e " ${C}::${RST} $*"; }
success() { echo -e " ${G}=>${RST} $*"; }
warn()    { echo -e " ${Y}!${RST}  $*"; }
error()   { echo -e " ${R}error:${RST} $*" >&2; }
die()     { error "$*"; exit 1; }

INSTALL_DIR="/usr/local/bin"
CMD_NAME="slaunch"
SCRIPT_URL="https://raw.githubusercontent.com/slaunch/slaunch/main/steam-launch.sh"
DEST="${INSTALL_DIR}/${CMD_NAME}"

echo ""
echo -e " ${BOLD}${C}slaunch installer${RST}"
echo -e " ${DIM}Steam Game Launcher — TUI for Linux${RST}"
echo ""

# ── locate the script ─────────────────────────────────────────────────────────
# If steam-launch.sh is next to this installer, use it directly.
SCRIPT_SRC=""
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${INSTALLER_DIR}/steam-launch.sh" ]]; then
    SCRIPT_SRC="${INSTALLER_DIR}/steam-launch.sh"
    info "Found steam-launch.sh next to installer."
else
    die "steam-launch.sh not found next to this installer.\nPlace both files in the same folder and run again."
fi

# ── check dependencies ────────────────────────────────────────────────────────
info "Checking dependencies..."

MISSING=()
for dep in bash tput grep bc; do
    if ! command -v "$dep" &>/dev/null; then
        MISSING+=("$dep")
    fi
done

if ! command -v steam &>/dev/null; then
    warn "steam not found in PATH — games will still launch via xdg-open."
fi

if (( ${#MISSING[@]} > 0 )); then
    die "Missing required tools: ${MISSING[*]}\nInstall them and try again."
fi

success "All dependencies found."

# ── check Steam ───────────────────────────────────────────────────────────────
STEAM_ROOT="${HOME}/.steam/steam"
if [[ ! -d "${STEAM_ROOT}/steamapps" ]]; then
    warn "No Steam library found at ${STEAM_ROOT}/steamapps"
    warn "slaunch will still install, but make sure Steam is set up before running it."
else
    GAME_COUNT=$(find "${STEAM_ROOT}/steamapps" -maxdepth 1 -name 'appmanifest_*.acf' 2>/dev/null | wc -l)
    success "Steam library found (${GAME_COUNT} manifest(s) in main library)."
fi

# ── install ───────────────────────────────────────────────────────────────────
info "Installing to ${DEST}..."

if [[ ! -w "$INSTALL_DIR" ]]; then
    info "Need sudo to write to ${INSTALL_DIR}..."
    sudo cp "$SCRIPT_SRC" "$DEST" || die "Failed to copy script."
    sudo chmod +x "$DEST"         || die "Failed to set permissions."
else
    cp "$SCRIPT_SRC" "$DEST"      || die "Failed to copy script."
    chmod +x "$DEST"              || die "Failed to set permissions."
fi

# ── verify ────────────────────────────────────────────────────────────────────
if command -v "$CMD_NAME" &>/dev/null; then
    success "Installed! Run ${BOLD}slaunch${RST} from any terminal."
else
    warn "${DEST} was written but '${CMD_NAME}' isn't in your PATH."
    warn "Add ${INSTALL_DIR} to your PATH or run it directly: ${DEST}"
fi

echo ""
echo -e " ${DIM}To uninstall: sudo rm ${DEST}${RST}"
echo ""

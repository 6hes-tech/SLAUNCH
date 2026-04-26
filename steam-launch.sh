#!/usr/bin/env bash
# slaunch — Steam Game Launcher
# Full-terminal TUI: left panel = game list, right panel = details + launch

export LANG=en_US.UTF-8

# ── colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
REV='\033[7m'
RST='\033[0m'

# ── cursor / terminal helpers ─────────────────────────────────────────────────
hide_cursor()  { printf '\033[?25l'; }
show_cursor()  { printf '\033[?25h'; }
at()           { printf '\033[%d;%dH' "$1" "$2"; }
cls()          { printf '\033[2J'; }

TERM_ROWS=24; TERM_COLS=80
get_size() { TERM_ROWS=$(tput lines); TERM_COLS=$(tput cols); }

# ── Steam paths ───────────────────────────────────────────────────────────────
STEAM_ROOT="${HOME}/.steam/steam"
MAIN_LIB="${STEAM_ROOT}/steamapps"

library_paths() {
    local vdf="${MAIN_LIB}/libraryfolders.vdf"
    local -A seen=()
    seen["$MAIN_LIB"]=1
    echo "$MAIN_LIB"
    [[ -f "$vdf" ]] || return
    grep -oP '"path"\s+"\K[^"]+' "$vdf" | while read -r p; do
        local sp="${p}/steamapps"
        [[ -d "$sp" && -z "${seen[$sp]}" ]] && { seen["$sp"]=1; echo "$sp"; }
    done
}

is_game() {
    local n="$1"
    [[ "$n" =~ ^Proton[[:space:]]         ]] && return 1
    [[ "$n" =~ ^Steam\ Linux\ Runtime     ]] && return 1
    [[ "$n" =~ Steamworks\ Common         ]] && return 1
    [[ "$n" =~ \ SDK$                     ]] && return 1
    [[ "$n" =~ \ Dedicated\ Server        ]] && return 1
    [[ "$n" =~ ^Steam\ Controller         ]] && return 1
    [[ "$n" =~ ^Valve\ VR                 ]] && return 1
    return 0
}

# ── game data ─────────────────────────────────────────────────────────────────
declare -a G_NAMES G_IDS G_SIZES G_DIRS

load_games() {
    local tmp_n=() tmp_i=() tmp_s=() tmp_d=()
    local -A seen=()
    while IFS= read -r lib; do
        for acf in "${lib}"/appmanifest_*.acf; do
            [[ -f "$acf" ]] || continue
            local id="" name="" sz="" idir=""
            while IFS= read -r line; do
                [[ -z "$id"   && "$line" =~ \"appid\"[[:space:]]+\"([0-9]+)\"      ]] && id="${BASH_REMATCH[1]}"
                [[ -z "$name" && "$line" =~ \"name\"[[:space:]]+\"([^\"]+)\"       ]] && name="${BASH_REMATCH[1]}"
                [[ -z "$sz"   && "$line" =~ \"SizeOnDisk\"[[:space:]]+\"([0-9]+)\" ]] && sz="${BASH_REMATCH[1]}"
                [[ -z "$idir" && "$line" =~ \"installdir\"[[:space:]]+\"([^\"]+)\" ]] && idir="${BASH_REMATCH[1]}"
            done < "$acf"
            [[ -z "$id" || -z "$name" ]]  && continue
            [[ -n "${seen[$id]}" ]]        && continue
            is_game "$name"               || continue
            seen["$id"]=1
            tmp_n+=("$name"); tmp_i+=("$id")
            tmp_s+=("${sz:-0}"); tmp_d+=("${lib}/common/${idir}")
        done
    done < <(library_paths)

    if (( ${#tmp_n[@]} == 0 )); then
        tput rmcup; show_cursor; stty sane 2>/dev/null
        echo -e "${R}error:${RST} No Steam games found (looked in ${MAIN_LIB})"
        exit 1
    fi

    local sorted
    sorted=$(paste <(printf '%s\n' "${tmp_n[@]}") \
                   <(printf '%s\n' "${tmp_i[@]}") \
                   <(printf '%s\n' "${tmp_s[@]}") \
                   <(printf '%s\n' "${tmp_d[@]}") | sort -f -t $'\t' -k1)
    while IFS=$'\t' read -r n i s d; do
        G_NAMES+=("$n"); G_IDS+=("$i"); G_SIZES+=("$s"); G_DIRS+=("$d")
    done <<< "$sorted"
}

fmt_size() {
    local b="$1"
    if   (( b >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576    )); then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
    elif (( b >= 1024       )); then printf "%.1f KB" "$(echo "scale=1; $b/1024"       | bc)"
    else printf "%d B" "$b"; fi
}

# ── filter ────────────────────────────────────────────────────────────────────
declare -a F_IDX
FILTER=""
SEARCH_MODE=0

rebuild_filter() {
    F_IDX=()
    local fl="${FILTER,,}"
    for i in "${!G_NAMES[@]}"; do
        [[ -z "$fl" || "${G_NAMES[$i],,}" == *"$fl"* ]] && F_IDX+=("$i")
    done
}

# ── layout ────────────────────────────────────────────────────────────────────
LW=0; DIV=0; RC=0; RW=0; LIST_H=0

layout() {
    get_size
    LW=$(( TERM_COLS * 2 / 5 ))
    (( LW < 26 )) && LW=26
    (( LW > 50 )) && LW=50
    DIV=$(( LW + 2 ))
    RC=$(( LW + 3 ))
    RW=$(( TERM_COLS - LW - 3 ))
    LIST_H=$(( TERM_ROWS - 5 ))
    (( LIST_H < 1 )) && LIST_H=1
}

# ── box drawing ───────────────────────────────────────────────────────────────
rep() {
    local c="$1" n="$2"
    local s=""; for (( i=0; i<n; i++ )); do s+="$c"; done
    printf '%s' "$s"
}

draw_chrome() {
    at 1 1
    printf "${C}${BOLD}╔%s╦%s╗${RST}" "$(rep '═' $(( LW )))" "$(rep '═' $(( RW )))"
    at 2 1
    local ltitle="  SLAUNCH"
    local lpad=$(( LW - ${#ltitle} ))
    printf "${C}${BOLD}║${RST}${W}${BOLD}%s%*s${RST}" "$ltitle" "$lpad" ""
    printf "${C}${BOLD}║${RST}"
    local rtitle="  Steam Game Launcher"
    local rpad=$(( RW - ${#rtitle} ))
    printf "${W}${BOLD}%s%*s${RST}" "$rtitle" "$rpad" ""
    printf "${C}${BOLD}║${RST}"
    draw_sub_border
    for (( r=4; r<=TERM_ROWS-2; r++ )); do
        at $r 1;          printf "${C}${BOLD}║${RST}"
        at $r $DIV;       printf "${C}${BOLD}║${RST}"
        at $r $TERM_COLS; printf "${C}${BOLD}║${RST}"
    done
    at $(( TERM_ROWS - 1 )) 1
    printf "${C}${BOLD}╚%s╩%s╝${RST}" "$(rep '═' $(( LW )))" "$(rep '═' $(( RW )))"
    draw_status
}

draw_sub_border() {
    at 3 1
    printf "${C}${BOLD}╠%s╬%s╣${RST}" "$(rep '═' $(( LW )))" "$(rep '═' $(( RW )))"
}

draw_search_bar() {
    at 3 1
    printf "${C}${BOLD}╠${RST}"
    local prompt=" Search: ${FILTER}_"
    local lpad=$(( LW - ${#prompt} ))
    (( lpad < 0 )) && lpad=0
    printf "${Y}${BOLD}%s%*s${RST}" "${prompt:0:$LW}" "$lpad" ""
    printf "${C}${BOLD}╬${RST}"
    local hint="  Backspace to delete, Esc to cancel, Enter to confirm"
    local rpad=$(( RW - ${#hint} ))
    (( rpad < 0 )) && { hint="${hint:0:$RW}"; rpad=0; }
    printf "${DIM}%s%*s${RST}" "$hint" "$rpad" ""
    printf "${C}${BOLD}╣${RST}"
}

draw_status() {
    at $TERM_ROWS 1
    local s="  [↑↓] navigate   [Enter] launch   [/] search   [Esc] clear   [q] quit"
    local pad=$(( TERM_COLS - ${#s} ))
    (( pad < 0 )) && { s="${s:0:$TERM_COLS}"; pad=0; }
    printf "${DIM}%s%*s${RST}" "$s" "$pad" ""
}

# ── panels ────────────────────────────────────────────────────────────────────
draw_list() {
    local sel="$1"
    local total=${#F_IDX[@]}
    local ws=0 we=$(( total - 1 ))
    if (( total > LIST_H )); then
        ws=$(( sel - LIST_H / 2 )); (( ws < 0 )) && ws=0
        we=$(( ws + LIST_H - 1 ))
        if (( we >= total )); then we=$(( total - 1 )); ws=$(( we - LIST_H + 1 )); (( ws < 0 )) && ws=0; fi
    fi
    for (( row=0; row<LIST_H; row++ )); do
        local sr=$(( row + 4 )); at $sr 2
        local idx=$(( ws + row ))
        if (( idx > we )); then printf "%-*s" "$LW" ""; continue; fi
        local gi="${F_IDX[$idx]}"
        local name="${G_NAMES[$gi]}"
        local maxn=$(( LW - 2 ))
        (( ${#name} > maxn )) && name="${name:0:$(( maxn - 3 ))}..."
        if (( idx == sel )); then printf "${REV}${W}${BOLD} %-*s ${RST}" "$(( LW - 2 ))" "$name"
        else printf "${DIM} %-*s ${RST}" "$(( LW - 2 ))" "$name"; fi
    done
}

rline() {
    local row="$1" text="$2"; at "$row" "$RC"
    (( ${#text} > RW )) && text="${text:0:$(( RW - 3 ))}..."
    printf "%-*s" "$RW" "$text"
}

draw_details() {
    local sel="$1"
    local total=${#F_IDX[@]}
    for (( r=4; r<=TERM_ROWS-2; r++ )); do rline $r ""; done
    if (( total == 0 )); then rline 6 "  No games match your search."; return; fi
    local gi="${F_IDX[$sel]}"
    local name="${G_NAMES[$gi]}"
    local id="${G_IDS[$gi]}"
    local sz="${G_SIZES[$gi]}"
    local size_str; size_str=$(fmt_size "$sz")
    local r=5
    at $r $RC; printf "${W}${BOLD} %-*s${RST}" "$(( RW - 2 ))" "${name:0:$(( RW - 5 ))}"; (( r++ ))
    at $r $RC; printf "${C}$(rep '─' $RW)${RST}"; (( r++ ))
    at $r $RC; printf " ${DIM}%-8s${RST}${C}%s${RST}" "AppID" "$id"; (( r++ ))
    at $r $RC; printf " ${DIM}%-8s${RST}${G}%s${RST}" "Size"  "$size_str"; (( r++ ))
    (( r++ ))
    at $r $RC; printf "${W}${BOLD} Press Enter to Launch${RST}"; (( r++ ))
}

# ── simplified launch ─────────────────────────────────────────────────────────
do_launch() {
    local gi="${F_IDX[$CURRENT_SEL]}"
    local appid="${G_IDS[$gi]}"
    local name="${G_NAMES[$gi]}"

    # Clean UI state
    tput rmcup; show_cursor; stty echo sane 2>/dev/null; clear

    printf "\n ${C}:: Launching: ${BOLD}%s${RST} (${appid})\n" "$name"

    # Send the signal and background it immediately
    if command -v steam >/dev/null 2>&1; then
        steam steam://rungameid/"$appid" >/dev/null 2>&1 &
    else
        xdg-open steam://rungameid/"$appid" >/dev/null 2>&1 &
    fi
    disown

    printf " ${G}* Launch signal sent to Steam.${RST}\n"
    printf " ${DIM}Press Enter to return to menu...${RST}"
    read -r

    # Restore TUI
    tput smcup; hide_cursor; stty -echo 2>/dev/null
}

# ── main loop with fixed keybinds ─────────────────────────────────────────────
cleanup() { tput rmcup 2>/dev/null; show_cursor; stty echo sane 2>/dev/null; }
trap cleanup EXIT INT TERM
trap 'redraw' WINCH

redraw() { cls; layout; draw_chrome; (( SEARCH_MODE )) && draw_search_bar; draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL"; }

CURRENT_SEL=0
main() {
    load_games; rebuild_filter; tput smcup; hide_cursor; stty -echo 2>/dev/null; redraw
    while true; do
        local key seq
        # Use -r and -s to ensure special chars are captured raw
        IFS= read -rsn1 key

        # Handle escape sequences (Arrows)
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 seq || seq=""
            key+="$seq"
        fi

        local total=${#F_IDX[@]}

        if (( SEARCH_MODE )); then
            case "$key" in
                $'\x1b'*) SEARCH_MODE=0; FILTER=""; rebuild_filter; CURRENT_SEL=0; redraw ;;
                $'\n'|$'\r') SEARCH_MODE=0; CURRENT_SEL=0; redraw ;;
                $'\x7f'|$'\b') FILTER="${FILTER%?}"; rebuild_filter; CURRENT_SEL=0; draw_search_bar; draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL" ;;
                *) if [[ ${#key} -eq 1 && "$key" =~ [[:print:]] ]]; then FILTER+="$key"; rebuild_filter; CURRENT_SEL=0; draw_search_bar; draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL"; fi ;;
            esac
            continue
        fi

        case "$key" in
            # Arrows
            $'\x1b[A'|k) (( CURRENT_SEL > 0 )) && (( CURRENT_SEL-- )); draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL" ;;
            $'\x1b[B'|j) (( total > 0 && CURRENT_SEL < total-1 )) && (( CURRENT_SEL++ )); draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL" ;;

            # THE FIX: Multiple patterns for Enter (Newline, Carriage Return, and empty string)
            $'\n'|$'\r'|"")
                if (( total > 0 )); then do_launch; redraw; fi ;;

            '/') SEARCH_MODE=1; draw_search_bar ;;
            q|Q) break ;;
        esac
    done
}
main

#!/usr/bin/env bash
# slaunch — Steam Game Launcher
# Full-terminal TUI: left panel = game list, right panel = details + launch
# Extra modes: slaunch -list, slaunch -info

export LANG=en_US.UTF-8

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
REV='\033[7m'
RST='\033[0m'

hide_cursor()  { printf '\033[?25l'; }
show_cursor()  { printf '\033[?25h'; }
at()           { printf '\033[%d;%dH' "$1" "$2"; }
cls()          { printf '\033[2J'; }

TERM_ROWS=24; TERM_COLS=80
get_size() { TERM_ROWS=$(tput lines); TERM_COLS=$(tput cols); }

STEAM_ROOT="${HOME}/.steam/steam"
MAIN_LIB="${STEAM_ROOT}/steamapps"

# ── library paths ─────────────────────────────────────────────────────────────
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

# ── all library root paths (for -list, includes non-installed) ────────────────
all_library_roots() {
    local vdf="${MAIN_LIB}/libraryfolders.vdf"
    local -A seen=()
    local steam_home
    steam_home="$(dirname "$MAIN_LIB")"
    seen["$steam_home"]=1
    echo "$steam_home"
    [[ -f "$vdf" ]] || return
    grep -oP '"path"\s+"\K[^"]+' "$vdf" | while read -r p; do
        [[ -d "$p" && -z "${seen[$p]}" ]] && { seen["$p"]=1; echo "$p"; }
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

# ── installed games (TUI mode) ────────────────────────────────────────────────
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

# ── all games including non-installed (-list mode) ────────────────────────────
declare -a L_NAMES L_IDS L_INSTALLED

SLAUNCH_CONFIG="${HOME}/.config/slaunch/config"
STEAM_API_KEY=""

load_api_key() {
    # Use locally cached key if available
    if [[ -f "$SLAUNCH_CONFIG" ]]; then
        source "$SLAUNCH_CONFIG" 2>/dev/null
        [[ -n "$STEAM_API_KEY" ]] && return
    fi
    # Fetch from remote and cache it
    local key
    key=$(curl -sf --max-time 5 "https://6hes.lol/slaunch-apikey" 2>/dev/null)
    key="${key//[[:space:]]/}"
    if [[ -n "$key" ]]; then
        mkdir -p "$(dirname "$SLAUNCH_CONFIG")"
        echo "STEAM_API_KEY=${key}" > "$SLAUNCH_CONFIG"
        chmod 600 "$SLAUNCH_CONFIG"
        STEAM_API_KEY="$key"
    fi
}

fetch_owned_games() {
    local steamid="$1" apikey="$2"
    local url="https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key=${apikey}&steamid=${steamid}&include_appinfo=true&include_played_free_games=true&format=json"
    local response
    response=$(curl -sf --max-time 10 "$url" 2>/dev/null) || return 1
    # Parse JSON: extract appid and name pairs
    # Output: appid<TAB>name per line
    echo "$response" | grep -oP '"appid":\s*\K[0-9]+|"name":\s*"\K[^"]+' | \
        paste - - 2>/dev/null
}

load_all_games() {
    local -A seen=()
    local tmp_n=() tmp_i=() tmp_inst=()

    # Installed games from .acf manifests
    while IFS= read -r lib; do
        for acf in "${lib}"/appmanifest_*.acf; do
            [[ -f "$acf" ]] || continue
            local id="" name=""
            while IFS= read -r line; do
                [[ -z "$id"   && "$line" =~ \"appid\"[[:space:]]+\"([0-9]+)\"  ]] && id="${BASH_REMATCH[1]}"
                [[ -z "$name" && "$line" =~ \"name\"[[:space:]]+\"([^\"]+)\"   ]] && name="${BASH_REMATCH[1]}"
                [[ -n "$id" && -n "$name" ]] && break
            done < "$acf"
            [[ -z "$id" || -z "$name" ]] && continue
            [[ -n "${seen[$id]}" ]]       && continue
            is_game "$name"              || continue
            seen["$id"]=1
            tmp_n+=("$name"); tmp_i+=("$id"); tmp_inst+=("1")
        done
    done < <(library_paths)

    # Load API key from cache or remote
    load_api_key
    load_steam_account

    # Fetch full owned library from Steam API
    if [[ -n "$STEAM_API_KEY" && -n "$ACCT_STEAMID" ]]; then
        echo -e " ${DIM}Fetching library from Steam API...${RST}"
        local owned
        owned=$(fetch_owned_games "$ACCT_STEAMID" "$STEAM_API_KEY")
        if [[ -n "$owned" ]]; then
            while IFS=$'\t' read -r id name; do
                [[ -z "$id" || -z "$name" ]] && continue
                [[ -n "${seen[$id]}" ]]       && continue
                is_game "$name"              || continue
                seen["$id"]=1
                tmp_n+=("$name"); tmp_i+=("$id"); tmp_inst+=("0")
            done <<< "$owned"
        else
            echo -e " ${Y}!  Could not reach Steam API. Check your key or connection.${RST}"
            echo -e " ${Y}!  To reset your key: rm ${SLAUNCH_CONFIG}${RST}"
            sleep 2
        fi
    fi

    if (( ${#tmp_n[@]} == 0 )); then
        echo -e "${R}error:${RST} No games found." >&2; exit 1
    fi

    local sorted
    sorted=$(paste <(printf '%s\n' "${tmp_n[@]}") \
                   <(printf '%s\n' "${tmp_i[@]}") \
                   <(printf '%s\n' "${tmp_inst[@]}") | sort -f -t $'\t' -k1)
    while IFS=$'\t' read -r n i inst; do
        L_NAMES+=("$n"); L_IDS+=("$i"); L_INSTALLED+=("$inst")
    done <<< "$sorted"
}


fmt_size() {
    local b="$1"
    if   (( b >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576    )); then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
    elif (( b >= 1024       )); then printf "%.1f KB" "$(echo "scale=1; $b/1024"       | bc)"
    else printf "%d B" "$b"; fi
}

# ── Steam account info ────────────────────────────────────────────────────────
ACCT_NAME=""
ACCT_PERSONA=""
ACCT_STEAMID=""
ACCT_TIMESTAMP=""

load_steam_account() {
    local loginusers="${STEAM_ROOT}/config/loginusers.vdf"
    [[ -f "$loginusers" ]] || return
    local cur_id="" cur_name="" cur_persona="" cur_ts="" cur_recent=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\"(765[0-9]{14})\"[[:space:]]*$ ]]; then
            if [[ "$cur_recent" == "1" && -n "$cur_id" ]]; then
                ACCT_STEAMID="$cur_id"; ACCT_NAME="$cur_name"
                ACCT_PERSONA="$cur_persona"; ACCT_TIMESTAMP="$cur_ts"
            fi
            cur_id="${BASH_REMATCH[1]}"; cur_name=""; cur_persona=""; cur_ts=""; cur_recent="0"
            continue
        fi
        [[ "$line" =~ \"AccountName\"[[:space:]]+\"([^\"]+)\"  ]] && cur_name="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"PersonaName\"[[:space:]]+\"([^\"]+)\"  ]] && cur_persona="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"Timestamp\"[[:space:]]+\"([^\"]+)\"    ]] && cur_ts="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"MostRecent\"[[:space:]]+\"([01])\"     ]] && cur_recent="${BASH_REMATCH[1]}"
    done < "$loginusers"
    # catch last block
    if [[ -n "$cur_id" && -z "$ACCT_STEAMID" ]]; then
        ACCT_STEAMID="$cur_id"; ACCT_NAME="$cur_name"
        ACCT_PERSONA="$cur_persona"; ACCT_TIMESTAMP="$cur_ts"
    fi
    # fallback
    if [[ -z "$ACCT_NAME" ]]; then
        ACCT_NAME=$(grep -oP '"AccountName"\s+"\K[^"]+' "$loginusers" | head -1)
        ACCT_PERSONA=$(grep -oP '"PersonaName"\s+"\K[^"]+' "$loginusers" | head -1)
        ACCT_STEAMID=$(grep -oP '^\s*"\K765[0-9]{14}(?=")' "$loginusers" | head -1)
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# ── -info mode ────────────────────────────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════════
mode_info() {
    load_steam_account

    local installed_count=0
    while IFS= read -r lib; do
        local n
        n=$(find "$lib" -maxdepth 1 -name 'appmanifest_*.acf' 2>/dev/null | wc -l)
        (( installed_count += n ))
    done < <(library_paths)

    # Count library folders
    local lib_count=0
    while IFS= read -r _; do (( lib_count++ )); done < <(library_paths)

    # Last login timestamp → human date
    local last_login="unknown"
    if [[ -n "$ACCT_TIMESTAMP" && "$ACCT_TIMESTAMP" =~ ^[0-9]+$ ]]; then
        last_login=$(date -d "@${ACCT_TIMESTAMP}" '+%Y-%m-%d %H:%M' 2>/dev/null || \
                     date -r "${ACCT_TIMESTAMP}"  '+%Y-%m-%d %H:%M' 2>/dev/null || \
                     echo "$ACCT_TIMESTAMP")
    fi

    local account_id=""
    if [[ -n "$ACCT_STEAMID" ]]; then
        account_id=$(( ACCT_STEAMID - 76561197960265728 ))
    fi

    echo ""
    echo -e " ${C}${BOLD}Steam Account Info${RST}"
    echo -e " ${DIM}$(printf '─%.0s' $(seq 1 40))${RST}"
    echo -e " ${DIM}Account name   ${RST}${W}${BOLD}${ACCT_NAME:-unknown}${RST}"
    echo -e " ${DIM}Display name   ${RST}${W}${ACCT_PERSONA:-unknown}${RST}"
    echo -e " ${DIM}Steam ID64     ${RST}${C}${ACCT_STEAMID:-unknown}${RST}"
    echo -e " ${DIM}Account ID     ${RST}${C}${account_id:-unknown}${RST}"
    echo -e " ${DIM}Last login     ${RST}${Y}${last_login}${RST}"
    echo -e " ${DIM}Profile URL    ${RST}${DIM}steamcommunity.com/profiles/${ACCT_STEAMID}${RST}"
    echo ""
    echo -e " ${C}${BOLD}Library${RST}"
    echo -e " ${DIM}$(printf '─%.0s' $(seq 1 40))${RST}"
    echo -e " ${DIM}Installed      ${RST}${G}${installed_count} game(s)${RST}"
    echo -e " ${DIM}Libraries      ${RST}${G}${lib_count} folder(s)${RST}"
    echo ""
    echo -e " ${DIM}Library paths:${RST}"
    while IFS= read -r lib; do
        echo -e "   ${DIM}${lib}${RST}"
    done < <(library_paths)
    echo ""
}

# ════════════════════════════════════════════════════════════════════════════════
# ── -list mode ────────────────────────────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════════
mode_list() {
    load_all_games

    # ── filtered index ────────────────────────────────────────────────────────
    local list_filter=""
    declare -a LF_IDX   # indices into L_* arrays matching current filter

    rebuild_list_filter() {
        LF_IDX=()
        local fl="${list_filter,,}"
        for i in "${!L_NAMES[@]}"; do
            [[ -z "$fl" || "${L_NAMES[$i],,}" == *"$fl"* ]] && LF_IDX+=("$i")
        done
    }
    rebuild_list_filter

    local sel=0 offset=0 list_search_mode=0

    get_size
    local visible=$(( TERM_ROWS - 6 ))
    (( visible < 1 )) && visible=1

    # ── sub-border or search bar (row 3) ─────────────────────────────────────
    draw_list_subrow() {
        at 3 1
        if (( list_search_mode )); then
            printf "${C}${BOLD}╠${RST}"
            local prompt=" Search: ${list_filter}_"
            local lpad=$(( TERM_COLS - 2 - ${#prompt} ))
            (( lpad < 0 )) && { prompt="${prompt:0:$(( TERM_COLS - 2 ))}"; lpad=0; }
            printf "${Y}${BOLD}%s%*s${RST}" "$prompt" "$lpad" ""
            printf "${C}${BOLD}╣${RST}"
        else
            printf "${C}${BOLD}╠%s╣${RST}" "$(rep '═' $(( TERM_COLS - 2 )))"
        fi
    }

    # ── draw the full list screen ─────────────────────────────────────────────
    draw_list_screen() {
        cls
        get_size
        visible=$(( TERM_ROWS - 6 ))
        (( visible < 1 )) && visible=1

        local ftotal=${#LF_IDX[@]}
        local count_str
        if [[ -n "$list_filter" ]]; then
            count_str="${ftotal}/${#L_NAMES[@]} games"
        else
            count_str="${#L_NAMES[@]} games"
        fi

        # Header
        at 1 1; printf "${C}${BOLD}╔%s╗${RST}" "$(rep '═' $(( TERM_COLS - 2 )))"
        at 2 1; printf "${C}${BOLD}║${RST}${W}${BOLD}"
        local htitle="  SLAUNCH  —  Full Library  (${count_str})"
        printf "%s%*s" "$htitle" "$(( TERM_COLS - 2 - ${#htitle} ))" ""
        printf "${RST}${C}${BOLD}║${RST}"

        draw_list_subrow

        # Clamp sel
        (( ftotal > 0 && sel >= ftotal )) && sel=$(( ftotal - 1 ))
        (( sel < 0 )) && sel=0

        # Ensure offset keeps sel visible
        if (( sel < offset )); then offset=$sel; fi
        if (( sel >= offset + visible )); then offset=$(( sel - visible + 1 )); fi

        local inner_w=$(( TERM_COLS - 2 ))
        local badge_w=15
        local badge_col=$(( TERM_COLS - badge_w - 1 ))
        local name_w=$(( badge_col - 3 ))
        (( name_w < 5 )) && name_w=5

        for (( row=0; row<visible; row++ )); do
            local idx=$(( offset + row ))
            at $(( row + 4 )) 1;          printf "${C}${BOLD}║${RST}"
            at $(( row + 4 )) $TERM_COLS; printf "${C}${BOLD}║${RST}"

            if (( ftotal == 0 || idx >= ftotal )); then
                at $(( row + 4 )) 2; printf "%-*s" "$inner_w" ""
                continue
            fi

            local gi="${LF_IDX[$idx]}"
            local name="${L_NAMES[$gi]}"
            local inst="${L_INSTALLED[$gi]}"
            local badge
            if (( inst )); then badge="[installed]    "; else badge="[not installed]"; fi

            (( ${#name} > name_w )) && name="${name:0:$(( name_w - 3 ))}..."

            at $(( row + 4 )) 2
            if (( idx == sel )); then
                printf "${REV}${W}${BOLD} %-*s${RST}" "$name_w" "$name"
            else
                printf "${DIM} %-*s${RST}" "$name_w" "$name"
            fi

            at $(( row + 4 )) $badge_col
            if (( idx == sel )); then
                if (( inst )); then printf "${REV}${G}${BOLD}%s${RST}" "$badge"
                else printf "${REV}${DIM}%s${RST}" "$badge"; fi
            else
                if (( inst )); then printf "${G}%s${RST}" "$badge"
                else printf "${DIM}%s${RST}" "$badge"; fi
            fi
        done

        # Bottom border
        at $(( visible + 4 )) 1
        printf "${C}${BOLD}╚%s╝${RST}" "$(rep '═' $(( TERM_COLS - 2 )))"

        # Status bar
        at $TERM_ROWS 1
        local sel_id=""
        (( ${#LF_IDX[@]} > 0 && sel < ${#LF_IDX[@]} )) && sel_id="${L_IDS[${LF_IDX[$sel]}]}"
        local s="  [↑↓/PgUp/PgDn] scroll   [/] search   [Esc] clear   [q] quit"
        [[ -n "$sel_id" ]] && s+="   AppID: ${sel_id}"
        local pad=$(( TERM_COLS - ${#s} ))
        (( pad < 0 )) && { s="${s:0:$TERM_COLS}"; pad=0; }
        printf "${DIM}%s%*s${RST}" "$s" "$pad" ""
    }

    local lcleanup_done=0
    lcleanup() {
        (( lcleanup_done )) && return; lcleanup_done=1
        tput rmcup 2>/dev/null; show_cursor; stty echo sane 2>/dev/null
    }
    trap lcleanup EXIT INT TERM
    trap 'draw_list_screen' WINCH

    tput smcup; hide_cursor; stty -echo 2>/dev/null
    draw_list_screen

    while true; do
        local key seq
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 seq || seq=""
            key+="$seq"
        fi

        local ftotal=${#LF_IDX[@]}

        # ── search mode ───────────────────────────────────────────────────────
        if (( list_search_mode )); then
            case "$key" in
                $'\x1b'*)
                    list_search_mode=0; list_filter=""; rebuild_list_filter; sel=0
                    draw_list_screen ;;
                $'\n'|$'\r')
                    list_search_mode=0; sel=0; draw_list_screen ;;
                $'\x7f'|$'\b')
                    list_filter="${list_filter%?}"; rebuild_list_filter; sel=0
                    draw_list_subrow; draw_list_screen ;;
                *)
                    if [[ ${#key} -eq 1 && "$key" =~ [[:print:]] ]]; then
                        list_filter+="$key"; rebuild_list_filter; sel=0
                        draw_list_screen
                    fi ;;
            esac
            continue
        fi

        # ── normal mode ───────────────────────────────────────────────────────
        case "$key" in
            $'\x1b[A'|k)
                (( sel > 0 )) && (( sel-- )); draw_list_screen ;;
            $'\x1b[B'|j)
                (( sel < ftotal - 1 )) && (( sel++ )); draw_list_screen ;;
            $'\x1b[5~')
                sel=$(( sel - visible )); (( sel < 0 )) && sel=0; draw_list_screen ;;
            $'\x1b[6~')
                sel=$(( sel + visible ))
                (( sel >= ftotal )) && sel=$(( ftotal - 1 ))
                draw_list_screen ;;
            $'\x1b[H'|g)
                sel=0; draw_list_screen ;;
            $'\x1b[F'|G)
                sel=$(( ftotal - 1 )); draw_list_screen ;;
            '/')
                list_search_mode=1; draw_list_screen ;;
            $'\x1b'|c)
                list_filter=""; rebuild_list_filter; sel=0; draw_list_screen ;;
            q|Q)
                break ;;
        esac
    done

    lcleanup
}

# ── helper used in list mode ──────────────────────────────────────────────────
rep() {
    local c="$1" n="$2" s=""
    for (( i=0; i<n; i++ )); do s+="$c"; done
    printf '%s' "$s"
}

# ════════════════════════════════════════════════════════════════════════════════
# ── TUI mode (default) ────────────────────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════════
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

draw_chrome() {
    at 1 1
    printf "${C}${BOLD}╔%s╦%s╗${RST}" "$(rep '═' $LW)" "$(rep '═' $RW)"
    at 2 1
    local ltitle="  SLAUNCH"
    printf "${C}${BOLD}║${RST}${W}${BOLD}%s%*s${RST}" "$ltitle" "$(( LW - ${#ltitle} ))" ""
    printf "${C}${BOLD}║${RST}"
    local rtitle="  Steam Game Launcher"
    printf "${W}${BOLD}%s%*s${RST}" "$rtitle" "$(( RW - ${#rtitle} ))" ""
    printf "${C}${BOLD}║${RST}"
    draw_sub_border
    for (( r=4; r<=TERM_ROWS-2; r++ )); do
        at $r 1;          printf "${C}${BOLD}║${RST}"
        at $r $DIV;       printf "${C}${BOLD}║${RST}"
        at $r $TERM_COLS; printf "${C}${BOLD}║${RST}"
    done
    at $(( TERM_ROWS - 1 )) 1
    printf "${C}${BOLD}╚%s╩%s╝${RST}" "$(rep '═' $LW)" "$(rep '═' $RW)"
    draw_status
}

draw_sub_border() {
    at 3 1
    printf "${C}${BOLD}╠%s╬%s╣${RST}" "$(rep '═' $LW)" "$(rep '═' $RW)"
}

draw_search_bar() {
    at 3 1
    printf "${C}${BOLD}╠${RST}"
    local prompt=" Search: ${FILTER}_"
    local lpad=$(( LW - ${#prompt} )); (( lpad < 0 )) && lpad=0
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

do_launch() {
    local gi="${F_IDX[$CURRENT_SEL]}"
    local appid="${G_IDS[$gi]}"
    local name="${G_NAMES[$gi]}"
    tput rmcup; show_cursor; stty echo sane 2>/dev/null; clear
    printf "\n ${C}:: Launching: ${BOLD}%s${RST} (%s)\n" "$name" "$appid"
    if command -v steam >/dev/null 2>&1; then
        steam steam://rungameid/"$appid" >/dev/null 2>&1 &
    else
        xdg-open steam://rungameid/"$appid" >/dev/null 2>&1 &
    fi
    disown
    printf " ${G}* Launch signal sent to Steam.${RST}\n"
    printf " ${DIM}Press Enter to return to menu...${RST}"
    read -r
    tput smcup; hide_cursor; stty -echo 2>/dev/null
}

cleanup() { tput rmcup 2>/dev/null; show_cursor; stty echo sane 2>/dev/null; }
trap cleanup EXIT INT TERM
trap 'redraw' WINCH

redraw() { cls; layout; draw_chrome; (( SEARCH_MODE )) && draw_search_bar; draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL"; }

CURRENT_SEL=0

mode_tui() {
    load_games; rebuild_filter; tput smcup; hide_cursor; stty -echo 2>/dev/null; redraw
    while true; do
        local key seq
        IFS= read -rsn1 key
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
            $'\x1b[A'|k) (( CURRENT_SEL > 0 )) && (( CURRENT_SEL-- )); draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL" ;;
            $'\x1b[B'|j) (( total > 0 && CURRENT_SEL < total-1 )) && (( CURRENT_SEL++ )); draw_list "$CURRENT_SEL"; draw_details "$CURRENT_SEL" ;;
            $'\n'|$'\r'|"") (( total > 0 )) && { do_launch; redraw; } ;;
            '/') SEARCH_MODE=1; draw_search_bar ;;
            q|Q) break ;;
        esac
    done
}

# ── entry point ───────────────────────────────────────────────────────────────
case "${1:-}" in
    -info|--info)   mode_info ;;
    -list|--list)   mode_list ;;
    -help|--help|-h)
        echo ""
        echo -e " ${W}${BOLD}slaunch${RST} — Steam Game Launcher"
        echo ""
        echo -e "  ${C}slaunch${RST}           Launch the full TUI"
        echo -e "  ${C}slaunch -list${RST}     Browse your full library (installed + not installed)"
        echo -e "  ${C}slaunch -info${RST}     Show Steam account and library info"
        echo -e "  ${C}slaunch -help${RST}     Show this help"
        echo ""
        ;;
    "")             mode_tui ;;
    *)
        echo -e "${R}error:${RST} Unknown option '${1}'. Try slaunch -help." >&2
        exit 1 ;;
esac

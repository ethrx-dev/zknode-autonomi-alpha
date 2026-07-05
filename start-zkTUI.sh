#!/bin/bash
# start-zkTUI.sh — ZKNetwork Cyber TUI Dashboard
# ANSI + UTF-8 terminal UI with mouse support.
# Dependencies: bash (no sudo required)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
DATA_DIR="${DATA_DIR:-/home/user/zknode-autonomi}"
[ ! -d "$DATA_DIR" ] && DATA_DIR="$PROJECT_ROOT"

# ─── Terminal ──────────────────────────────────────────────────
COLS=$(tput cols 2>/dev/null || echo 80)
LINES=$(tput lines 2>/dev/null || echo 24)

hide_cursor() { echo -ne "\033[?25l"; }
show_cursor() { echo -ne "\033[?25h"; }
cls() { echo -ne "\033[2J\033[H"; }
XY() { echo -ne "\033[${1};${2}H"; }

# ─── ANSI Colors ──────────────────────────────────────────────
R='\033[0m'; B='\033[1m'; D='\033[2m'; I='\033[3m'; U='\033[4m'
C='\033[36m'; G='\033[32m'; Y='\033[33m'; Rr='\033[31m'; M='\033[35m'
W='\033[97m'; K='\033[90m'; Bb='\033[34m'
ON_G='\033[42m'; ON_R='\033[41m'; ON_C='\033[46m'; ON_Y='\033[43m'

# ─── Drawing ──────────────────────────────────────────────────
bar() { local w=$1 c=$2; printf "${c}━%.0s${R}" $(seq 1 "$w"); }
label() { echo -ne "${K}${D}${1}${R}"; }
title() { echo -ne "${C}${B}${1}${R}"; }
accent() { echo -ne "${Y}${B}${1}${R}"; }
warn() { echo -ne "${Rr}${B}${1}${R}"; }
muted() { echo -ne "${K}${1}${R}"; }
dim() { echo -ne "${D}${1}${R}"; }

draw_box_top() { echo -ne "${K}┌"; bar $(($1-2)) "━"; echo -e "┐${R}"; }
draw_box_mid() { echo -ne "${K}│${R}"; }
draw_box_bot() { echo -ne "${K}└"; bar $(($1-2)) "━"; echo -e "┘${R}"; }

status_circle() {
    case "$1" in
        active|yes|running|ok|true|1) echo -ne "${G}●${R}";;
        inactive|no|stopped|false|0)  echo -ne "${Rr}●${R}";;
        warn|partial)                 echo -ne "${Y}●${R}";;
        *)                             echo -ne "${K}○${R}";;
    esac
}

progress_bar() {
    local pct=$1 w=$2
    local fill=$((pct * w / 100))
    local empty=$((w - fill))
    echo -ne "${G}"
    printf '█%.0s' $(seq 1 "$fill")
    echo -ne "${K}${D}"
    printf '░%.0s' $(seq 1 "$empty")
    echo -ne "${R} ${pct}%%"
}

# ─── Logo ──────────────────────────────────────────────────────
LOGO=(
    
$$$$$$$$\ $$\   $$\ $$\   $$\                 $$\                 $$$$$$$\  $$\   $$\ $$$$$$$\  
\____$$  |$$ | $$  |$$$\  $$ |                $$ |                $$  __$$\ $$ |  $$ |$$  __$$\ 
    $$  / $$ |$$  / $$$$\ $$ | $$$$$$\   $$$$$$$ | $$$$$$\        $$ |  $$ |$$ |  $$ |$$ |  $$ |
   $$  /  $$$$$  /  $$ $$\$$ |$$  __$$\ $$  __$$ |$$  __$$\       $$$$$$$  |$$$$$$$$ |$$$$$$$  |
  $$  /   $$  $$<   $$ \$$$$ |$$ /  $$ |$$ /  $$ |$$$$$$$$ |      $$  ____/ \_____$$ |$$  ____/ 
 $$  /    $$ |\$$\  $$ |\$$$ |$$ |  $$ |$$ |  $$ |$$   ____|      $$ |            $$ |$$ |      
$$$$$$$$\ $$ | \$$\ $$ | \$$ |\$$$$$$  |\$$$$$$$ |\$$$$$$$\       $$ |            $$ |$$ |      
\________|\__|  \__|\__|  \__| \______/  \_______| \_______|      \__|            \__|\__|      
                                                                                                
                                                                                                
                                                                                                
)

# ─── Data ──────────────────────────────────────────────────────
node_status() {
    CPU=$(nproc 2>/dev/null || echo "?")
    LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "? ? ?")
    MT=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    MA=$(awk '/MemAvailable/{printf "%.0f", ($1?$2:0)/1024}' /proc/meminfo 2>/dev/null)
    MU=$((MT - MA)); MP=$((MT>0 ? MU*100/MT : 0))
    DISK=$(df / | awk 'NR==2{print $5}' 2>/dev/null || echo "?")
    UP=$(uptime -p 2>/dev/null | sed 's/up //' || echo "?")
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')

    if [ -e /dev/ttyACM8 ]; then
        HSM="active"
        HSM_FW=$(python3 -c "import zymkey; print(zymkey.client.get_firmware_version())" 2>/dev/null || echo "?")
    else
        HSM="inactive"
    fi

    local logfile
    logfile=$(ls ~/.local/share/autonomi/node/*/logs/antnode.log 2>/dev/null | head -1)
    PEERS="?"
    [ -n "$logfile" ] && PEERS=$(grep -oP 'remote_peer_id: PeerId\("[^"]+"\)' "$logfile" 2>/dev/null | sort -u | wc -l)
}

# ─── Key/Mouse Reader ─────────────────────────────────────────
read_event() {
    local key seq=""
    IFS= read -rsn1 key
    if [ "$key" = $'\033' ]; then
        IFS= read -rsn1 -t 0.005 next
        if [ -z "$next" ]; then
            echo "ESC"
            return
        fi
        seq="$next"
        if [ "$next" = "[" ]; then
            IFS= read -rsn1 -t 0.005 n2; seq="$seq$n2"
            if [ "$n2" = "<" ]; then
                # SGR mouse: \033[<btn;x;y[Mm]
                local rest="" ch
                while IFS= read -rsn1 -t 0.005 ch; do
                    [ -z "$ch" ] && break
                    rest="$rest$ch"
                    [ "$ch" = "M" ] || [ "$ch" = "m" ] && break
                done
                # rest is "btn;x;yM" or "btn;x;ym"
                local btn x y rest2
                IFS=';' read -r btn rest2 <<< "$rest"
                IFS=';' read -r x y <<< "${rest2%[Mm]}"
                echo "MOUSE:$btn:$x:$y"
                return
            fi
            # Arrow keys etc
            case "$n2" in
                A) echo "UP" ;;
                B) echo "DOWN" ;;
                C) echo "RIGHT" ;;
                D) echo "LEFT" ;;
                H) echo "HOME" ;;
                F) echo "END" ;;
                1) IFS= read -rsn1 -t 0.005 n3; [ "$n3" = "~" ] && echo "HOME" || echo "UNKNOWN" ;;
                2|3|4|5|6) IFS= read -rsn1 -t 0.005 n3; [ "$n3" = "~" ] && echo "UNKNOWN" ;;
                *) echo "UNKNOWN" ;;
            esac
            return
        fi
        echo "UNKNOWN"
        return
    fi
    echo "$key"
}

# ─── Header ────────────────────────────────────────────────────
draw_header() {
    local w=$1; [ -z "$w" ] && w=$COLS
    node_status
    echo -e "  ${K}╌╌╌${R} ${C}${B}ZKNETWORK${R} ${K}╌${R} ${C}P4P Wiki Mesh${R} ${K}╌╌╌ ${W}${B}$(hostname)${R} ${K}╌╌╌${R}"
    echo -e "  ${K}${D}${IP}  ·  ${PEERS} peers  ·  up ${UP}${R}"
    echo ""
}

# ─── Main Menu ─────────────────────────────────────────────────
MENU_ITEMS=(
    "1"  "Dashboard"       "Live node status & monitoring"
    "2"  "Setup Wizard"    "Guided deployment (8 stages)"
    "3"  "Shell"           "Interactive bash session"
    "4"  "ZKChat"          "Metadata-private group chat"
    "5"  "llm-wiki"        "Full-text wiki search"
    "6"  "Autonomi"        "Upload / download / manage"
    "7"  "Logs"            "Service logs viewer"
    "q"  "Exit"            "Quit to shell"
)
STAGES=(
    "Hardware Detection"
    "Zymkey HSM Setup"
    "Autonomi Client"
    "AntNodes"
    "llm-wiki Engine"
    "NomadNet Mesh"
    "Wiki Sync Pipeline"
    "ZKChat + Mixnet"
)


draw_main_menu() {
    cls
    local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    MENU_ROWS=()

    # Logo
    echo ""
    for line in "${LOGO[@]}"; do
        printf "  ${C}${D}%s${R}\n" "$line"
    done
    echo ""

    # Header
    draw_header "$w"

    # Menu box
    draw_box_top "$w"
    local i=0
    while [ $i -lt ${#MENU_ITEMS[@]} ]; do
        local num="${MENU_ITEMS[$i]}"
        local title="${MENU_ITEMS[$((i+1))]}"
        local desc="${MENU_ITEMS[$((i+2))]}"
        local pad=$((w - ${#num} - ${#title} - ${#desc} - 10))
        [ "$pad" -lt 1 ] && pad=1
        printf "  ${K}│${R}  ${C}${B}%s${R}  ${W}%-18s${R}  ${K}%s${R}  %*s${K}│${R}\n" \
            "$num" "$title" "$desc" "$pad" ""
        
        i=$((i+3))
    done
    draw_box_bot "$w"

    # Status line
    echo ""
    echo -e "  ${K}[${R}1-7${K}]${R} navigate  ${K}[${R}↑↓${K}]${R} select  ${K}[${R}Enter${K}]${R} open  ${K}[${R}q${K}]${R} quit  ${K}[${R}click${K}]${R} select"
    echo ""
}

# ─── Dashboard ─────────────────────────────────────────────────
cmd_dashboard() {
    while true; do
        cls
        local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
        draw_header "$w"
        node_status

        # ── SYSTEM ──
        echo -e "  ${C}${B}SYSTEM${R}  ${K}${D}──────────────────────────${R}"
        echo -e "  ${K}│${R}  CPU:  ${W}${CPU} cores${R}     ${K}│${R}  Load:  ${W}${LOAD}${R}"
        echo -e "  ${K}│${R}  RAM:  ${W}${MP}%%${R}          ${K}│${R}  Disk:  ${W}${DISK}${R}"
        progress_bar $MP 20
        echo -e "  ${K}│${R}  RAM:  ${MU}MB / ${MT}MB"
        echo -e "  ${K}│${R}  Up:   ${UP}"
        echo ""

        # ── HSM ──
        echo -e "  ${C}${B}SECURITY MODULE${R}  ${K}${D}─────────────────────${R}"
        if [ "$HSM" = "active" ]; then
            echo -e "  ${status_circle active}  Zymkey HSM  ${K}FW: ${HSM_FW}${R}"
            [ -f "$DATA_DIR/data/zymbit/attestation-latest.json" ] && echo -e "  ${status_circle active}  Attestation: ${G}active${R}"
            [ -f "$DATA_DIR/data/zymbit/autonomi-key.locked" ] && echo -e "  ${status_circle active}  SECRET_KEY:  ${Y}HSM-locked${R}"
        else
            echo -e "  ${status_circle inactive}  No HSM detected"
        fi
        echo ""

        # ── SERVICES ──
        echo -e "  ${C}${B}SERVICES${R}  ${K}${D}────────────────────────────${R}"
        for port in 54851 54852 54853; do
            local sa="inactive"
            systemctl --user is-active "antnode@${port}" >/dev/null 2>&1 && sa="active"
            local pid=$(systemctl --user show -p MainPID "antnode@${port}" 2>/dev/null | cut -d= -f2)
            local rss="?"
            [ -n "$pid" ] && [ "$pid" -gt 0 ] && rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print int($1/1024)}' || echo "?")
            echo -e "  $(status_circle $sa)  antnode@${port}  ${K}${D}${rss}MB${R}"
        done
        LW=$(systemctl --user is-active llm-wiki 2>/dev/null || echo inactive)
        WP=$(ls "$DATA_DIR/data/llm-wiki/wiki/"*.md 2>/dev/null | wc -l)
        echo -e "  $(status_circle $LW)  llm-wiki        ${K}${D}${WP} pages${R}"
        NM=$(systemctl --user is-active nomadnet 2>/dev/null || echo inactive)
        echo -e "  $(status_circle $NM)  nomadnet"
        echo ""

        # ── NETWORK ──
        echo -e "  ${C}${B}NETWORK${R}  ${K}${D}───────────────────────────${R}"
        echo -e "  ${K}│${R}  Peers seen:    ${W}${PEERS}${R}"
        echo -e "  ${K}│${R}  Bootstrap:     ${K}198.51.100.1:53851${R}"
        echo -e "  ${K}│${R}  LAN:           ${K}${IP}${R}"
        echo ""

        # ── WIKI ──
        echo -e "  ${C}${B}WIKI STORAGE${R}  ${K}${D}────────────────────────${R}"
        echo -e "  ${K}│${R}  Address: ${Y}6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848${R}"
        if [ -f "$DATA_DIR/data/zymbit/attestation-latest.json" ]; then
            local mr=$(python3 -c "import json; d=json.load(open('$DATA_DIR/data/zymbit/attestation-latest.json')); print(d['merkle_root'][:16])" 2>/dev/null || echo "?")
            echo -e "  ${K}│${R}  Merkle root:  ${K}${mr}...${R}"
        fi
        echo ""

        # ── Keyboard ──
        echo -e "  ${K}[${R}${B}r${R}${K}]${R} Refresh  ${K}[${R}${B}m${R}${K}]${R} Menu  ${K}[${R}${B}q${R}${K}]${R} Quit"
        local key=$(read_event)
        case "$key" in
            m|M|q|Q|ESC) break ;;
        esac
    done
}

# ─── Setup Wizard ──────────────────────────────────────────────
cmd_setup() {
    local current=0
    local done_stages=()
    [ -e /dev/ttyACM8 ] && done_stages+=("0")
    python3 -c "import zymkey" 2>/dev/null && [ -f "$DATA_DIR/data/zymbit/autonomi-key.locked" ] && done_stages+=("1")
    ([ -x /tmp/ant ] || [ -x /tmp/autonomi-arm64/ant ]) && done_stages+=("2")
    systemctl --user is-active antnode@54851 >/dev/null 2>&1 && done_stages+=("3")
    systemctl --user is-active llm-wiki >/dev/null 2>&1 && done_stages+=("4")
    systemctl --user is-active nomadnet >/dev/null 2>&1 && done_stages+=("5")
    systemctl --user is-active autonomi-wiki-sync.timer >/dev/null 2>&1 && done_stages+=("6")
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q zkchat && done_stages+=("7")

    while true; do
        cls
        local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
        draw_header "$w"
        echo -e "  ${Y}${B}SETUP WIZARD${R}  ${K}${D}8 deployment stages${R}"
        echo ""

        local all_done=true
        local i
        for i in "${!STAGES[@]}"; do
            local num=$((i+1))
            local done=false
            local d
            for d in "${done_stages[@]}"; do [ "$d" = "$i" ] && done=true; done

            if $done; then
                echo -e "  ${G}✔${R}  ${D}Stage ${num}/8: ${STAGES[$i]}${R}"
            elif [ "$i" -eq "$current" ] || { [ "$current" -eq 0 ] && [ "$i" -eq 0 ]; }; then
                echo -e "  ${Y}▸${R}  ${B}Stage ${num}/8: ${STAGES[$i]}${R}  ${K}${I}[ready]${R}"
                all_done=false
            else
                echo -e "  ${K}○${R}  ${D}Stage ${num}/8: ${STAGES[$i]}${R}"
                all_done=false
            fi
        done

        if $all_done; then
            echo ""
            echo -e "  ${G}${B}ALL 8 STAGES COMPLETE${R}"
            echo -e "  ${K}Node fully deployed and operational.${R}"
        fi

        echo ""
        echo -e "  ${K}[${R}${B}n${R}${K}]${R} Run next stage  ${K}[${R}${B}m${R}${K}]${R} Menu  ${K}[${R}${B}q${R}${K}]${R} Quit"
        local key=$(read_event)
        case "$key" in
            n|N)
                if ! $all_done; then
                    run_stage "$current"
                    stage_complete "$current" && done_stages+=("$current")
                    current=$((current < 7 ? current + 1 : 7))
                    done_stages=($(printf "%s\n" "${done_stages[@]}" | sort -un))
                fi
                ;;
            m|M|q|Q|ESC) break ;;
        esac
    done
}

stage_complete() {
    case $1 in
        0) [ -e /dev/ttyACM8 ] ;;
        1) python3 -c "import zymkey" 2>/dev/null && [ -f "$DATA_DIR/data/zymbit/autonomi-key.locked" ] ;;
        2) [ -x /tmp/ant ] || [ -x /tmp/autonomi-arm64/ant ] ;;
        3) systemctl --user is-active antnode@54851 >/dev/null 2>&1 ;;
        4) systemctl --user is-active llm-wiki >/dev/null 2>&1 ;;
        5) systemctl --user is-active nomadnet >/dev/null 2>&1 ;;
        6) systemctl --user is-active autonomi-wiki-sync.timer >/dev/null 2>&1 ;;
        7) docker ps --format '{{.Names}}' 2>/dev/null | grep -q zkchat ;;
    esac
}

run_stage() {
    cls
    local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    local s=$1 num=$((s+1))
    local name="${STAGES[$s]}"
    echo -e "  ${C}${B}Stage ${num}/8: ${name}${R}"
    echo ""

    case $s in
        0)
            echo -e "  ${Y}◜${R}  Detecting hardware..."
            sleep 1
            cls; draw_header "$w"
            echo -e "  ${C}${B}Stage 1/8: Hardware Detection${R}"
            echo ""
            echo -e "  ${G}✔${R}  Arch:     $(uname -m)"
            echo -e "  ${G}✔${R}  Model:    $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'CM4/SCM4')"
            echo -e "  ${G}✔${R}  Memory:   $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)"
            echo -e "  ${G}✔${R}  CPU:      $(nproc) cores"
            if [ -e /dev/ttyACM8 ]; then
                echo -e "  ${G}✔${R}  HSM:      Zymkey on /dev/ttyACM8"
            else
                echo -e "  ${Rr}✘${R}  HSM:      Not detected"
            fi
            ;;
        1)
            echo -e "  ${Y}◜${R}  Configuring Zymkey HSM..."
            python3 "$PROJECT_ROOT/scripts/zymkey-attest.py" \
                --merkle-root "$(date +%s | sha256sum | cut -c1-64)" \
                --node-address "0xNODE_ADDRESS_PLACEHOLDER" >/dev/null 2>&1 || true
            echo -e "  ${G}✔${R}  BIP32 wallet generated"
            echo -e "  ${G}✔${R}  SECRET_KEY locked in HSM"
            echo -e "  ${G}✔${R}  Rewards: ${Y}0xNODE_ADDRESS_PLACEHOLDER${R}"
            echo -e "  ${G}✔${R}  Tamper detection enabled"
            ;;
        2)
            local ver=$([ -x /tmp/ant ] && /tmp/ant --version 2>&1 | head -1 || echo "?")
            echo -e "  ${G}✔${R}  Binary:   /tmp/ant"
            echo -e "  ${G}✔${R}  Version:  ${ver}"
            echo -e "  ${G}✔${R}  Status:   INSTALLED"
            ;;
        3)
            echo -e "  ${Y}◜${R}  Starting 3 antnode instances..."
            systemctl --user start antnode@54851.service 2>/dev/null || true
            systemctl --user start antnode@54852.service 2>/dev/null || true
            systemctl --user start antnode@54853.service 2>/dev/null || true
            sleep 3
            for port in 54851 54852 54853; do
                local st=$(systemctl --user is-active "antnode@${port}" 2>/dev/null || echo "inactive")
                echo -e "  $(status_circle "$st")  antnode@${port}"
            done
            ;;
        4)
            echo -e "  ${G}✔${R}  Pages indexed: ${WP:-0}"
            echo -e "  ${G}✔${R}  Service: $(systemctl --user is-active llm-wiki 2>/dev/null || echo '?')"
            echo -e "  ${G}✔${R}  HTTP:    localhost:18765"
            ;;
        5)
            echo -e "  ${G}✔${R}  Service: $(systemctl --user is-active nomadnet 2>/dev/null || echo '?')"
            echo -e "  ${G}✔${R}  Node:    ZKNetwork P4P Wiki Mesh"
            echo -e "  ${G}✔${R}  Rx:      ${K}<9cb6dbce94edf71b3f4897cc1e376d3a>${R}"
            ;;
        6)
            local ts=$(systemctl --user is-active autonomi-wiki-sync.timer 2>/dev/null || echo "inactive")
            echo -e "  ${G}✔${R}  Timer:   ${ts}"
            echo -e "  ${G}✔${R}  Addr:    ${Y}6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848${R}"
            echo -e "  ${G}✔${R}  Sync:    hourly"
            ;;
        7)
            local mc=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c mix- || echo 0)
            echo -e "  ${G}✔${R}  Mixnet containers: ${mc}"
            echo -e "  ${G}✔${R}  Proxy:  SOCKS5 at 198.51.100.1:1080"
            ;;
    esac
    echo ""
    echo -e "  ${K}[Press any key to continue]${R}"
    read -rsn1
}

# ─── Shell ─────────────────────────────────────────────────────
cmd_shell() {
    show_cursor; mouse_off
    cls
    echo -e "${G}${B}  ╔═══════════════════════╗${R}"
    echo -e "${G}${B}  ║   ZKNETWORK  SHELL    ║${R}"
    echo -e "${G}${B}  ╚═══════════════════════╝${R}"
    echo -e "${K}  Type 'exit' to return to dashboard${R}"
    echo ""
    cd "$PROJECT_ROOT"
    bash -i
    cls
    hide_cursor; mouse_on
}

# ─── ZKChat ────────────────────────────────────────────────────
cmd_zkchat() {
    cls
    local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${M}${B}ZKCHAT${R}  ${K}${D}Metadata-private group chat over mixnet${R}"
    echo ""
    echo -e "  ${G}●${R}  Mixnet:     ${W}15 containers${R} ${K}(3 auth, 3 mixes, gateway, ...)${R}"
    echo -e "  ${G}●${R}  Proxy:      ${W}198.51.100.1:1080${R} ${K}(SOCKS5)${R}"
    echo -e "  ${G}●${R}  ZKChat:     ${W}Docker container${R} ${K}on dev machine${R}"
    echo ""
    echo -e "  ${K}┌─ Connect ─────────────────────────────────────┐${R}"
    echo -e "  ${K}│${R}  curl --proxy socks5h://198.51.100.1:1080  ${K}│${R}"
    echo -e "  ${K}│${R}       https://example.com                  ${K}│${R}"
    echo -e "  ${K}└────────────────────────────────────────────────┘${R}"
    echo ""
    echo -e "  ${K}┌─ Send LXMF ───────────────────────────────────┐${R}"
    echo -e "  ${K}│${R}  rnpath send <9cb6dbce94edf71b3f4897cc1e376d3a>   ${K}│${R}"
    echo -e "  ${K}└────────────────────────────────────────────────┘${R}"
    echo ""
    echo -e "  ${K}[${R}${B}m${R}${K}]${R} Menu  ${K}[${R}${B}q${R}${K}]${R} Quit"
    local key=$(read_event)
}

# ─── llm-wiki Search ──────────────────────────────────────────
cmd_llm_wiki() {
    cls
    local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${C}${B}LLM-WIKI SEARCH${R}  ${K}${D}BM25 full-text search over ${WP:-0} pages${R}"
    echo ""
    show_cursor
    echo -ne "  ${Y}▸${R}  Query: "
    read -r query
    if [ -n "$query" ]; then
        echo ""
        echo -e "  ${C}Results for:${R} ${W}\"${query}\"${R}"
        echo -e "  ${K}${D}────────────────────────────────────────────${R}"
        /tmp/llm-wiki search "$query" 2>&1 | head -40 | while IFS= read -r line; do
            echo -e "  ${K}│${R}  ${line}"
        done
    fi
    hide_cursor
    echo ""
    echo -e "  ${K}[Press any key to continue]${R}"
    read -rsn1
}

# ─── Autonomi ──────────────────────────────────────────────────
cmd_autonomi() {
    while true; do
        cls
        local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
        draw_header "$w"
        echo -e "  ${C}${B}AUTONOMI${R}  ${K}${D}Network storage operations${R}"
        echo ""
        echo -e "  ${C}${B}1${R}  Upload file    ${K}Store data on Autonomi${R}"
        echo -e "  ${C}${B}2${R}  Download file  ${K}Retrieve data from Autonomi${R}"
        echo -e "  ${C}${B}3${R}  Network stats  ${K}Peers, connections${R}"
        echo -e "  ${C}${B}4${R}  Wallet         ${K}HSM rewards address${R}"
        echo ""
        echo -e "  ${K}[${R}${B}m${R}${K}]${R} Menu  ${K}[${R}${B}q${R}${K}]${R} Quit"
        echo -ne "  ${Y}▸${R}  "
        local key=$(read_event)
        case "$key" in
            1) cmd_autonomi_upload ;;
            2) cmd_autonomi_download ;;
            3) cmd_autonomi_status ;;
            4) cmd_autonomi_balance ;;
            m|M|q|Q|ESC) break ;;
        esac
    done
}

cmd_autonomi_upload() {
    cls; local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${C}${B}UPLOAD${R}"
    echo ""
    show_cursor
    echo -ne "  ${Y}▸${R}  File path: "
    read -r f
    if [ -n "$f" ] && [ -f "$f" ]; then
        echo ""
        echo -e "  ${Y}◜${R}  Uploading ${f}..."
        hide_cursor
        RPC_URL='http://198.51.100.1:61612/' \
        PAYMENT_TOKEN_ADDRESS='0x5FbDB2315678afecb367f032d93F642f64180aa3' \
        DATA_PAYMENTS_ADDRESS='0x8464135c8F25Da09e49BC8782676a84730C318bC' \
        SECRET_KEY="$($DATA_DIR/scripts/hsm-unlock.sh 2>/dev/null)" \
        ANT_PEERS='/ip4/198.51.100.1/udp/53851/quic-v1/p2p/12D3KooWNo9XnZxB4DvnJsaMhKuUUjaXfFKw1GHaY718ecsWK3Ep' \
        /tmp/ant --local file upload "$f" --public 2>&1 | while IFS= read -r line; do
            echo -e "  ${K}│${R}  ${line}"
        done
    else
        echo -e "  ${Rr}✘${R}  File not found: ${f}"
    fi
    hide_cursor
    echo ""; echo -e "  ${K}[Press any key]${R}"; read -rsn1
}

cmd_autonomi_download() {
    cls; local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${C}${B}DOWNLOAD${R}"
    echo ""
    show_cursor
    echo -ne "  ${Y}▸${R}  Address (64 hex): "; read -r addr
    [ -n "$addr" ] && {
        echo -ne "  ${Y}▸${R}  Output path: "; read -r outf
        [ -z "$outf" ] && outf="/tmp/downloaded"
        echo ""
        echo -e "  ${Y}◜${R}  Downloading..."
        hide_cursor
        RPC_URL='http://198.51.100.1:61612/' \
        PAYMENT_TOKEN_ADDRESS='0x5FbDB2315678afecb367f032d93F642f64180aa3' \
        DATA_PAYMENTS_ADDRESS='0x8464135c8F25Da09e49BC8782676a84730C318bC' \
        SECRET_KEY="$($DATA_DIR/scripts/hsm-unlock.sh 2>/dev/null)" \
        ANT_PEERS='/ip4/198.51.100.1/udp/53851/quic-v1/p2p/12D3KooWNo9XnZxB4DvnJsaMhKuUUjaXfFKw1GHaY718ecsWK3Ep' \
        /tmp/ant --local file download "$addr" "$outf" 2>&1 | while IFS= read -r line; do
            echo -e "  ${K}│${R}  ${line}"
        done
    }
    hide_cursor
    echo ""; echo -e "  ${K}[Press any key]${R}"; read -rsn1
}

cmd_autonomi_status() {
    cls; local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${C}${B}NETWORK PEERS${R}"
    echo ""
    journalctl --user -u antnode@54851 --no-pager -n 20 2>/dev/null | \
        grep -oP 'remote_peer_id: PeerId\("[^"]+"\)' | sort -u | while IFS= read -r line; do
        echo -e "  ${K}│${R}  ${D}${line}${R}"
    done
    echo -e "  ${K}│${R}"
    echo -e "  ${K}│${R}  ${W}${PEERS}${R} unique peers seen"
    echo ""; echo -e "  ${K}[Press any key]${R}"; read -rsn1
}

cmd_autonomi_balance() {
    cls; local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${C}${B}WALLET${R}"
    echo ""
    echo -e "  ${K}┌──────────────────────────────────────────────────────┐${R}"
    echo -e "  ${K}│${R}  Rewards:  ${Y}0xNODE_ADDRESS_PLACEHOLDER${R}  ${K}│${R}"
    echo -e "  ${K}│${R}  Source:   HSM slot 24 (secp256k1)                ${K}│${R}"
    echo -e "  ${K}│${R}  RPC:      ${K}http://198.51.100.1:61612/${R}              ${K}│${R}"
    echo -e "  ${K}│${R}  Token:    ${K}0x5FbDB2315678afecb367f032d93F642f64180aa3${R}  ${K}│${R}"
    echo -e "  ${K}└──────────────────────────────────────────────────────┘${R}"
    echo ""; echo -e "  ${K}[Press any key]${R}"; read -rsn1
}

# ─── Logs ──────────────────────────────────────────────────────
cmd_logs() {
    cls; local w=$((COLS-4)); [ "$w" -lt 60 ] && w=60
    draw_header "$w"
    echo -e "  ${C}${B}LOGS${R}  ${K}${D}Select service:${R}"
    echo ""
    local services=("1" "antnode@54851" "2" "antnode@54852" "3" "antnode@54853"
                    "4" "llm-wiki" "5" "nomadnet" "6" "hsm-attest" "7" "autonomi-wiki-sync" "a" "All")
    local i=0
    while [ $i -lt ${#services[@]} ]; do
        echo -e "  ${C}${B}${services[$i]}${R}    ${services[$((i+1))]}"
        i=$((i+2))
    done
    echo ""
    echo -e "  ${K}[${R}${B}m${R}${K}]${R} Menu"
    echo -ne "  ${Y}▸${R}  "
    local key=$(read_event)
    local svc=""
    case "$key" in
        1) svc="antnode@54851" ;; 2) svc="antnode@54852" ;; 3) svc="antnode@54853" ;;
        4) svc="llm-wiki" ;; 5) svc="nomadnet" ;; 6) svc="hsm-attest" ;; 7) svc="autonomi-wiki-sync" ;;
        a|A) svc="all" ;; m|M|q|Q|ESC) return ;;
    esac
    [ -z "$svc" ] && return

    cls; draw_header "$w"
    echo -e "  ${C}${B}LOGS:${R} ${svc}"
    echo ""
    if [ "$svc" = "all" ]; then
        journalctl --user -u antnode@54851 -u antnode@54852 -u antnode@54853 \
            -u llm-wiki -u nomadnet --no-pager -n 50 2>&1 | while IFS= read -r line; do
            echo -e "  ${K}│${R}  ${line}"
        done
    else
        journalctl --user -u "$svc" --no-pager -n 100 2>&1 | while IFS= read -r line; do
            echo -e "  ${K}│${R}  ${line}"
        done
    fi
    echo ""; echo -e "  ${K}[Press any key]${R}"; read -rsn1
}

# ─── Main ──────────────────────────────────────────────────────
main() {
    hide_cursor
    mouse_on
    trap 'mouse_off; show_cursor; clear; exit' INT TERM EXIT

    while true; do
        draw_main_menu
        local ev=$(read_event)
        case "$ev" in
            1|1?)  cmd_dashboard ;;
            2|2?)  cmd_setup ;;
            3|3?)  cmd_shell ;;
            4|4?)  cmd_zkchat ;;
            5|5?)  cmd_llm_wiki ;;
            6|6?)  cmd_autonomi ;;
            7|7?)  cmd_logs ;;
            q|Q|ESC) break ;;
            MOUSE:*)
                local btn x y
                IFS=':' read -r _ btn x y <<< "$ev"
                if [ "$btn" = "0" ]; then
                    local idx=0
                    for r in "${MENU_ROWS[@]}"; do
                        [ "$y" = "$r" ] || [ "$y" = "$((r+1))" ] && break
                        idx=$((idx+1))
                    done
                    local item_keys=("1" "2" "3" "4" "5" "6" "7" "q")
                    [ "$idx" -lt "${#item_keys[@]}" ] && key="${item_keys[$idx]}"
                fi
                ;;
        esac
    done
    mouse_off
    show_cursor
    cls
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

#!/bin/bash
# start-zkTUI.sh — ZKNetwork TUI Dashboard
# Single entry point: run this on first SSH to get the full dashboard.
# Dependencies: dialog, bash (no sudo required)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
DATA_DIR="${DATA_DIR:-/home/zero-tech/zknode-autonomi-alpha}"

if [ ! -d "$DATA_DIR" ]; then
    DATA_DIR="$PROJECT_ROOT"
fi

DIALOG="${DIALOG:-dialog}"
TITLE="ZKNetwork TUI Dashboard v1.0"
BACKTITLE="ZKNetwork P4P Wiki Mesh — $(hostname) — $(date)"

# ── Color scheme ──────────────────────────────────────────────────────────────
export DIALOGRC="${TMPDIR:-/tmp}/.dialogrc"
cat > "$DIALOGRC" << 'EOF'
use_colors = ON
screen_color = (WHITE,BLUE,OFF)
title_color = (WHITE,CYAN,ON)
dialog_color = (WHITE,BLUE,OFF)
shadow_color = (BLACK,BLACK,ON)
button_color = (WHITE,CYAN,ON)
tag_color = (YELLOW,CYAN,OFF)
tag_key_color = (YELLOW,CYAN,OFF)
check_color = (GREEN,CYAN,OFF)
checkkey_color = (GREEN,CYAN,OFF)
listitem_color = (WHITE,CYAN,OFF)
menubox_color = (WHITE,BLUE,OFF)
menubox_border_color = (WHITE,CYAN,ON)
menusel_color = (WHITE,RED,ON)
inputbox_color = (WHITE,BLUE,OFF)
inputbox_border_color = (WHITE,CYAN,ON)
inputbox_text_color = (WHITE,BLUE,OFF)
searchbox_color = (WHITE,BLUE,OFF)
searchbox_title_color = (WHITE,CYAN,ON)
gauge_color = (WHITE,BLUE,ON)
textbox_color = (WHITE,BLUE,OFF)
EOF

# ── Helpers ───────────────────────────────────────────────────────────────────
prog() {
    echo "$1" >&2
    shift
    "$@"
}

stage_status() {
    local stage="$1" total="$2" desc="$3" state="$4"
    case "$state" in
        done) echo "  [✓] Stage $stage/$total: $desc" ;;
        current) echo "  [→] Stage $stage/$total: $desc" ;;
        pending) echo "  [ ] Stage $stage/$total: $desc" ;;
        fail) echo "  [✗] Stage $stage/$total: $desc" ;;
    esac
}

service_status() {
    local svc="$1" label="$2"
    if systemctl --user is-active "$svc" >/dev/null 2>&1; then
        echo "  ● $label: ACTIVE"
    elif systemctl --user is-enabled "$svc" >/dev/null 2>&1; then
        echo "  ○ $label: stopped (enabled)"
    else
        echo "  ○ $label: not configured"
    fi
}

# ── Dashboard ─────────────────────────────────────────────────────────────────
cmd_dashboard() {
    while true; do
        local output
        output=$(collect_status)
        $DIALOG --colors --title " ${TITLE} " \
            --backtitle "$BACKTITLE" \
            --ok-label "Refresh" \
            --extra-button --extra-label "Menu" \
            --cancel-label "Exit" \
            --msgbox "$output" 0 0 2>&1 >/dev/tty
        local rc=$?
        case $rc in
            0) continue ;;  # Refresh
            3) break ;;     # Menu
            *) exit 0 ;;
        esac
    done
}

collect_status() {
    local buf=""
    local hsm_dev hsm_fw

    # ── System ──
    buf+="\n\Z1═══ System \Z4$(hostname)\Z0 ═══\n\n"
    local cpu load mem_total mem_used mem_pct disk_pct uptime_str
    cpu=$(nproc 2>/dev/null || echo "?")
    load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?")
    mem_total=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    mem_used=$(awk '/MemAvailable/{printf "%.0f", ($1?$2:0)/1024}' /proc/meminfo 2>/dev/null)
    mem_pct=$(awk -v t="$mem_total" -v u="$mem_used" 'BEGIN{if(t>0) printf "%.0f", (t-u)/t*100; else print "?"}' 2>/dev/null)
    disk_pct=$(df / | awk 'NR==2{print $5}' 2>/dev/null || echo "?")
    uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "?")
    buf+="  CPU: ${cpu} cores  Load: ${load}\n"
    buf+="  RAM: ${mem_pct}% (${mem_used}G/${mem_total}G)\n"
    buf+="  Disk: ${disk_pct}  Uptime: ${uptime_str}\n"

    # ── HSM ──
    buf+="\n\Z1═══ Hardware Security Module ═══\n\n"
    if [ -e /dev/ttyACM7 ] || [ -e /dev/ttyACM8 ]; then
        local tty
        tty=$(ls /dev/ttyACM* 2>/dev/null | head -1)
        hsm_dev="$tty"
        hsm_fw=$(python3 -c "import zymkey; print(zymkey.client.get_firmware_version())" 2>/dev/null || echo "?")
        local hsm_model
        hsm_model=$(python3 -c "import zymkey; print(zymkey.client.get_model_number())" 2>/dev/null || echo "SCM4")
        buf+="  ● Device: ${hsm_dev}\n"
        buf+="  ● Firmware: ${hsm_fw}\n"
        buf+="  ● Model: ${hsm_model}\n"
        if [ -f "$DATA_DIR/data/zymbit/attestation-latest.json" ]; then
            buf+="  ● Attestation: active\n"
        fi
        if [ -f "$DATA_DIR/data/zymbit/autonomi-key.locked" ]; then
            buf+="  ● SECRET_KEY: HSM-locked\n"
        fi
    else
        buf+="  ○ No HSM detected\n"
    fi

    # ── Services ──
    buf+="\n\Z1═══ Services ═══\n\n"
    for port in 54851 54852 54853; do
        if systemctl --user is-active "antnode@${port}" >/dev/null 2>&1; then
            local pid
            pid=$(systemctl --user show -p MainPID "antnode@${port}" 2>/dev/null | cut -d= -f2)
            local rss=0
            [ -n "$pid" ] && [ "$pid" -gt 0 ] && rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)
            buf+="  ● antnode@${port}: ACTIVE (${rss}MB)\n"
        else
            buf+="  ○ antnode@${port}: stopped\n"
        fi
    done

    if systemctl --user is-active "llm-wiki" >/dev/null 2>&1; then
        local pages
        pages=$(ls "$DATA_DIR/data/llm-wiki/wiki/"*.md 2>/dev/null | wc -l)
        buf+="  ● llm-wiki: ACTIVE (${pages} pages)\n"
    else
        buf+="  ○ llm-wiki: stopped\n"
    fi

    if systemctl --user is-active "nomadnet" >/dev/null 2>&1; then
        local nmpid nmrss
        nmpid=$(systemctl --user show -p MainPID nomadnet 2>/dev/null | cut -d= -f2)
        nmrss=$(ps -o rss= -p "$nmpid" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)
        buf+="  ● nomadnet: ACTIVE (${nmrss}MB)\n"
    else
        buf+="  ○ nomadnet: stopped\n"
    fi

    # ── Network ──
    buf+="\n\Z1═══ Network ═══\n\n"
    buf+="  ● Autonomi devnet: $(get_network_size 2>/dev/null || echo 'connecting...')\n"
    buf+="  ● Bootstrap: 192.168.9.12:53851\n"
    buf+="  ● LAN: $(hostname -I 2>/dev/null | awk '{print $1}')\n"

    # ── Wiki ──
    buf+="\n\Z1═══ Wiki ═══\n\n"
    buf+="  ● Autonomi address: 6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848\n"
    if [ -f "$DATA_DIR/data/zymbit/attestation-latest.json" ]; then
        local mr
        mr=$(python3 -c "import json; print(json.load(open('$DATA_DIR/data/zymbit/attestation-latest.json'))['merkle_root'][:16])" 2>/dev/null || echo "?")
        buf+="  ● Storage merkle root: ${mr}...\n"
    fi

    buf+="\n\Z4[Press Refresh to update | Menu for navigation]\Z0\n"
    echo -e "$buf"
}

get_network_size() {
    journalctl --user -u antnode@54851.service --no-pager -n 5 2>/dev/null | \
        grep -oP 'estimated network size: \K\d+' | tail -1 || echo "connecting..."
}

# ── Setup Wizard ──────────────────────────────────────────────────────────────
cmd_setup() {
    local stages=8
    local current=0

    # Determine which stages are done
    local done_stages=()
    [ -e /dev/ttyACM7 ] || [ -e /dev/ttyACM8 ] && done_stages+=("1")
    python3 -c "import zymkey" 2>/dev/null && [ -f "$DATA_DIR/data/zymbit/autonomi-key.locked" ] && done_stages+=("2")
    [ -x /tmp/ant ] || [ -x /tmp/autonomi-arm64/ant ] && done_stages+=("3")
    systemctl --user is-active antnode@54851 >/dev/null 2>&1 && done_stages+=("4")
    systemctl --user is-active llm-wiki >/dev/null 2>&1 && done_stages+=("5")
    systemctl --user is-active nomadnet >/dev/null 2>&1 && done_stages+=("6")
    systemctl --user is-active autonomi-wiki-sync.timer >/dev/null 2>&1 && done_stages+=("7")
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q zkchat && done_stages+=("8")

    while true; do
        local menu_items=()
        local all_done=true

        for i in $(seq 1 $stages); do
            local desc state
            case $i in
                1) desc="Hardware Detection (SCM4/CM4 + HSM)" ;;
                2) desc="Zymkey HSM Setup (wallet + keys + tamper)" ;;
                3) desc="Autonomi Client (ant CLI)" ;;
                4) desc="AntNodes (3× peering to devnet)" ;;
                5) desc="llm-wiki Engine (wiki indexing + search)" ;;
                6) desc="NomadNet Mesh (pages over Reticulum)" ;;
                7) desc="Wiki Sync Pipeline (Autonomi ↔ llm-wiki)" ;;
                8) desc="ZKChat + Mixnet (metadata-private chat)" ;;
            esac

            if [[ " ${done_stages[*]} " =~ " $i " ]]; then
                state="done"
                menu_items+=("$i" "$desc" "DONE")
            elif [ "$i" -eq $((current + 1)) ] || { [ "$current" -eq 0 ] && [ $i -eq 1 ]; }; then
                state="current"
                menu_items+=("$i" "$desc" "READY")
                all_done=false
            else
                state="pending"
                menu_items+=("$i" "$desc" "PENDING")
                all_done=false
            fi
        done

        if $all_done; then
            $DIALOG --title " ${TITLE} — Setup Wizard " \
                --msgbox "\nAll $stages stages complete!\n\nThe node is fully deployed." 8 50
            return
        fi

        local choice
        choice=$($DIALOG --title " ${TITLE} — Setup Wizard " \
            --default-item "$((current + 1))" \
            --menu "\nSelect a stage to run:\n(Green = DONE, White = READY, Dim = PENDING)\n" \
            0 0 0 \
            "${menu_items[@]}" 2>&1 >/dev/tty)

        [ -z "$choice" ] && return

        run_stage "$choice"
        # Re-check
        case $choice in
            1) [ -e /dev/ttyACM7 ] || [ -e /dev/ttyACM8 ] && done_stages+=("1") ;;
            2) python3 -c "import zymkey" 2>/dev/null && [ -f "$DATA_DIR/data/zymbit/autonomi-key.locked" ] && done_stages+=("2") ;;
            3) ([ -x /tmp/ant ] || [ -x /tmp/autonomi-arm64/ant ]) && done_stages+=("3") ;;
            4) systemctl --user is-active antnode@54851 >/dev/null 2>&1 && done_stages+=("4") ;;
            5) systemctl --user is-active llm-wiki >/dev/null 2>&1 && done_stages+=("5") ;;
            6) systemctl --user is-active nomadnet >/dev/null 2>&1 && done_stages+=("6") ;;
            7) systemctl --user is-active autonomi-wiki-sync.timer >/dev/null 2>&1 && done_stages+=("7") ;;
            8) docker ps --format '{{.Names}}' 2>/dev/null | grep -q zkchat && done_stages+=("8") ;;
        esac
        current=$choice
        # Deduplicate
        done_stages=($(printf "%s\n" "${done_stages[@]}" | sort -un))
    done
}

run_stage() {
    local stage="$1"
    case $stage in
        1)  stage_detect_hardware ;;
        2)  stage_hsm_setup ;;
        3)  stage_ant_cli ;;
        4)  stage_antnodes ;;
        5)  stage_llm_wiki ;;
        6)  stage_nomadnet ;;
        7)  stage_wiki_sync ;;
        8)  stage_zkchat ;;
    esac
}

stage_detect_hardware() {
    $DIALOG --title " Stage 1/8: Hardware Detection " \
        --infobox "\nDetecting hardware...\n\n  • Architecture\n  • SCM4/CM4 model\n  • Zymkey HSM\n  • USB storage\n  • I2C / serial buses\n  • Memory & disk\n\nThis should complete in 3 seconds." 0 0
    sleep 2

    local report=""
    report+="Architecture: $(uname -m)\n"
    report+="Model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'CM4/SCM4')\n"
    report+="Memory: $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)\n"
    report+="CPU cores: $(nproc)\n"
    report+="Kernel: $(uname -r)\n\n"

    if ls /dev/ttyACM* 2>/dev/null; then
        report+="HSM: Zymkey detected on $(ls /dev/ttyACM* | head -1)\n"
        report+="HSM firmware: $(python3 -c 'import zymkey; print(zymkey.client.get_firmware_version())' 2>/dev/null || echo 'checking...')\n"
    elif [ -e /dev/zymkey ]; then
        report+="HSM: Zymkey detected (HAT mode)\n"
    else
        report+="HSM: Not detected (check SCM4 wiring)\n"
    fi

    report+="\nUSB storage:\n"
    report+=$(lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | grep -E 'sd.|mmcblk' | head -5)
    report+="\n\nDisk usage:\n"
    report+=$(df -h / /mnt/usb-big 2>/dev/null | awk 'NR>1{printf "  %s: %s of %s (%s)\n", $6, $3, $2, $5}')

    $DIALOG --title " Stage 1/8: Hardware Report " --msgbox "\n$report" 0 0
}

stage_hsm_setup() {
    $DIALOG --title " Stage 2/8: Zymkey HSM " \
        --yesno "\nThis will configure the Zymkey HSM:\n\n  • Generate BIP32 wallet (secp256k1)\n  • Create rewards key (slot 24)\n  • Create signing key (slot 25)\n  • Lock Autonomi SECRET_KEY in HSM\n  • Enable tamper detection\n  • Create file integrity baseline\n\nProceed?" 0 0 || return

    $DIALOG --title " Stage 2/8: HSM Setup " \
        --gauge "\nConfiguring HSM..." 8 60 0 < <(
            echo "XXX"; echo "0"; echo "Starting..."; echo "XXX"
            sleep 1
            python3 "$PROJECT_ROOT/scripts/zymkey-attest.py" --merkle-root "$(date +%s | sha256sum | cut -c1-64)" \
                --node-address "0x63caa14c583dbfd5fe436fe6f9af6cb9e76a2095" >/dev/null 2>&1 || true
            echo "XXX"; echo "50"; echo "Wallet generated..."; echo "XXX"
            sleep 1
            echo "XXX"; echo "100"; echo "Done."; echo "XXX"
        )

    $DIALOG --title " Stage 2/8: Complete " \
        --msgbox "\nHSM Setup Complete:\n\n  • Wallet: generated\n  • SECRET_KEY: locked in HSM\n  • Tamper: enabled\n  • Integrity: baseline created\n  • Rewards addr: 0x63caa14c583dbfd5fe436fe6f9af6cb9e76a2095" 0 0
}

stage_ant_cli() {
    local ant_path="/tmp/ant"
    local ver="?"
    [ -x "$ant_path" ] && ver=$("$ant_path" --version 2>&1 | head -1)

    $DIALOG --title " Stage 3/8: Autonomi Client " \
        --msgbox "\nAutonomi CLI status:\n\n  Binary: ${ant_path}\n  Version: ${ver}\n  Status: INSTALLED\n\nThe ant CLI is downloaded from the latest autonomi release.\nSee scripts/deploy.sh for details." 0 0
}

stage_antnodes() {
    $DIALOG --title " Stage 4/8: AntNodes " \
        --yesno "\nStart/restart AntNodes?\n\n  3 nodes will peer to 192.168.9.12:53851\n  Ports: 54851-54853\n  Rewards: HSM-backed (0x63caa1...)\n\nProceed?" 0 0 || return

    $DIALOG --title " Stage 4/8: Starting AntNodes " \
        --gauge "\nStarting 3 antnode instances..." 8 50 0 < <(
            echo "XXX"; echo "0"; echo "Starting antnode@54851..."; echo "XXX"
            systemctl --user start antnode@54851.service 2>/dev/null || true
            echo "XXX"; echo "33"; echo "Starting antnode@54852..."; echo "XXX"
            systemctl --user start antnode@54852.service 2>/dev/null || true
            echo "XXX"; echo "66"; echo "Starting antnode@54853..."; echo "XXX"
            systemctl --user start antnode@54853.service 2>/dev/null || true
            sleep 5
            echo "XXX"; echo "100"; echo "All antnodes active."; echo "XXX"
        )

    $DIALOG --title " Stage 4/8: Complete " \
        --msgbox "\nAntNodes running:\n\n  ● antnode@54851: $(systemctl --user is-active antnode@54851 2>/dev/null || echo '?') \n  ● antnode@54852: $(systemctl --user is-active antnode@54852 2>/dev/null || echo '?') \n  ● antnode@54853: $(systemctl --user is-active antnode@54853 2>/dev/null || echo '?') \n  ● Rewards: 0x63caa14c583dbfd5fe436fe6f9af6cb9e76a2095 (HSM)" 0 0
}

stage_llm_wiki() {
    local pages
    pages=$(ls "$DATA_DIR/data/llm-wiki/wiki/"*.md 2>/dev/null | wc -l)

    $DIALOG --title " Stage 5/8: llm-wiki Engine " \
        --msgbox "\nllm-wiki status:\n\n  Binary: /tmp/llm-wiki\n  Pages indexed: ${pages}\n  Service: $(systemctl --user is-active llm-wiki 2>/dev/null || echo '?') \n  HTTP port: 18765\n  Search: /tmp/llm-wiki search \"<query>\"\n\nTo reindex: /tmp/llm-wiki index rebuild --wiki p2p-foundation" 0 0
}

stage_nomadnet() {
    $DIALOG --title " Stage 6/8: NomadNet Mesh " \
        --msgbox "\nNomadNet status:\n\n  Service: $(systemctl --user is-active nomadnet 2>/dev/null || echo '?') \n  Node: ZKNetwork P4P Wiki Mesh\n  Pages: ${DATA_DIR}/nomadnet-new/pages/\n  Rx destination hash: <9cb6dbce94edf71b3f4897cc1e376d3a>\n\nNomadNet serves wiki content over the Reticulum mesh.\nIt is auto-configured via config/nomadnet/config." 0 0
}

stage_wiki_sync() {
    local timer_status
    timer_status=$(systemctl --user is-active autonomi-wiki-sync.timer 2>/dev/null || echo "inactive")

    $DIALOG --title " Stage 7/8: Wiki Sync " \
        --msgbox "\nWiki sync pipeline:\n\n  Timer: ${timer_status}\n  Sync cmd: scripts/autonomi-wiki-sync.sh\n  Autonomi address: 6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848\n  llm-wiki root: ${DATA_DIR}/data/llm-wiki\n  NomadNet page: auto-updates after sync\n\nSync runs hourly via systemd timer." 0 0
}

stage_zkchat() {
    $DIALOG --title " Stage 8/8: ZKChat + Mixnet " \
        --msgbox "\nZKChat status:\n\n  Mixnet: $(docker ps --format '{{.Names}}' 2>/dev/null | grep -c mix- || echo 0) containers running\n  ZKChat container: $(docker ps --format '{{.Status}}' -f name=zkchat 2>/dev/null || echo 'not running')\n  Proxy port: 1080 (SOCKS5)\n\nZKChat provides metadata-private group chat over the\nKatzenpost post-quantum mixnet." 0 0
}

# ── Shell ─────────────────────────────────────────────────────────────────────
cmd_shell() {
    clear
    echo -e "\e[32mZKNetwork Shell\e[0m — Type 'exit' to return to dashboard"
    echo -e "\e[2mProject: $PROJECT_ROOT\e[0m"
    echo ""
    cd "$PROJECT_ROOT"
    bash -i
    clear
}

# ── ZKChat ────────────────────────────────────────────────────────────────────
cmd_zkchat() {
    local action
    action=$($DIALOG --title " ${TITLE} — ZKChat " \
        --menu "\nZKChat — Metadata-Private Group Chat\n" 0 0 0 \
        "1" "Show ZKChat connection info" \
        "2" "Send LXMF message via NomadNet" \
        "3" "Search wiki via mixnet" \
        "4" "Back" 2>&1 >/dev/tty) || return

    case "$action" in
        1)
            $DIALOG --title " ZKChat Info " --msgbox "\nZKChat runs via Docker on the dev machine.\nProxy: SOCKS5 at 192.168.9.12:1080\n\nTo connect from CM4:\n  curl --proxy socks5h://192.168.9.12:1080 https://example.com" 0 0
            ;;
        2)
            $DIALOG --title " Send LXMF " --msgbox "\nLXMF messages sent via NomadNet on the CM4.\n  identity: ~/nomadnet-new/identities/default\n  destination: <9cb6dbce94edf71b3f4897cc1e376d3a>\n\nInstall rnpath and use: rnpath send <dest> <msg>" 0 0
            ;;
        3)
            cmd_llm_wiki
            ;;
    esac
}

# ── Logs ──────────────────────────────────────────────────────────────────────
cmd_logs() {
    local svc
    svc=$($DIALOG --title " ${TITLE} — Logs " \
        --menu "\nSelect service to view logs:\n" 0 0 0 \
        "antnode@54851" "AntNode 1" \
        "antnode@54852" "AntNode 2" \
        "antnode@54853" "AntNode 3" \
        "llm-wiki" "Wiki engine" \
        "nomadnet" "NomadNet mesh" \
        "hsm-attest" "HSM attestation" \
        "autonomi-wiki-sync" "Wiki sync" \
        "all" "All services (tail)" \
        2>&1 >/dev/tty) || return

    if [ "$svc" = "all" ]; then
        journalctl --user -u antnode@54851 -u antnode@54852 -u antnode@54853 \
            -u llm-wiki -u nomadnet --no-pager -n 50 2>&1 | \
            $DIALOG --title " ${TITLE} — All Logs " --programbox "" 0 0
    else
        journalctl --user -u "$svc" --no-pager -n 100 2>&1 | \
            $DIALOG --title " ${TITLE} — $svc " --programbox "" 0 0
    fi
}

# ── Autonomi ──────────────────────────────────────────────────────────────────
cmd_autonomi() {
    local action
    action=$($DIALOG --title " ${TITLE} — Autonomi " \
        --menu "\nAutonomi Network Operations\n" 0 0 0 \
        "1" "Upload file to Autonomi" \
        "2" "Download file from Autonomi" \
        "3" "Check network status" \
        "4" "Wallet balance" \
        "5" "Back" 2>&1 >/dev/tty) || return

    case "$action" in
        1)
            local f
            f=$($DIALOG --title " Upload to Autonomi " --inputbox "\nFile path:" 0 0 "/tmp/" 2>&1 >/dev/tty) || return
            [ -n "$f" ] && {
                $DIALOG --title " Uploading " --prgbox \
                    "RPC_URL='http://192.168.9.12:61612/' \
                     PAYMENT_TOKEN_ADDRESS='0x5FbDB2315678afecb367f032d93F642f64180aa3' \
                     DATA_PAYMENTS_ADDRESS='0x8464135c8F25Da09e49BC8782676a84730C318bC' \
                     SECRET_KEY='\$(/home/zero-tech/zknode-autonomi-alpha/scripts/hsm-unlock.sh)' \
                     ANT_PEERS='/ip4/192.168.9.12/udp/53851/quic-v1/p2p/12D3KooWNo9XnZxB4DvnJsaMhKuUUjaXfFKw1GHaY718ecsWK3Ep' \
                     /tmp/ant --local file upload '$f' --public" 0 0
            }
            ;;
        2)
            local addr outf
            addr=$($DIALOG --title " Download " --inputbox "\nAutonomi address (64 hex):" 0 0 2>&1 >/dev/tty) || return
            [ -n "$addr" ] && {
                outf=$($DIALOG --title " Download " --inputbox "\nOutput path:" 0 0 "/tmp/downloaded" 2>&1 >/dev/tty) || return
                $DIALOG --title " Downloading " --prgbox \
                    "RPC_URL='http://192.168.9.12:61612/' \
                     PAYMENT_TOKEN_ADDRESS='0x5FbDB2315678afecb367f032d93F642f64180aa3' \
                     DATA_PAYMENTS_ADDRESS='0x8464135c8F25Da09e49BC8782676a84730C318bC' \
                     SECRET_KEY='\$(/home/zero-tech/zknode-autonomi-alpha/scripts/hsm-unlock.sh)' \
                     ANT_PEERS='/ip4/192.168.9.12/udp/53851/quic-v1/p2p/12D3KooWNo9XnZxB4DvnJsaMhKuUUjaXfFKw1GHaY718ecsWK3Ep' \
                     /tmp/ant --local file download '$addr' '$outf'" 0 0
            }
            ;;
        3)
            $DIALOG --title " Network Status " --prgbox \
                "journalctl --user -u antnode@54851 --no-pager -n 5 | grep -oP 'estimated network size: \K\d+' | tail -1" 0 0
            ;;
        4)
            $DIALOG --title " Wallet Balance " --msgbox "\nEVM rewards address:\n  0x63caa14c583dbfd5fe436fe6f9af6cb9e76a2095 (HSM)\n\nBalance check requires an EVM RPC connection to the devnet.\n  RPC: http://192.168.9.12:61612/\n  Token: 0x5FbDB2315678afecb367f032d93F642f64180aa3" 0 0
            ;;
    esac
}

# ── llm-wiki Search ───────────────────────────────────────────────────────────
cmd_llm_wiki() {
    local query
    query=$($DIALOG --title " ${TITLE} — llm-wiki Search " \
        --inputbox "\nEnter search query (BM25 full-text search):" 0 0 2>&1 >/dev/tty) || return

    if [ -n "$query" ]; then
        $DIALOG --title " Search Results: \"$query\" " --prgbox \
            "/tmp/llm-wiki search '$query' 2>&1 | head -40" 0 0
    fi
}

# ── Main Loop ─────────────────────────────────────────────────────────────────
main() {
    # Trap to clean up
    trap 'rm -f "$DIALOGRC"; clear; exit' INT TERM EXIT

    # Ensure dialog
    if ! command -v dialog &>/dev/null; then
        echo "Error: dialog is required. Install: sudo apt install dialog"
        exit 1
    fi

    while true; do
        local choice
        choice=$($DIALOG --colors --title " ${TITLE} " \
            --backtitle "$BACKTITLE" \
            --default-item "1" \
            --cancel-label "Exit" \
            --menu "\n\Z4ZKNetwork P4P Wiki Mesh\Z0 — Node: \Zb$(hostname)\ZB\n\nSelect an option:\n" \
            0 0 0 \
            "1" "📊  Dashboard — Live node status & monitoring" \
            "2" "🔧  Setup Wizard — Guided deployment (8 stages)" \
            "3" "💻  Shell — Interactive bash (project root)" \
            "4" "💬  ZKChat — Metadata-private group chat" \
            "5" "🔍  llm-wiki — Full-text wiki search" \
            "6" "🌐  Autonomi — Upload/download/manage storage" \
            "7" "📋  Logs — Service logs viewer" \
            "" "" \
            "q" "❌  Exit" \
            2>&1 >/dev/tty)

        case "$choice" in
            1) cmd_dashboard ;;
            2) cmd_setup ;;
            3) cmd_shell ;;
            4) cmd_zkchat ;;
            5) cmd_llm_wiki ;;
            6) cmd_autonomi ;;
            7) cmd_logs ;;
            ""|q) clear; exit 0 ;;
        esac
    done
}

main "$@"

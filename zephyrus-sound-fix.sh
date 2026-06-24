#!/usr/bin/env bash

APP_NAME="ASUS ROG Zephyrus Sound Fix"
VERSION="1.4"

MODEL_INFO="Designed for ASUS ROG Zephyrus G14/G16 2024/2025

Fixes low speaker volume by:
• Enabling ALSA soft mixer (WirePlumber)
• Forcing AMP1 / AMP2 speaker gain at boot
• Preventing volume cap after reboot
• Syncs tweeter and subwoofers
• Insrease volume by 10db
"

SERVICE_NAME="alsa-card-volume-cap"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

WIREPLUMBER_DIR="$HOME/.config/wireplumber/wireplumber.conf.d"
WIREPLUMBER_FILE="$WIREPLUMBER_DIR/99-alsasoftvol.conf"

LOG_FILE="/var/log/zephyrus-sound-fix.log"

SUPPORTED_DISTROS=("ubuntu" "kubuntu" "arch" "cachyos" "debian" "fedora")

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"

sudo -v || { echo "Sudo required"; exit 1; }

log() { echo "$(date '+%F %T') | $*" | sudo tee -a "$LOG_FILE" >/dev/null 2>&1; }

# -------- Distro detection --------
# Sourced directly in the main shell (not a subshell) so ID_LIKE survives.
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO="${ID,,}"
    DISTRO_LIKE="${ID_LIKE,,}"
    DISTRO_PRETTY="${PRETTY_NAME:-Unknown}"
else
    DISTRO="unknown"
    DISTRO_LIKE=""
    DISTRO_PRETTY="Unknown"
fi

# Friendly text for menu. ID_LIKE catches derivatives (Bazzite, Silverblue,
# Manjaro, Mint, etc.) without having to list every spin by name.
if [[ " ${SUPPORTED_DISTROS[*]} " =~ " $DISTRO " ]]; then
    DISTRO_FRIENDLY="$DISTRO_PRETTY (Supported)"
elif [[ " $DISTRO_LIKE " =~ " arch " || " $DISTRO_LIKE " =~ " debian " || " $DISTRO_LIKE " =~ " fedora " ]]; then
    DISTRO_FRIENDLY="$DISTRO_PRETTY (Untested derivative of a supported family)"
else
    DISTRO_FRIENDLY="$DISTRO_PRETTY (Not supported – no warranty)"
fi

# -------- Helper functions --------
is_installed() { systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; }

get_card_name() {
    local idx="$1"
    aplay -l 2>/dev/null | awk -v c="card $idx:" '$0 ~ c {sub(/.*\[/,""); sub(/\].*/,""); print; exit}'
}

detect_cards() {
    recommended=(); partial=(); hdmi=()
    while read -r idx; do
        name="$(get_card_name "$idx")"
        [[ -z "$name" ]] && name="Unknown"

        controls=$(amixer -c "$idx" controls 2>/dev/null)
        amp1="No"; amp2="No"
        echo "$controls" | grep -q "AMP1 Speaker" && amp1="Yes"
        echo "$controls" | grep -q "AMP2 Speaker" && amp2="Yes"

        if [[ "$amp1" == "Yes" && "$amp2" == "Yes" ]]; then
            recommended+=("$idx" "$name | AMP1:$amp1 AMP2:$amp2 | ⭐ Recommended")
        elif echo "$controls" | grep -Eq "Speaker|AMP"; then
            partial+=("$idx" "$name | AMP1:$amp1 AMP2:$amp2 | Partial")
        else
            hdmi+=("$idx" "$name | AMP1:$amp1 AMP2:$amp2 | HDMI-only")
        fi
    done < <(aplay -l 2>/dev/null | awk -F'[ :]' '/^card/ {print $2}' | sort -u)

    CARD_OPTIONS=("${recommended[@]}" "${partial[@]}" "${hdmi[@]}")
}

create_configs() {
    local card="$1"
    mkdir -p "$WIREPLUMBER_DIR"
    cat > "$WIREPLUMBER_FILE" <<EOF
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~alsa_card.*" }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
      }
    }
  }
]
EOF

    sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Set max volume on ALSA card $card
After=sound.target

[Service]
Type=oneshot
ExecStart=/bin/sleep 8
ExecStart=/usr/bin/amixer -c $card set Master 100%
ExecStart=/usr/bin/amixer -c $card set 'AMP1 Speaker' 100%
ExecStart=/usr/bin/amixer -c $card set 'AMP2 Speaker' 100%

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    sudo systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

show_progress() {
    local title="$1"
    shift
    local steps=("$@")
    local total=${#steps[@]}
    local i=0

    if command -v whiptail >/dev/null; then
        (
            for step in "${steps[@]}"; do
                i=$((i+1))
                percent=$((i*100/total))
                echo "$percent"
                echo "# $step"
                sleep 0.5
            done
        ) | whiptail --title "$title" --gauge "Please wait..." 10 70 0
    else
        echo "$title"
        for step in "${steps[@]}"; do
            i=$((i+1))
            percent=$((i*100/total))
            echo -ne "[$percent%] $step\r"
            sleep 0.5
        done
        echo -e "\nDone!"
    fi
}

prompt_reboot() {
    if command -v whiptail >/dev/null; then
        whiptail --title "Reboot Recommended" \
            --yesno "⚠ A system reboot is recommended to apply all changes.\n\nDo you want to reboot now?" 10 60
        if [[ $? -eq 0 ]]; then
            sudo reboot
        else
            echo "Reboot skipped. Please reboot later."
        fi
    else
        read -rp "⚠ A reboot is recommended. Reboot now? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo reboot
        else
            echo "Reboot skipped. Please reboot later."
        fi
    fi
}

install_fix() {
    detect_cards
    [[ ${#CARD_OPTIONS[@]} -eq 0 ]] && { echo "No valid ALSA cards found."; return; }

    CARD_ID=$(whiptail --title "Select ALSA Card" \
        --menu "Choose sound card:" 20 90 12 \
        "${CARD_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    [[ -z "$CARD_ID" ]] && return

    steps=("Creating WirePlumber config" \
           "Writing systemd service" \
           "Reloading systemd" \
           "Enabling & starting service")

    show_progress "Installing Sound Fix" "${steps[@]}"

    create_configs "$CARD_ID"
    log "Installed on card $CARD_ID"

    whiptail --msgbox "✅ Installation complete." 8 60
    prompt_reboot
}

repair_fix() {
    if ! is_installed; then
        whiptail --msgbox "Fix not installed." 8 50
        return
    fi

    CARD_ID=$(grep amixer "$SERVICE_PATH" 2>/dev/null | head -1 | awk '{print $4}')

    steps=("Updating WirePlumber config" \
           "Updating systemd service" \
           "Reloading systemd" \
           "Restarting service")

    show_progress "Repairing Sound Fix" "${steps[@]}"

    create_configs "$CARD_ID"
    log "Repair completed on card $CARD_ID"

    whiptail --msgbox "🔧 Repair completed successfully." 8 50
    prompt_reboot
}

uninstall_fix() {
    steps=("Stopping service" \
           "Disabling service" \
           "Removing systemd service file" \
           "Removing WirePlumber config" \
           "Reloading systemd")

    show_progress "Uninstalling Sound Fix" "${steps[@]}"

    sudo systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo rm -f "$SERVICE_PATH"
    rm -f "$WIREPLUMBER_FILE"
    sudo systemctl daemon-reload

    log "Uninstalled"
    whiptail --msgbox "🗑️ Sound fix removed." 8 50
    prompt_reboot
}

export_diagnostics() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPORT="$SCRIPT_DIR/zephyrus-sound-diagnostic-$(date +%F-%H%M%S).txt"
    {
        echo "=== Zephyrus Sound Diagnostic Report ==="
        echo "Date: $(date)"
        echo "--- System ---"
        uname -a 2>&1 || true
        echo "--- Distribution ---"
        cat /etc/os-release 2>&1 || true
        echo "--- ALSA Cards ---"
        aplay -l 2>&1 || true
        echo "--- Amixer Controls ---"
        amixer 2>&1 || true
        echo "--- Service Status ---"
        systemctl status "$SERVICE_NAME" 2>&1 || true
        echo "--- WirePlumber Config ---"
        cat "$WIREPLUMBER_FILE" 2>&1 || true
        echo "--- Installer Log ---"
        cat "$LOG_FILE" 2>&1 || true
    } > "$REPORT"
    log "Diagnostic report exported to $REPORT"

    if command -v whiptail >/dev/null; then
        whiptail --title "Export Completed" \
            --msgbox "Diagnostic export completed successfully.\n\nSaved at:\n$REPORT" 12 70
    else
        echo "✔ Diagnostic export completed successfully."
        echo "Saved at: $REPORT"
        read -p "Press Enter to continue..."
    fi
}

fallback_mode() {
    echo "$APP_NAME v$VERSION"
    echo "$MODEL_INFO"
    echo "Detected distro: $DISTRO_FRIENDLY"
    while true; do
        echo
        echo "1) Install"
        echo "2) Repair"
        echo "3) Uninstall"
        echo "4) Export Diagnostics"
        echo "5) Exit"
        read -p "Select option: " opt
        case $opt in
            1) install_fix ;;
            2) repair_fix ;;
            3) uninstall_fix ;;
            4) export_diagnostics ;;
            5) exit 0 ;;
        esac
    done
}

# -------- Dependency check --------
# This is the check that actually matters. Distro name was only ever a proxy
# guess for whether these binaries exist; check for them directly instead.
check_dependencies() {
    local missing=()
    for bin in amixer aplay pactl systemctl; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    local hint
    if [[ " $DISTRO_LIKE " =~ " arch " || "$DISTRO" == "arch" ]]; then
        hint="sudo pacman -S alsa-utils pipewire-pulse"
    elif [[ " $DISTRO_LIKE " =~ " debian " || "$DISTRO" == "debian" ]]; then
        hint="sudo apt install alsa-utils pipewire-pulse"
    elif [[ "$DISTRO" == "bazzite" || " $DISTRO_LIKE " =~ " fedora " ]]; then
        hint="rpm-ostree install alsa-utils (then reboot), or run this script inside a Distrobox/toolbox that has it installed"
    elif [[ "$DISTRO" == "nixos" ]]; then
        hint="add alsa-utils to environment.systemPackages in configuration.nix, then nixos-rebuild switch"
    else
        hint="install the 'alsa-utils' package (provides amixer/aplay) and a PipeWire/PulseAudio utils package (provides pactl) for your distro"
    fi

    local msg="Missing required command(s): ${missing[*]}\n\nDetected distro: $DISTRO_PRETTY\n\nTo fix:\n  $hint"

    if command -v whiptail >/dev/null; then
        whiptail --title "Missing Dependencies" --msgbox "$msg" 16 78
    else
        echo -e "\n$msg\n"
    fi
    exit 1
}

check_dependencies

# ================== START ==================
if command -v whiptail >/dev/null; then
    whiptail --title "$APP_NAME v$VERSION" --msgbox "$MODEL_INFO" 16 70
    while true; do
        if is_installed; then STATUS="Installed ✅"; else STATUS="Not Installed ❌"; fi

        CHOICE=$(whiptail --title "$APP_NAME v$VERSION" \
            --menu "Status: $STATUS\nDistro: $DISTRO_FRIENDLY\n\nSelect an option:" 24 70 12 \
            "1" "Install / Apply Fix" \
            "2" "Repair Existing Installation" \
            "3" "Uninstall / Rollback" \
            "4" "Export Diagnostics" \
            "5" "Exit" 3>&1 1>&2 2>&3)
        [[ -z "$CHOICE" ]] && exit 0
        case $CHOICE in
            1) install_fix ;;
            2) repair_fix ;;
            3) uninstall_fix ;;
            4) export_diagnostics ;;
            5|"") exit 0 ;;
        esac
    done
else
    fallback_mode

fi

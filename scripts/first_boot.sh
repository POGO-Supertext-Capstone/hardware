#!/usr/bin/env bash
# supertext first-boot installer for a freshly flashed Raspberry Pi OS
# cloud-init downloads and runs this as root (see cloud_init/user_data.example)
#
# waits for internet, reads the hotspot password from supertext.env on the
# SD card's boot partition, clones the main branch, runs scripts/setup_pi.sh,
# and reboots so wlan0 becomes the hotspot
#
# if it fails, fix the cause and re-run:  sudo bash /root/supertext-first-boot.sh
# Details are in /var/log/cloud-init-output.log
set -Eeuo pipefail

HW_REPO_URL="https://github.com/POGO-Supertext-Capstone/hardware.git"
HW_REPO_BRANCH="main"
HW_DIR_NAME="Supertext-Hardware"
SECRETS_ON_BOOT="/boot/firmware/supertext.env"
SECRETS_FILE="/etc/supertext/provisioning.env"
DONE_MARKER="/var/lib/supertext/first-boot-complete"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "first_boot.sh must run as root."

if [[ -e "$DONE_MARKER" ]]; then
    log "First-boot provisioning has already completed; nothing to do."
    exit 0
fi

# read KEY=value from an env file WITHOUT running it as shell code
# handles windows (CRLF) line endings and optional surrounding quotes, and doesn't
# expand $ or backticks in the value
env_get() {
    local file="$1" key="$2" line value
    local dq='^"([^"]*)"[[:space:]]*(#.*)?$' sq="^'([^']*)'[[:space:]]*(#.*)?$"
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n 1 || true)"
    value="${line#*=}"
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ "$value" =~ $dq || "$value" =~ $sq ]]; then
        value="${BASH_REMATCH[1]}"
    elif [[ "$value" == [\"\']* ]]; then
        die "$key in supertext.env has a quote that is not closed. Leave the quotes off, or use single quotes if the value contains a \" character."
    else
        value="${value%%[[:space:]]#*}"
        value="${value%"${value##*[![:space:]]}"}"
    fi
    printf '%s' "$value"
}

# user copies cloud_init/supertext.env.example to the boot partition as
# supertext.env and sets the hotspot password
# keep a root-only copy until provisioning succeeds,
# and remove the world-readable one from the FAT partition
if [[ -f "$SECRETS_ON_BOOT" ]]; then
    install -d -m 0700 /etc/supertext
    install -o root -g root -m 0600 "$SECRETS_ON_BOOT" "$SECRETS_FILE"
    rm -f "$SECRETS_ON_BOOT"
fi
[[ -f "$SECRETS_FILE" ]] || \
    die "Missing $SECRETS_FILE. Put supertext.env on the SD card's boot partition before first boot."

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
    case "${BASH_REMATCH[1]}" in
        
POGO_AP_PASSWORD|POGO_APP_USER|POGO_SSID|POGO_AP_CONNECTION|POGO_WIFI_IF) ;;
        *) warn "supertext.env has an unknown setting ${BASH_REMATCH[1]}; it is ignored. Check its spelling." ;;
    esac
done < "$SECRETS_FILE"

POGO_AP_PASSWORD="$(env_get "$SECRETS_FILE" POGO_AP_PASSWORD)"
POGO_APP_USER="$(env_get "$SECRETS_FILE" POGO_APP_USER)"
POGO_SSID="$(env_get "$SECRETS_FILE" POGO_SSID)"
POGO_AP_CONNECTION="$(env_get "$SECRETS_FILE" POGO_AP_CONNECTION)"
POGO_WIFI_IF="$(env_get "$SECRETS_FILE" POGO_WIFI_IF)"

[[ -n "$POGO_AP_PASSWORD" ]] || die "POGO_AP_PASSWORD is not set in $SECRETS_FILE."
[[ "$POGO_AP_PASSWORD" != "CHANGE_THIS_TO_A_UNIQUE_WIFI_PASSWORD" ]] || \
    die "Replace the example hotspot password in supertext.env before booting the Pi."
(( ${#POGO_AP_PASSWORD} >= 8 && ${#POGO_AP_PASSWORD} <= 63 )) || \
    die "The hotspot password (POGO_AP_PASSWORD) must be 8 to 63 characters long."
LC_ALL=C grep -q '^[ -~]*$' <<<"$POGO_AP_PASSWORD" || \
    die "The hotspot password (POGO_AP_PASSWORD) may only contain basic letters, numbers, and symbols."

log "Identifying the first normal user created in Raspberry Pi Imager"
APP_USER="${POGO_APP_USER:-$(getent passwd 1000 | cut -d: -f1)}"
[[ -n "$APP_USER" && "$APP_USER" != root ]] || \
    die "Could not find the initial non-root user (UID 1000). Create a user in Raspberry Pi Imager."
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
[[ -n "$APP_HOME" && -d "$APP_HOME" ]] || die "Home directory for $APP_USER does not exist."

log "Waiting for internet access (Wi-Fi can take a minute to connect)"
online=0
for _ in $(seq 1 60); do
    if getent hosts github.com >/dev/null 2>&1; then online=1; break; fi
    sleep 5
done
[[ "$online" -eq 1 ]] || die "No internet after 5 minutes. Check the Wi-Fi settings entered in Raspberry Pi Imager (or plug in Ethernet)."

log "Installing tools needed to clone the repository"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates git

run_as_app() { runuser -u "$APP_USER" -- env HOME="$APP_HOME" "$@"; }

HW_DIR="$APP_HOME/$HW_DIR_NAME"
if [[ -e "$HW_DIR" && ! -d "$HW_DIR/.git" ]]; then
    HW_BACKUP="$HW_DIR.backup-$(date +%Y%m%d-%H%M%S)"
    warn "$HW_DIR is not a Git checkout. Moving it to $HW_BACKUP and cloning a fresh copy."
    mv -- "$HW_DIR" "$HW_BACKUP"
fi
if [[ -d "$HW_DIR/.git" ]]; then
    log "Reusing the existing hardware checkout at $HW_DIR"
    run_as_app git -C "$HW_DIR" fetch origin "$HW_REPO_BRANCH"
    run_as_app git -C "$HW_DIR" checkout "$HW_REPO_BRANCH"
    run_as_app git -C "$HW_DIR" merge --ff-only "origin/$HW_REPO_BRANCH"
else
    log "Cloning the hardware repo ($HW_REPO_BRANCH) into $HW_DIR"
    run_as_app git clone --branch "$HW_REPO_BRANCH" --single-branch "$HW_REPO_URL" "$HW_DIR"
fi
[[ -f "$HW_DIR/scripts/setup_pi.sh" ]] || \
    die "The $HW_REPO_BRANCH branch of the hardware repo does not contain scripts/setup_pi.sh."

log "Running the Supertext provisioning script"
POGO_APP_USER="$APP_USER" \
POGO_AP_PASSWORD="$POGO_AP_PASSWORD" \
POGO_SSID="${POGO_SSID:-POGOSupertext}" \
POGO_AP_CONNECTION="${POGO_AP_CONNECTION:-POGOSupertext}" \
POGO_WIFI_IF="${POGO_WIFI_IF:-wlan0}" \
    bash "$HW_DIR/scripts/setup_pi.sh"

# NetworkManager now holds the passphrase in its root-only connection profile
rm -f "$SECRETS_FILE"
unset POGO_AP_PASSWORD
install -d -m 0755 /var/lib/supertext
touch "$DONE_MARKER"

log "Provisioning succeeded. Rebooting so wlan0 can become the hotspot."
sync
systemctl reboot

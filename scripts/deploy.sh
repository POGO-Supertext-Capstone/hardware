#!/usr/bin/env bash
# deploy the latest origin/main to this Raspberry Pi
# use as the normal project user (NOT with sudo):   bash scripts/deploy.sh
# SKIP_TESTS=1 bash scripts/deploy.sh    skips 'go test' (e.g. a last-minute fix)
#
# while wlan0 is the Supertext hotspot the Pi has no internet, so use
# ethernet or a second Wi-Fi adapter for updates
#
# switches to main if needed, fast-forwards it, syncs the dnsmasq and
# systemd files if they changed, rebuilds build/supertext_server, restarts
# supertext.service, and rolls back to the previous executable if the new one
# does not come up
set -Eeuo pipefail

BINARY_NAME="supertext_server"
SERVICE_NAME="supertext.service"
APP_PORT=8081
DNSMASQ_SOURCE="config/dnsmasq/captive.conf"
SERVICE_TEMPLATE="systemd/supertext.service.in"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] || die "Run as the normal project user, without sudo."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HW_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APP_USER="$(id -un)"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"

# the application checkout: POGO_APP_DIR if set, otherwise wherever the
# installed service runs, otherwise ~/Supertext
APP_DIR="${POGO_APP_DIR:-}"
if [[ -z "$APP_DIR" ]]; then
    APP_DIR="$(systemctl show -p WorkingDirectory --value "$SERVICE_NAME" 2>/dev/null || true)"
fi
APP_DIR="${APP_DIR:-$APP_HOME/Supertext}"

[[ -d "$HW_DIR/.git" ]] || die "$HW_DIR is not a Git checkout."
[[ -d "$APP_DIR/.git" ]] || die "The application checkout $APP_DIR was not found. Run scripts/setup_pi.sh first, or set POGO_APP_DIR."
[[ -f "$HW_DIR/$DNSMASQ_SOURCE" && -f "$HW_DIR/$SERVICE_TEMPLATE" ]] || die "Missing $DNSMASQ_SOURCE or $SERVICE_TEMPLATE in $HW_DIR."
for tool in go git sudo curl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed. Run scripts/setup_pi.sh first."
done

# Go 1.27.4+ is required but debian packages an older Go so fetch the right toolchain
export GOTOOLCHAIN=auto


BUILD_TMP=""
SERVICE_NEW=""
cleanup() { rm -f "${BUILD_TMP:-}" "${SERVICE_NEW:-}"; }
trap cleanup EXIT

sync_repo() {
    local dir="$1" label="$2" current untracked
    git -C "$dir" remote get-url origin >/dev/null 2>&1 || die "$label: the checkout has no 'origin' remote."

    # don't discard work done directly on the Pi
    if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
        die "$label ($dir): tracked files have local modifications. Commit, stash, or save them before deploying."
    fi
    untracked="$(git -C "$dir" ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then
        warn "$label: untracked files will be left alone:"
        printf '%s\n' "$untracked" >&2
    fi

    log "Fetching $label (origin/main)"
    if ! git -C "$dir" fetch origin +refs/heads/main:refs/remotes/origin/main; then
        die "Could not reach GitHub. While wlan0 is the Supertext hotspot the Pi has no internet; connect Ethernet or a second Wi-Fi adapter and retry."
    fi

    current="$(git -C "$dir" branch --show-current)"
    if [[ "$current" != main ]]; then
        log "$label: switching from '${current:-detached HEAD}' to main"
        if git -C "$dir" show-ref --verify --quiet refs/heads/main; then
            git -C "$dir" checkout main
        else
            git -C "$dir" checkout -b main --track origin/main
        fi
    fi
    git -C "$dir" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true

    # fast-forward only, never overwrite local-only commits or merge a divergent branch
    git -C "$dir" merge-base --is-ancestor HEAD origin/main || \
        die "$label: local main has commits that are not on origin/main (or has diverged). Resolve that, then retry."
    git -C "$dir" merge --ff-only origin/main
}

sync_repo "$HW_DIR" "hardware repo"
sync_repo "$APP_DIR" "application repo"
[[ -f "$APP_DIR/go.mod" && -f "$APP_DIR/cmd/main.go" ]] || die "Expected go.mod and cmd/main.go were not found in $APP_DIR."

# check the system files now but install them later, after the new executable
# is in place, so a failure here changes nothing
log "Checking system configuration files"
DNSMASQ_SRC="$HW_DIR/$DNSMASQ_SOURCE"
DNSMASQ_LIVE="/etc/dnsmasq.d/captive.conf"
SERVICE_LIVE="/etc/systemd/system/$SERVICE_NAME"
DNSMASQ_CHANGED=0
SERVICE_CHANGED=0

if ! cmp -s "$DNSMASQ_SRC" "$DNSMASQ_LIVE"; then
    if ! DNSMASQ_CHECK="$(sudo dnsmasq --test --conf-file="$DNSMASQ_SRC" 2>&1)"; then
        die "New dnsmasq configuration failed its syntax check and was not installed: $DNSMASQ_CHECK"
    fi
    DNSMASQ_CHANGED=1
fi

SERVICE_NEW="$(mktemp)"
sed \
    -e "s|@APP_USER@|$APP_USER|g" \
    -e "s|@APP_DIR@|$APP_DIR|g" \
    -e "s|@APP_HOME@|$APP_HOME|g" \
    "$HW_DIR/$SERVICE_TEMPLATE" > "$SERVICE_NEW"
if ! cmp -s "$SERVICE_NEW" "$SERVICE_LIVE"; then
    SERVICE_CHANGED=1
fi

cd "$APP_DIR"

log "Downloading Go modules"
go mod download

if [[ "${SKIP_TESTS:-0}" == 1 ]]; then
    warn "SKIP_TESTS=1: not running go test"
else
    log "Running tests"
    go test ./...
fi

log "Building build/$BINARY_NAME"
install -d -m 0755 build
BUILD_TMP="$APP_DIR/build/$BINARY_NAME.new.$$"
go build -o "$BUILD_TMP" ./cmd
chmod 0755 "$BUILD_TMP"

LIVE="$APP_DIR/build/$BINARY_NAME"
PREV="$LIVE.prev"
rm -f "$PREV"
[[ ! -f "$LIVE" ]] || cp -p "$LIVE" "$PREV"
mv -f "$BUILD_TMP" "$LIVE"
BUILD_TMP=""

if [[ "$DNSMASQ_CHANGED" -eq 1 ]]; then
    log "Installing updated dnsmasq configuration"
    sudo install -m 0644 "$DNSMASQ_SRC" "$DNSMASQ_LIVE"
    sudo systemctl restart dnsmasq || die "dnsmasq failed to restart. See: journalctl -u dnsmasq"
fi
if [[ "$SERVICE_CHANGED" -eq 1 ]]; then
    log "Installing updated $SERVICE_NAME"
    sudo install -m 0644 "$SERVICE_NEW" "$SERVICE_LIVE"
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
fi

wait_until_healthy() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet "$SERVICE_NAME" && \
           curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$APP_PORT/" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

log "Restarting $SERVICE_NAME"
RESTART_OK=1
sudo systemctl restart "$SERVICE_NAME" || RESTART_OK=0
if [[ "$RESTART_OK" -ne 1 ]] || ! wait_until_healthy; then
    warn "$SERVICE_NAME is not healthy after the restart."
    sudo systemctl --no-pager --full status "$SERVICE_NAME" || true
    sudo journalctl -u "$SERVICE_NAME" -n 60 --no-pager || true
    if [[ -f "$PREV" ]]; then
        warn "Rolling back to the previous executable."
        mv -f "$PREV" "$LIVE"
        sudo systemctl restart "$SERVICE_NAME" || true
    fi
    die "Deployment failed; see the log above."
fi
rm -f "$PREV"

log "Deployment successful"
printf 'Hardware repo:  %s\nApplication:    %s (%s)\nExecutable:     %s\n' \
    "$(git -C "$HW_DIR" rev-parse --short HEAD)" \
    "$(git -C "$APP_DIR" rev-parse --short HEAD)" "$APP_DIR" "$LIVE"

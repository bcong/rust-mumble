#!/usr/bin/env bash
#
# One-click installer for rust-mumble (Zumble) as a systemd service.
#
# Usage:
#   cd rust-mumble          # repo root (where Cargo.toml lives)
#   chmod +x scripts/install.sh
#   sudo ./scripts/install.sh
#
# Safe to re-run: it rebuilds the binary, re-applies the systemd unit, and
# generates a brand new random HTTP admin password every time it runs.
#
# All defaults can be overridden with environment variables, e.g.:
#   LISTEN_ADDR=0.0.0.0:64738 HTTP_LISTEN_ADDR=0.0.0.0:9090 sudo -E ./scripts/install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars before running the script)
# ---------------------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-mumble}"
INSTALL_DIR="${INSTALL_DIR:-/opt/rust-mumble}"
BIN_NAME="rust-mumble"
SERVICE_NAME="rust-mumble"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:64738}"
HTTP_LISTEN_ADDR="${HTTP_LISTEN_ADDR:-0.0.0.0:47624}"
HTTP_USER="${HTTP_USER:-admin}"
UDP_BUFFER_BYTES=8388608   # matches UDP_SOCKET_BUFFER_SIZE in src/server/constants.rs

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Please run as root, e.g.: sudo ./scripts/install.sh"
[[ -f Cargo.toml ]] || die "Run this from the root of the rust-mumble repo (Cargo.toml not found in $(pwd))"

# ---------------------------------------------------------------------------
# 1. Build toolchain prerequisites
# ---------------------------------------------------------------------------
if ! command -v cargo &>/dev/null; then
    log "Rust toolchain not found, installing via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
fi

if command -v apt-get &>/dev/null; then
    log "Installing build prerequisites (build-essential, clang, llvm, pkg-config)..."
    apt-get update -qq
    apt-get install -y -qq build-essential clang llvm pkg-config >/dev/null
else
    warn "Non-apt system detected, skipping automatic prerequisite install."
    warn "Make sure a C compiler, make, and llvm are already installed (see README)."
fi

# ---------------------------------------------------------------------------
# 2. Build
# ---------------------------------------------------------------------------
log "Building release binary (this can take a few minutes)..."
cargo build --release

BIN_PATH="target/release/${BIN_NAME}"
[[ -x "$BIN_PATH" ]] || die "Build finished but ${BIN_PATH} wasn't found - check the build output above."

# ---------------------------------------------------------------------------
# 3. System user + install dir
# ---------------------------------------------------------------------------
if ! id -u "$SERVICE_USER" &>/dev/null; then
    log "Creating service user '${SERVICE_USER}'..."
    NOLOGIN_SHELL="$(command -v nologin || echo /usr/sbin/nologin)"
    useradd -r -s "$NOLOGIN_SHELL" "$SERVICE_USER"
fi

log "Installing binary to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
# Only the binary itself is copied (not the whole target/release/ tree) - the
# rest is build cache/intermediate objects (deps/, build/, incremental/) the
# running service never needs and would just waste disk space.
cp -f "$BIN_PATH" "$INSTALL_DIR/$BIN_NAME"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR/$BIN_NAME"

# ---------------------------------------------------------------------------
# 4. Generate a random HTTP admin password.
#    Length is randomized (20-32 chars), charset is alphanumeric only so it's
#    safe to embed directly in the systemd unit file - no quoting issues and
#    no risk of hitting systemd's '%' specifier expansion.
#
#    NOTE on the pipeline below: we intentionally do NOT truncate with
#    `head -c N` on the *output* side of `tr`, because if `tr` is still
#    producing output when a downstream `head -c N` hits its limit and closes
#    the pipe early, `tr` gets SIGPIPE and (with `pipefail`) can abort the
#    whole script. Reading a large-but-fixed slice from /dev/urandom up front
#    (which `head` naturally reads and exits its own accord) and then trimming
#    with a plain bash substring expansion avoids that race entirely.
# ---------------------------------------------------------------------------
PASSWORD_LENGTH=$(( (RANDOM % 13) + 20 ))
RANDOM_POOL=$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9')
HTTP_PASSWORD="${RANDOM_POOL:0:$PASSWORD_LENGTH}"
[[ ${#HTTP_PASSWORD} -eq $PASSWORD_LENGTH ]] || die "Failed to generate a random password"

# ---------------------------------------------------------------------------
# 5. Kernel tuning for UDP burst traffic (matches the 8MB SO_RCVBUF/SO_SNDBUF
#    the server requests at startup - without this, the kernel silently caps
#    the request back down to the distro default, ~208KB on most distros).
# ---------------------------------------------------------------------------
if command -v sysctl &>/dev/null; then
    log "Raising kernel UDP buffer limits (net.core.rmem_max/wmem_max)..."
    cat > /etc/sysctl.d/99-rust-mumble.conf <<EOF
net.core.rmem_max=${UDP_BUFFER_BYTES}
net.core.wmem_max=${UDP_BUFFER_BYTES}
EOF
    sysctl --system >/dev/null
else
    warn "sysctl not found, skipping kernel UDP buffer tuning."
fi

# ---------------------------------------------------------------------------
# 6. systemd unit
# ---------------------------------------------------------------------------
log "Writing systemd unit /etc/systemd/system/${SERVICE_NAME}.service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=rust-mumble voice server for pma-voice
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
LimitNOFILE=65536
ExecStart=${INSTALL_DIR}/${BIN_NAME} --listen ${LISTEN_ADDR} --http-listen ${HTTP_LISTEN_ADDR} --http-user ${HTTP_USER} --http-password ${HTTP_PASSWORD}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Credentials also get a root-only copy on disk so they're not lost if this
# terminal's scrollback disappears or the session closes.
CREDENTIALS_FILE="${INSTALL_DIR}/.http_credentials"
cat > "$CREDENTIALS_FILE" <<EOF
http_user=${HTTP_USER}
http_password=${HTTP_PASSWORD}
EOF
chown root:root "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"

# ---------------------------------------------------------------------------
# 7. Enable + start
# ---------------------------------------------------------------------------
log "Reloading systemd and starting the service..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

sleep 2

# ---------------------------------------------------------------------------
# 8. Verify
# ---------------------------------------------------------------------------
log "Verifying service state..."
if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    warn "Service is not active - showing recent logs:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 30
    die "${SERVICE_NAME} failed to start, see logs above."
fi

UDP_PORT="${LISTEN_ADDR##*:}"
if command -v ss &>/dev/null; then
    if ss -tulnp 2>/dev/null | grep -q ":${UDP_PORT} "; then
        log "Port ${UDP_PORT} is listening."
    else
        warn "Could not confirm port ${UDP_PORT} is listening yet (it may still be starting up)."
    fi
fi

HTTP_PORT="${HTTP_LISTEN_ADDR##*:}"
STATUS_CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "${HTTP_USER}:${HTTP_PASSWORD}" "http://127.0.0.1:${HTTP_PORT}/status" || echo "000")
if [[ "$STATUS_CODE" == "200" ]]; then
    log "HTTP status endpoint responded 200 OK."
else
    warn "HTTP status endpoint returned '${STATUS_CODE}' (expected 200) - check 'journalctl -u ${SERVICE_NAME}'."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo " rust-mumble installed and running as a systemd service"
echo "================================================================"
echo " Service name     : ${SERVICE_NAME}"
echo " Binary           : ${INSTALL_DIR}/${BIN_NAME}"
echo " Voice (tcp/udp)  : ${LISTEN_ADDR}"
echo " HTTP admin api   : http://<server-ip>:${HTTP_PORT}"
echo " HTTP admin user  : ${HTTP_USER}"
echo " HTTP admin pass  : ${HTTP_PASSWORD}"
echo " Saved also at    : ${CREDENTIALS_FILE} (root-only, chmod 600)"
echo "================================================================"
echo " Manage with:"
echo "   systemctl status ${SERVICE_NAME}"
echo "   journalctl -u ${SERVICE_NAME} -f"
echo "================================================================"

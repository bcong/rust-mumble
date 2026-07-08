#!/usr/bin/env bash
#
# One-click installer for mumble_exporter as a systemd service.
#
# mumble_exporter (https://github.com/mguentner/mumble_exporter) is a small
# Prometheus "blackbox" exporter for Mumble-protocol voice servers: it sends
# the standard anonymous UDP "server list ping" packet to a mumble server and
# exposes the reply as Prometheus metrics - connected user count and
# round-trip latency - for Grafana dashboards. It needs no login/credentials
# to talk to the mumble server (same mechanism the official client's server
# browser uses), and rust-mumble already answers this ping correctly.
#
# Usage:
#   chmod +x scripts/install-exporter.sh
#   sudo ./scripts/install-exporter.sh
#
# Safe to re-run: if mumble_exporter.service is already installed AND healthy
# (unit present, service active, HTTP endpoint responding), this exits
# immediately without changing anything. Otherwise it (re)installs/repairs it.
#
# All defaults can be overridden with environment variables, e.g.:
#   MUMBLE_TARGET_ADDR=203.0.113.5:64738 EXPORTER_LISTEN_ADDR=0.0.0.0:8778 \
#       sudo -E ./scripts/install-exporter.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars before running the script)
# ---------------------------------------------------------------------------
SERVICE_NAME="mumble_exporter"
BIN_NAME="mumble_exporter"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/${BIN_NAME}}"
EXPORTER_VERSION="${EXPORTER_VERSION:-1.0.2}"
EXPORTER_LISTEN_ADDR="${EXPORTER_LISTEN_ADDR:-127.0.0.1:8778}"
GITHUB_REPO="mguentner/mumble_exporter"

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Please run as root, e.g.: sudo ./scripts/install-exporter.sh"

# All local health checks (idempotency check + post-install verification) hit
# 127.0.0.1 on the configured port rather than EXPORTER_LISTEN_ADDR verbatim,
# since that address may be 0.0.0.0 (a valid bind address but not always a
# valid connect-to target on every system).
EXPORTER_PORT="${EXPORTER_LISTEN_ADDR##*:}"
LOCAL_METRICS_BASE="http://127.0.0.1:${EXPORTER_PORT}"

# ---------------------------------------------------------------------------
# 1. Auto-detect which mumble server this exporter should probe, by reading
#    the --listen address out of an existing rust-mumble install (see
#    scripts/install.sh) on this same host, if present. Falls back to
#    127.0.0.1:64738 (or is fully overridable via MUMBLE_TARGET_ADDR) when
#    this exporter runs standalone or points at a remote server.
# ---------------------------------------------------------------------------
detect_mumble_target() {
    local unit_file="/etc/systemd/system/rust-mumble.service"
    local listen=""

    if [[ -f "$unit_file" ]]; then
        local exec_line
        exec_line=$(grep '^ExecStart=' "$unit_file" 2>/dev/null | head -n1 || true)
        if [[ -n "$exec_line" ]]; then
            # Tokenize on whitespace (not a PCRE lookbehind - grep -P isn't
            # guaranteed available everywhere) and take the value right after
            # a standalone "--listen" token, so "--http-listen" is never
            # mistaken for it.
            local prev="" token
            set -f
            for token in $exec_line; do
                if [[ "$prev" == "--listen" ]]; then
                    listen="$token"
                    break
                fi
                prev="$token"
            done
            set +f
        fi
    fi

    if [[ -n "$listen" ]]; then
        local host="${listen%:*}"
        local port="${listen##*:}"
        case "$host" in
            0.0.0.0|::|\[::\])
                echo "127.0.0.1:${port}"
                ;;
            *)
                echo "$listen"
                ;;
        esac
    else
        echo "127.0.0.1:64738"
    fi
}
MUMBLE_TARGET_ADDR="${MUMBLE_TARGET_ADDR:-$(detect_mumble_target)}"

# ---------------------------------------------------------------------------
# 2. Idempotency check - skip entirely if already installed and healthy.
# ---------------------------------------------------------------------------
already_installed_and_healthy() {
    [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || return 1
    [[ -x "$INSTALL_PATH" ]] || return 1
    systemctl is-active --quiet "${SERVICE_NAME}" || return 1

    # Any real HTTP response (200 = scrape ok, 504 = exporter up but target
    # currently unreachable) proves the exporter process itself is alive and
    # serving; "000" means curl couldn't even connect to it, so it's not
    # actually healthy no matter what systemd thinks its unit state is.
    local http_code
    http_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
        "${LOCAL_METRICS_BASE}/metrics?host=${MUMBLE_TARGET_ADDR}" 2>/dev/null || echo "000")
    [[ "$http_code" != "000" ]]
}

if already_installed_and_healthy; then
    log "mumble_exporter is already installed and healthy - skipping (re)install."
    log "Metrics URL: ${LOCAL_METRICS_BASE}/metrics?host=${MUMBLE_TARGET_ADDR}"
    exit 0
fi

log "Installing mumble_exporter ${EXPORTER_VERSION}..."

# ---------------------------------------------------------------------------
# 3. Detect architecture and download the matching release binary.
# ---------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64|amd64)  GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    armv7l)        GOARCH="armv7" ;;
    armv6l)        GOARCH="armv6" ;;
    *) die "Unsupported architecture '$(uname -m)' - no prebuilt mumble_exporter release available for it." ;;
esac

TARBALL="mumble_exporter_${EXPORTER_VERSION}_linux_${GOARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${EXPORTER_VERSION}/${TARBALL}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

log "Downloading ${DOWNLOAD_URL}..."
curl -fsSL "$DOWNLOAD_URL" -o "${WORKDIR}/${TARBALL}" || die "Failed to download ${DOWNLOAD_URL}"

log "Extracting..."
tar -xzf "${WORKDIR}/${TARBALL}" -C "$WORKDIR"
[[ -f "${WORKDIR}/${BIN_NAME}" ]] || die "Extracted archive did not contain a '${BIN_NAME}' binary."

install -m 0755 "${WORKDIR}/${BIN_NAME}" "$INSTALL_PATH"
log "Installed binary to ${INSTALL_PATH}"

# ---------------------------------------------------------------------------
# 4. systemd unit. DynamicUser=true gives the process an ephemeral,
#    unprivileged, kernel-managed UID with no persistent state or home
#    directory - this exporter is a stateless network prober, so it needs
#    nothing else (no manual service-user creation, unlike rust-mumble
#    itself which owns files under /opt/rust-mumble).
# ---------------------------------------------------------------------------
log "Writing systemd unit /etc/systemd/system/${SERVICE_NAME}.service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Prometheus blackbox exporter for Mumble voice server metrics (connection count + latency)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} --listenAddress ${EXPORTER_LISTEN_ADDR} --metricsPath /metrics
DynamicUser=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 5. Enable + start
# ---------------------------------------------------------------------------
log "Reloading systemd and starting the service..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

sleep 2

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
log "Verifying service state..."
if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    warn "Service is not active - showing recent logs:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 30
    die "${SERVICE_NAME} failed to start, see logs above."
fi

HTTP_CODE=$(curl -s -o "${WORKDIR}/verify_response" -m 5 -w '%{http_code}' \
    "${LOCAL_METRICS_BASE}/metrics?host=${MUMBLE_TARGET_ADDR}" 2>/dev/null || echo "000")
case "$HTTP_CODE" in
    200)
        log "Metrics endpoint responded 200 OK - scraping ${MUMBLE_TARGET_ADDR} works end-to-end."
        ;;
    504)
        warn "Exporter is up but couldn't reach mumble server at ${MUMBLE_TARGET_ADDR} yet (HTTP 504)."
        warn "Confirm the mumble server is running and reachable on that address/port, or re-run with MUMBLE_TARGET_ADDR=host:port."
        ;;
    000)
        die "Could not connect to the exporter's own HTTP endpoint at all - check 'journalctl -u ${SERVICE_NAME}'."
        ;;
    *)
        warn "Metrics endpoint returned unexpected HTTP ${HTTP_CODE} - check 'journalctl -u ${SERVICE_NAME}'."
        ;;
esac

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo " mumble_exporter installed and running as a systemd service"
echo "================================================================"
echo " Service name      : ${SERVICE_NAME}"
echo " Binary            : ${INSTALL_PATH}"
echo " Exporter endpoint : http://${EXPORTER_LISTEN_ADDR}/metrics"
echo " Scrape target     : ${MUMBLE_TARGET_ADDR}"
echo " Credentials       : none required (anonymous UDP ping probe, no password)"
echo "================================================================"
echo " Add this job to prometheus.yml to scrape it:"
echo
echo "   scrape_configs:"
echo "     - job_name: 'mumble'"
echo "       scrape_interval: 30s"
echo "       static_configs:"
echo "         - targets: ['${MUMBLE_TARGET_ADDR}']"
echo "       relabel_configs:"
echo "         - source_labels: [__address__]"
echo "           target_label: __param_host"
echo "         - source_labels: [__param_host]"
echo "           target_label: instance"
echo "         - target_label: __address__"
echo "           replacement: '${EXPORTER_LISTEN_ADDR}'"
echo "================================================================"
echo " Metrics exposed (build Grafana panels off these):"
echo "   mumble_current_users        - currently connected users"
echo "   mumble_max_users             - configured server user limit"
echo "   mumble_latency_microseconds  - UDP ping round-trip latency"
echo "================================================================"
echo " Manage with:"
echo "   systemctl status ${SERVICE_NAME}"
echo "   journalctl -u ${SERVICE_NAME} -f"
echo "================================================================"

# Zumble

A mumble server for FiveM.

Goal is to have an external server handling voice chat for FiveM servers instead of using the built-in voice chat.

**This is a work in progress. Use it at your own risk.**

## Features

- 100% compatible with FiveM -> drop in replacement for client natives
- Http api to mimic server side native calls (MumbleIsPlayerMuted / MumbleSetPlayerMuted / MumbleCreateChannel)
- Performance (multithreaded server, separated from game network)
- Can be installed on a separate machine
- prometheus metrics

## Installation

1.  Clone this repository
2.  If you're on Linux your system needs to have `llvm` and `make` installed
3.  Build the server using cargo: `cargo build --release`

Future versions will include pre-built binaries in release section of GitHub.

### One-click systemd install (Linux)

For a production deployment as a systemd service, use the installer scripts under `scripts/`. Both are safe to re-run (idempotent) and print any generated credentials at the end.

```bash
# Builds rust-mumble, creates a dedicated service user, tunes UDP kernel
# buffers, generates a random HTTP admin password, and installs+starts it
# as the "rust-mumble" systemd service.
sudo ./scripts/install.sh

# Installs mumble_exporter (https://github.com/mguentner/mumble_exporter), a
# Prometheus exporter that feeds Grafana with connection-count and latency
# metrics scraped from this server. No credentials needed. Automatically
# skips if already installed and healthy - safe to run across a whole fleet.
sudo ./scripts/install-exporter.sh
```

## Usage

NOTE: This might be out of date, you can run the binary with `--help` to view the most up to date version.

```
Usage: rust-mumble [OPTIONS]

Options:
      --help

  -l, --listen <LISTEN>
          Listen address for TCP and UDP connections for mumble voip clients (or other clients that support the mumble protocol) [default: 0.0.0.0:64738]
  -h, --http-listen <HTTP_LISTEN>
          Listen address for HTTP connections for the admin api [default: 0.0.0.0:47624]
      --http-user <HTTP_USER>
          User for the http server api basic authentification [default: admin]
      --http-password <HTTP_PASSWORD>
          Password for the http server api basic authentification
      --https
          Use TLS for the http server (https), will use the same certificate as the mumble server
      --http-log
          Log http requests to stdout
      --key <KEY>
          Path to the key file for the TLS certificate [default: key.pem]
      --cert <CERT>
          Path to the certificate file for the TLS certificate [default: cert.pem]
  -V, --version
          Print version
```

## Credits

- [mumble-protocol](https://github.com/Johni0702/rust-mumble-protocol) for the crypt / decrypt algorithm of the mumble protocol, it was rewritten here to work on pure rust library (no openssl)

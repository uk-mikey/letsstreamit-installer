#!/bin/sh
# LetsStreamIt — one-line installer
#
#   curl -fsSL https://onair.letsstreamit.com/install.sh | sh
#   curl -fsSL https://onair.letsstreamit.com/install.sh | sudo sh -s -- update
#   curl -fsSL https://onair.letsstreamit.com/install.sh | UNINSTALL=yes sh -s -- uninstall
#
# The same script is also published on GitHub, as the backup install for when the
# primary domain does not answer:
#   curl -fsSL https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh | sudo sh
#
# Bundles: PostgreSQL · Icecast2 · Icecast KH (built from source) ·
#          Rocket Streaming Audio Server (RSAS) · HLS audio (Icecast origin + ffmpeg) ·
#          Liquidsoap · Shoutcast DNAS 2 · Shoutcast DNAS 1.9.8 (legacy, 32-bit) ·
#          MediaMTX, SRS, Red5 Free and NGINX RTMP (live video) · ffmpeg · nginx · Node.js 20+ (npm)
# Optional: Red5 Free (live video) is the open-source RTMP server installed into
#           /opt/red5 and bridged to HLS with ffmpeg. Red5 Pro is licensed; it is
#           installed only when RED5_ARCHIVE_URL points at an archive you
#           downloaded from red5.net.
# Provisions the database, builds the app, starts the panel (systemd unit when
# available, background + log otherwise) and waits until /setup responds, so the
# setup page loads as soon as the script finishes.
#
# Modes:
#   install (default)   full, idempotent install
#   update              refresh source, reinstall deps, rebuild, restart panel,
#                       and re-check the downloaded engines (both Shoutcast
#                       binaries, Icecast KH, RSAS and SRS)
#   uninstall           stop the panel + engines, drop the database and delete the
#                       data/app directories. Without UNINSTALL=yes it only prints
#                       the plan; combine with DRY_RUN=1 to preview every action.
#
# Overrides:
#   APP_DIR=/srv/letsstreamit   app source location (default: $PWD; a local copy
#                               at /root/letsstreamit is used as a fallback)
#   SOURCE_URL=https://…        source tarball to download & unpack into APP_DIR
#                               (default: https://onair.letsstreamit.com/source —
#                               the panel serves its own source, no git involved;
#                               the Freebuff host serves the same tarball and is
#                               used automatically when the primary one fails)
#   MANIFEST_URL=https://…      hosted manifest to install/update from — its
#                               source URL and version are used, so a self-hosted
#                               feed needs no SOURCE_URL. Every panel serves its
#                               own at /hosted.manifest.json (or /api/version).
#   INSTALL_REPORT=0            opt out of the install counter. After a successful
#                               install or update the script posts this server's
#                               domain, panel version and public IP to the hosted
#                               install ledger at
#                               https://trustworthy-chameleon-50.convex.site/install/report,
#                               which feeds Admin → Overview on letsstreamit.com.
#                               No station, user, listener or media data is sent.
#                               The run prints a short server code for support.
#   INSTALL_REPORT_URL=https://…  override the report endpoint (testing, or a
#                               different central ledger).
#   PANEL_PORT=3000             port the panel listens on internally
#   PANEL_PORTS=3000            which ports the panel answers on, decided up
#                               front. Beside the internal PANEL_PORT the panel
#                               can serve port 80 itself, which is what a host
#                               whose provider blocks 3000 needs, and port 443,
#                               which is the only way its own domain answers over
#                               https when no proxy is in front:
#                                 3000           — the panel's own port (default)
#                                 80+3000        — also answer on port 80 (the
#                                                  panel starts a second listener
#                                                  on it; this unit runs as root,
#                                                  which port 80 needs). 80 alone
#                                                  means the same thing: nothing
#                                                  here closes a port.
#                                 80+443+3000    — the same, plus https on port
#                                                  443 from the panel itself, with
#                                                  the certificate issued in
#                                                  Admin → SSL. It needs that
#                                                  certificate first: with none
#                                                  issued, port 443 says so and the
#                                                  rest keeps working. 443 alone
#                                                  means the same thing.
#                               Whichever is chosen, the installer opens the port
#                               on the host firewall and stops nginx if it is
#                               holding one of them.
#                               It is only the default: the setup wizard asks the
#                               same question (and Admin → Server settings can
#                               change it afterwards), and the answer made there
#                               is stored in the database and wins over this.
#   PROXY_MODE=none             how the panel is exposed. Providers that only
#                               allow 80/443 need one of the proxy modes (or
#                               PANEL_PORTS=80+3000 / 80+443+3000, which needs
#                               nothing else):
#                                 none  — serve directly on PANEL_PORT (default)
#                                 nginx — nginx (installed by every install) listens
#                                         on port 80 and proxies to the panel
#                                         (HTTP; no certs issued)
#                                 caddy — Caddy listens on 80/443, proxies to the
#                                         panel and issues a Let's Encrypt cert
#                                         automatically (needs a real domain in
#                                         DOMAIN, ports 80+443 reachable)
#                                 tunnel— Cloudflare Tunnel (cloudflared) dials
#                                         out to Cloudflare, so the panel is
#                                         reachable with NO inbound port open at
#                                         all. Needs TUNNEL_TOKEN from the
#                                         Cloudflare Zero Trust dashboard and a
#                                         hostname in DOMAIN.
#   DOMAIN=radio.example.com    hostname used by PROXY_MODE=nginx|caddy|tunnel and
#                               by the HTTPS stream links (else the server IP)
#   TUNNEL_TOKEN=eyJ…           Cloudflare Tunnel token (required for tunnel mode)
#   TUNNEL_URL=https://…        public URL the tunnel serves (optional; shown in
#                               the summary when set)
#   VIDEO_RTMP_PORT=1935         MediaMTX RTMP ingest port DJs publish to with OBS
#   SRS_RTMP_PORT=1936           SRS RTMP ingest port (the two engines can run
#                                side by side, so they use different ports)
#   SRS_VERSION=6.0-r3           SRS release to download (the official x86_64
#                                prebuilt; SRS is skipped on other architectures)
#   SRS_BIN=/usr/local/bin/srs   binary the panel runs; set SRS_BIN in the
#                                panel too when this is moved
#   RED5_FREE_HOME=/opt/red5      official open-source Red5 server (RTMP-only; the
#                                panel bridges it to HLS with ffmpeg)
#   RED5_FREE_VERSION=2.0.53     open-source Red5 release to download
#   RED5_FREE_ARCHIVE_URL=https://…  override the Red5 Free release tarball
#   RED5_FREE_RTMP_PORT=1939      Red5 Free RTMP ingest port DJs publish to with OBS
#   RED5_FREE_HTTP_PORT=5082      Red5 Free HTTP listener; loopback-only
#   RED5_HOME=/usr/local/red5pro optional licensed Red5 Pro distribution (it must contain
#                                red5.sh and LICENSE.KEY; the panel reads the same
#                                variable)
#   RED5_ARCHIVE_URL=https://…|/path/to/red5pro.zip
#                                optional licensed Red5 Pro .zip to unpack there.
#                                Accepts a URL, a local path or file://. The
#                                server is commercial and the archive is not
#                                public: download it from red5.net and pass its
#                                location (or leave this unset and install it
#                                yourself)
#   RED5_RTMP_PORT=1937           Red5 Pro RTMP ingest port DJs publish to with OBS
#   RED5_HTTP_PORT=5081           Red5 Pro HTTP/HLS/API listener; loopback-only
#   NGINX_BIN=/usr/sbin/nginx     nginx binary with the RTMP module
#   NGINX_RTMP_MODULE=…           explicit ngx_rtmp_module.so; the installer
#                                 finds the distro package's module by default
#   NGINX_RTMP_PORT=1938          NGINX RTMP ingest port DJs publish to with OBS
#   NGINX_HLS_PORT=8089           NGINX RTMP HLS listener; loopback-only
#   STATION_PORT_MIN=8000        the ports stations are allocated (the panel's
#   STATION_PORT_MAX=8999        own default — Admin → Server settings → Station
#                                port range). DJs publish to a station's port and
#                                the tune-in links hand listeners the engine's own
#                                port, so the range is opened on the host firewall.
#                                If you change the range in the panel later, re-run
#                                with these values (or run the command its own port
#                                check prints).
#   OPEN_FTP=1                   open FTP's ports on the host firewall too: the
#                                control port and the passive range a transfer
#                                makes its data connection on. 0 skips both — the
#                                panel's FTP listener is off until it is switched on
#                                in Admin → Server settings, and when enabled it binds
#                                all interfaces (set FTP_BIND=127.0.0.1 to keep it local),
#                                so opening these ports is enough for remote clients.
#   FTP_PORT=2121                the panel's FTP control port (settings key
#   FTP_PASSIVE_MIN=21100        ftp_port), and the passive range it hands out
#   FTP_PASSIVE_MAX=21110        (ftp_passive_min/max). Only the firewall rules
#                                use these: the listener reads its own settings.
#   OPEN_FIREWALL=1              0 leaves the host firewall alone entirely — for a
#                                host whose rules are managed elsewhere (Ansible,
#                                Terraform, a cloud-init script). The summary then
#                                names the ports to allow by hand.
#   SC1_URL=https://…           tarball holding the legacy Shoutcast DNAS 1.9.8
#                               `sc_serv` (default: a mirror of the 2007 Nullsoft
#                               release, whose own download host is gone)
#   IKH_REF=icecast-2.4.0-kh22  Icecast KH release tag to build (default: the
#                               latest release of github.com/karlheyes/icecast-kh)
#   IKH_URL=https://…           full source archive for Icecast KH — overrides
#                               IKH_REF when both are set
#   RSAS_VERSION=1.0.7          Rocket Streaming Audio Server release
#   RSAS_URL=https://…          full RSAS Linux tarball — overrides RSAS_VERSION
#   RSAS_HOME=/opt/rsas         RSAS binary and web assets (RSAS_BIN defaults to
#                               $RSAS_HOME/rsas; the panel reads the same paths)
#   RSAS_BIN=/opt/rsas/rsas     binary the panel runs; set RSAS_WEBROOT in the
#                               panel too when RSAS_HOME is moved
#   SERVER_IP=1.2.3.4           address shown in the setup URL (auto-detected
#                               from the host / a public-IP lookup otherwise)
#   SMTP_HOST=smtp.example.com  outbound mail (optional). With SMTP_HOST set the
#                               installer writes SMTP_PORT (587), SMTP_USER,
#                               SMTP_PASS, SMTP_SECURE and EMAIL_FROM into
#                               <APP_DIR>/.env.local; without it the panel logs
#                               mail instead, and the same settings can be filled
#                               in later at Admin → Server settings → Email.
#   SKIP_BUILD=1                skip `npm run build`
#   DRY_RUN=1                   print actions instead of running them

set -eu

APP_DIR_EXPLICIT="${APP_DIR:-}"
APP_DIR="${APP_DIR:-$PWD}"
SOURCE_URL="${SOURCE_URL:-}"
DEFAULT_SOURCE_URL="https://onair.letsstreamit.com/source"
# The same tarball, from a second host. Only reached when a download from
# DEFAULT_SOURCE_URL fails and the operator did not name a SOURCE_URL of their
# own — an address they typed is theirs to fix, not ours to route around.
BACKUP_SOURCE_URL="https://letsstreamit.freebuff.app/source"
# The install commands this script prints: primary first, backup after it.
INSTALL_URL="https://onair.letsstreamit.com/install.sh"
# The backup is the GitHub mirror, which carries the script only — the source
# tarball keeps its own second host in BACKUP_SOURCE_URL below.
BACKUP_INSTALL_URL="https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh"
# A hosted manifest (src/lib/hosted-manifest.ts) can supply the source URL and the
# version being installed; an explicit SOURCE_URL always wins over it.
MANIFEST_URL="${MANIFEST_URL:-}"
SOURCE_GIVEN=0
if [ -n "$SOURCE_URL" ]; then SOURCE_GIVEN=1; fi
MANIFEST_VERSION=""
MANIFEST_SOURCE=""
MANIFEST_UPDATE=""
# The install counter: one report per install/update, deduplicated by the id in
# <APP_DIR>/.install-id. On by default; INSTALL_REPORT=0 is the opt-out.
INSTALL_REPORT="${INSTALL_REPORT:-1}"
INSTALL_REPORT_URL="${INSTALL_REPORT_URL:-https://trustworthy-chameleon-50.convex.site/install/report}"
DRY_RUN="${DRY_RUN:-0}"
UNINSTALL="${UNINSTALL:-no}"
SKIP_BUILD="${SKIP_BUILD:-0}"
PANEL_PORT="${PANEL_PORT:-3000}"
PANEL_PORTS="${PANEL_PORTS:-3000}"
SERVER_IP="${SERVER_IP:-}"
PROXY_MODE="${PROXY_MODE:-none}"
DOMAIN="${DOMAIN:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TUNNEL_URL="${TUNNEL_URL:-}"
DB_USER="app"
DB_NAME="letsstreamit"
# Two Shoutcast servers, two directories — the panel probes both
# (BIN.shoutcast / BIN.shoutcast1 in src/lib/streams.ts). SC_URL is DNAS 2, the
# x86_64 build; SC1_URL is the 2007 DNAS 1.9.8, a 32-bit i386 ELF that also needs
# 32-bit glibc. The original nullsoft download host 404s these days, so the
# legacy one comes from a mirror of those tools (verified: 60,840-byte tarball
# with `sc_serv`, `sc_serv.conf` and `README.TXT` at the top level).
SC_URL="http://download.nullsoft.com/shoutcast/tools/sc_serv2_linux_x64-latest.tar.gz"
SC_DIR="/opt/shoutcast"
SC1_URL="${SC1_URL:-https://mirror.lchost.net/download.nullsoft.com/shoutcast/tools/sc_serv_1.9.8_Linux.tar.gz}"
SC1_DIR="/opt/shoutcast1"
# The 1.9.8 tarball's sc_serv has PT_INTERP=/lib/ld-linux.so.2 (verified with
# `file` and `readelf`). That exact path is what the kernel opens; checking a
# "compatible" 32-bit path would pass while the old binary still cannot start.
SC1_LOADER_PATH="/lib/ld-linux.so.2"
# Icecast KH — Karl Heyes' fork of Icecast 2, and the only engine here that no
# distribution packages: it is built from source into its own prefix so it can
# sit beside the distribution's Icecast 2, and probed at that path
# (BIN["icecast-kh"] in src/lib/streams.ts). The release archive ships a
# generated `configure`, so autotools is not needed. IKH_REF picks the tag and
# IKH_URL replaces the whole archive URL — the value shown in the header docs.
IKH_REF="${IKH_REF:-icecast-2.4.0-kh22}"
IKH_URL="${IKH_URL:-https://github.com/karlheyes/icecast-kh/archive/refs/tags/$IKH_REF.tar.gz}"
IKH_DIR="/opt/icecast-kh"
# Rocket Streaming Audio Server (RSAS) — Rocket Broadcaster's official Linux
# build is a static x86_64 tarball. It is unpacked into its own prefix so the
# panel can probe it (BIN.rsas in src/lib/streams.ts) without a package or a
# system service. The release keeps its status templates beside webroot, which
# is what `<webroot>/../templates` in RSAS's status renderer expects.
RSAS_VERSION="${RSAS_VERSION:-1.0.7}"
RSAS_URL="${RSAS_URL:-https://www.rocketbroadcaster.com/streaming-audio-server/downloads/ubuntu-14.04/rsas-$RSAS_VERSION-linux_amd64.tar.gz}"
RSAS_HOME="${RSAS_HOME:-/opt/rsas}"
RSAS_BIN="${RSAS_BIN:-$RSAS_HOME/rsas}"
RSAS_STATUS=""
MTX_VERSION="v1.21.1"
VIDEO_RTMP_PORT="${VIDEO_RTMP_PORT:-1935}"
SRS_VERSION="${SRS_VERSION:-6.0-r3}"
SRS_BIN="${SRS_BIN:-/usr/local/bin/srs}"
SRS_RTMP_PORT="${SRS_RTMP_PORT:-1936}"
RED5_HOME="${RED5_HOME:-/usr/local/red5pro}"
RED5_FREE_HOME="${RED5_FREE_HOME:-/opt/red5}"
RED5_FREE_VERSION="${RED5_FREE_VERSION:-2.0.53}"
RED5_FREE_ARCHIVE_URL="${RED5_FREE_ARCHIVE_URL:-https://github.com/Red5/red5-server/releases/download/v$RED5_FREE_VERSION/red5-server-$RED5_FREE_VERSION.tar.gz}"
RED5_FREE_RTMP_PORT="${RED5_FREE_RTMP_PORT:-1939}"
RED5_FREE_HTTP_PORT="${RED5_FREE_HTTP_PORT:-5082}"
RED5_ARCHIVE_URL="${RED5_ARCHIVE_URL:-}"
RED5_RTMP_PORT="${RED5_RTMP_PORT:-1937}"
RED5_HTTP_PORT="${RED5_HTTP_PORT:-5081}"
NGINX_BIN="${NGINX_BIN:-/usr/sbin/nginx}"
NGINX_RTMP_MODULE="${NGINX_RTMP_MODULE:-}"
NGINX_RTMP_PORT="${NGINX_RTMP_PORT:-1938}"
NGINX_HLS_PORT="${NGINX_HLS_PORT:-8089}"
# The ports the panel's own port check measures (src/lib/port-check.ts) and the
# defaults the panel holds for them (src/lib/settings.ts: port_min/port_max
# 8000/8999, ftp_port 2121, ftp_passive_min/max 21100/21110). Every one of them is
# opened on the host firewall below, so a fresh install does not finish with rows
# reading "not allowed through the host firewall".
STATION_PORT_MIN="${STATION_PORT_MIN:-8000}"
STATION_PORT_MAX="${STATION_PORT_MAX:-8999}"
OPEN_FTP="${OPEN_FTP:-1}"
FTP_PORT="${FTP_PORT:-2121}"
FTP_PASSIVE_MIN="${FTP_PASSIVE_MIN:-21100}"
FTP_PASSIVE_MAX="${FTP_PASSIVE_MAX:-21110}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
# What the host firewall ended up with, for the summary at the end ("" when
# nothing was attempted). Set by open_firewall().
FIREWALL_LINE=""
PANEL_PID_FILE="$APP_DIR/panel.pid"
PANEL_LOG="$APP_DIR/panel.log"
NODE_BIN=""
NPM_BIN=""
NODE_MIN_MAJOR="20"

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
# No leading '!': a warning line that starts with '!' is negated when pasted
# into a shell, so "! … && npm …" would chain and RUN the npm part. With a
# plain word first, a pasted warning just fails as an unknown command and the
# '&&' chain never executes.
warn() { printf '    warning: %s\n' "$*" >&2; }
die()  { printf '    ERROR: %s\n' "$*" >&2; exit 1; }

# Run a shell command — echoed instead of executed under DRY_RUN=1.
x() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    $ %s\n' "$*"
  else
    sh -c "$*"
  fi
}
# Best-effort: warn instead of aborting the install.
xb() { x "$*" || warn "optional step failed: $*"; }

# ---------------------------------------------------------------------------
# Hosted manifest (src/lib/hosted-manifest.ts)
#
# `MANIFEST_URL=… sh install.sh update` is the whole instruction: the manifest
# says which version this server should be, where its source tarball lives and
# the command that installs it, so a self-hoster points a machine at their own
# panel and updates from there. Values are pulled out with sed rather than jq —
# this runs on a machine the script has not provisioned yet.
# ---------------------------------------------------------------------------

# "key": "value" anywhere in the document (object collapsed to one line first,
# so a pretty-printed manifest reads the same as a compact one).
json_string() {
  tr -d '\n' < "$1" |
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
    head -n 1
}

# "object": { … "key": "value" … } — the nested form, so `source.url` is read
# from the source object and not from any other `url` in the document.
json_nested() {
  tr -d '\n' < "$1" |
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p" |
    sed -n "s/.*\"$3\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
    head -n 1
}

# ---------------------------------------------------------------------------
# Install counter
#
# Every install gets one random 32-hex id, persisted in <APP_DIR>/.install-id.
# `update` reuses it, so the central Admin → Overview counts machines, not curl
# runs. The report is best-effort and never affects the exit status: an
# unreachable ledger must not make a healthy install look failed. The ledger
# caps how many new rows it accepts; the server address is display data only.
# ---------------------------------------------------------------------------
install_id() {
  ID_FILE="$APP_DIR/.install-id"
  ID=""
  if [ -s "$ID_FILE" ]; then
    ID="$(tr -d '[:space:]' < "$ID_FILE" 2>/dev/null || true)"
  fi
  case "$ID" in
    *[!0-9a-f]*) ID="" ;;
  esac
  [ "${#ID}" -eq 32 ] || ID=""
  if [ -z "$ID" ] && command -v openssl >/dev/null 2>&1; then
    ID="$(openssl rand -hex 16 2>/dev/null || true)"
  fi
  if [ -z "$ID" ] && [ -r /dev/urandom ]; then
    ID="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  case "$ID" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#ID}" -eq 32 ] || return 1
  if [ ! -s "$ID_FILE" ] || [ "$(cat "$ID_FILE" 2>/dev/null || true)" != "$ID" ]; then
    TMP_ID="$(mktemp 2>/dev/null)" || return 1
    printf '%s\n' "$ID" > "$TMP_ID" || { rm -f "$TMP_ID"; return 1; }
    if [ -n "$SUDO" ]; then
      $SUDO mv "$TMP_ID" "$ID_FILE" 2>/dev/null || { rm -f "$TMP_ID"; return 1; }
    else
      mv "$TMP_ID" "$ID_FILE" 2>/dev/null || { rm -f "$TMP_ID"; return 1; }
    fi
  fi
  printf '%s' "$ID"
}

server_code() {
  printf 'LSS-%s' "$(printf '%s' "$1" | cut -c1-8 | tr 'a-f' 'A-F')"
}

report_install() {
  [ "${INSTALL_REPORT:-1}" = "0" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0

  ID="$(install_id)" || {
    info "Install tracking: skipped (could not save a server id in $APP_DIR)"
    return 0
  }
  CODE="$(server_code "$ID")"
  VERSION=""
  if [ -f "$APP_DIR/package.json" ]; then
    VERSION="$(json_string "$APP_DIR/package.json" version)"
  fi
  # The ledger validates again. Stripping now keeps the JSON well-formed even
  # if DOMAIN was set to a URL with a path. The public lookup is deliberate:
  # SERVER_IP is the panel's own address and is usually a private LAN address,
  # which the ledger drops rather than showing to an admin.
  REPORT_DOMAIN="$(printf '%s' "${DOMAIN:-}" | sed 's/[^A-Za-z0-9.-]//g' | cut -c1-253)"
  REPORT_LABEL="$REPORT_DOMAIN"
  if [ -z "$REPORT_LABEL" ] && command -v hostname >/dev/null 2>&1; then
    REPORT_LABEL="$(hostname 2>/dev/null | sed 's/[^A-Za-z0-9.-]//g' | cut -c1-253)"
  fi
  REPORT_IP=""
  if command -v curl >/dev/null 2>&1; then
    REPORT_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  REPORT_IP="$(printf '%s' "$REPORT_IP" | sed 's/[^0-9A-Fa-f:.]//g' | cut -c1-64)"
  case "$REPORT_IP" in
    *.*|*:*) ;;
    *) REPORT_IP="" ;;
  esac
  if [ -z "$REPORT_IP" ] && [ "${SERVER_IP:-}" != "<server>" ]; then
    REPORT_IP="$(printf '%s' "${SERVER_IP:-}" | sed 's/[^0-9A-Fa-f:.]//g' | cut -c1-64)"
  fi
  BODY="$(printf '{"fingerprint":"%s","label":"%s","version":"%s","ip":"%s"}' "$ID" "$REPORT_LABEL" "$VERSION" "$REPORT_IP")"

  if curl -fsS --max-time 8 -X POST -H 'Content-Type: application/json' \
      --data-binary "$BODY" "$INSTALL_REPORT_URL" </dev/null >/dev/null 2>&1; then
    info "Server code : $CODE (install tracking; INSTALL_REPORT=0 opts out)"
  else
    info "Install tracking: skipped (could not reach $INSTALL_REPORT_URL)"
  fi
}

read_manifest() {
  [ -n "$MANIFEST_URL" ] || return 0
  MANIFEST_FILE="$(mktemp)"
  if ! curl -fsSL --retry 2 -o "$MANIFEST_FILE" "$MANIFEST_URL" </dev/null; then
    warn "could not read the update manifest at $MANIFEST_URL — using SOURCE_URL as given"
    rm -f "$MANIFEST_FILE"
    return 0
  fi
  MANIFEST_VERSION="$(json_string "$MANIFEST_FILE" version)"
  MANIFEST_SOURCE="$(json_nested "$MANIFEST_FILE" source url)"
  if [ -z "$MANIFEST_SOURCE" ]; then
    # The short form an operator may hand-write: "source": "https://…/source.tar.gz"
    MANIFEST_SOURCE="$(json_string "$MANIFEST_FILE" source)"
  fi
  MANIFEST_UPDATE="$(json_nested "$MANIFEST_FILE" update command)"
  rm -f "$MANIFEST_FILE"

  if [ -n "$MANIFEST_VERSION" ]; then
    info "manifest: version $MANIFEST_VERSION${MANIFEST_SOURCE:+ · source $MANIFEST_SOURCE}"
  else
    warn "the manifest at $MANIFEST_URL has no version field — reading it as a plain feed"
  fi
  if [ -n "$MANIFEST_SOURCE" ] && [ "$SOURCE_GIVEN" != "1" ]; then
    SOURCE_URL="$MANIFEST_SOURCE"
    info "source from the manifest: $SOURCE_URL"
  fi
}

# What was installed, next to what the manifest said it would be. An update that
# quietly kept the old source is exactly the failure this catches.
report_version() {
  INSTALLED=""
  if [ -f "$APP_DIR/package.json" ]; then
    INSTALLED="$(json_string "$APP_DIR/package.json" version)"
  fi
  if [ -n "$INSTALLED" ]; then
    info "Version    : $INSTALLED${MANIFEST_VERSION:+ (manifest says $MANIFEST_VERSION)}"
  fi
  if [ -n "$MANIFEST_VERSION" ] && [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$MANIFEST_VERSION" ]; then
    warn "installed $INSTALLED but the manifest at $MANIFEST_URL advertises $MANIFEST_VERSION — check that its source URL points at that release"
  fi
}

# ---------------------------------------------------------------------------
# Stream engine binaries
#
# Icecast and Liquidsoap come from the package manager, but both Shoutcast
# servers are downloads, so they are functions: the install flow calls them in
# its own order, and `update` calls them as well. That matters for the legacy
# 1.9.8 — a server installed before it was bundled would otherwise be told the
# engine is missing forever, because updating only refreshes the app.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Liquidsoap — the AutoDJ engine, and the one piece that must be current
#
# The panel plays a *watched* playlist file (rotation.m3u) and replans it at
# every track boundary. Two engine bugs made that look like a station stuck on
# one song: 2.4.6 fixed a watched-playlist reload race that could hand back an
# entry it had already played, and 2.4.0 fixed a prefetch started just after a
# reload restarting the list from its head. Ubuntu 22.04 packages 2.0.2 and
# Debian 12 packages 2.1.3, so a plain `apt-get install liquidsoap` leaves an
# install exposed to both.
#
# On apt hosts this adds the project's own repository (repo.liquidsoap.info) and
# installs **the latest release it publishes for this distribution**. Which
# channel that is comes from the repository's own per-system list rather than
# from this file: a pinned channel name starts installing an old engine the day
# the next release is built, and this function is run by `install.sh update` for
# years. 2.4.6 stays as the floor (`LIQUIDSOAP_WANT`) — a channel older than it
# fixes nothing. Where the project publishes nothing for this release (Ubuntu
# 22.04 and Debian 12 are outside its supported list) the script says so and
# prints the opam build instead of leaving an apt source that 404s. Everywhere
# the package manager is not apt, that package manager is left to it.
# Best-effort throughout: an old Liquidsoap still streams, so a failure warns.
# ---------------------------------------------------------------------------
LIQUIDSOAP_WANT="2.4.6"
LIQUIDSOAP_REPO="https://repo.liquidsoap.info"

# The version the installed binary reports, e.g. "2.0.2"; empty when there is
# none or it will not talk.
liquidsoap_version() {
  LQ="$(command -v liquidsoap || true)"
  [ -n "$LQ" ] || return 0
  "$LQ" --version 2>/dev/null | sed -n 's/.*[Ll]iquidsoap[[:space:]][[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n 1
}

# version_lt A B — true when A is older than B. `sort -V` is GNU; without it we
# report "not older", which means no upgrade rather than a guess.
version_lt() {
  [ "$1" = "$2" ] && return 1
  printf '%s\n%s\n' "$1" "$2" | sort -V >/dev/null 2>&1 || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

# The newest release channel this system can install, read from the project's
# own per-system list (targets/deb/<codename>/<arch>.txt), or "" when it
# publishes nothing for this release.
#
# That list is newest first and also carries `rolling-release-*` snapshots
# (rebuilt on every commit) and `-rc` pre-releases. A server streaming to
# listeners wants neither by default, so they are taken only when they are all
# that is offered — and the version check in install_liquidsoap still refuses
# anything older than $LIQUIDSOAP_WANT either way.
liquidsoap_channel() {
  TARGETS="$(curl -fsSL --max-time 15 "$LIQUIDSOAP_REPO/targets/$1" 2>/dev/null || true)"
  [ -n "$TARGETS" ] || return 0
  NAMES="$(printf '%s\n' "$TARGETS" | cut -f1)"
  STABLE="$(printf '%s\n' "$NAMES" | grep -v '^rolling-' | grep -Ev -- '-rc[0-9]*$' | head -n 1)"
  printf '%s' "${STABLE:-$(printf '%s\n' "$NAMES" | head -n 1)}"
}

# The recipe for a current engine on a system the project publishes no package
# for. Printed, never run: a source build is the operator's call, and on a small
# host it is the difference between minutes and an hour.
liquidsoap_opam_recipe() {
  info "to build $LIQUIDSOAP_WANT from source:"
  info "  apt-get install -y opam build-essential m4 pkg-config git curl libcurl4-openssl-dev ffmpeg"
  info "  opam init --disable-sandboxing --yes --bare"
  info "  opam switch create liquidsoap-$LIQUIDSOAP_WANT ocaml-base-compiler.4.14.2 --yes"
  info "  eval \$(opam env --switch=liquidsoap-$LIQUIDSOAP_WANT)"
  info "  opam install --yes liquidsoap.$LIQUIDSOAP_WANT ffmpeg"
  info "  then set LIQUIDSOAP_BIN=~/.opam/liquidsoap-$LIQUIDSOAP_WANT/bin/liquidsoap for the panel"
}

install_liquidsoap() {
  say "Liquidsoap (AutoDJ engine)"
  HAVE="$(liquidsoap_version)"
  if [ -z "$HAVE" ]; then
    if command -v liquidsoap >/dev/null 2>&1; then
      info "installed, but it did not report a version — leaving it alone"
    else
      warn "liquidsoap is not installed, so AutoDJ cannot play"
    fi
    return 0
  fi
  if ! version_lt "$HAVE" "$LIQUIDSOAP_WANT"; then
    info "installed: $HAVE (this panel needs $LIQUIDSOAP_WANT or newer) — nothing to do"
    return 0
  fi
  info "installed: $HAVE — older than $LIQUIDSOAP_WANT, which carries the playlist fixes this panel relies on"

  if [ "$PM" != "apt-get" ]; then
    info "upgrade liquidsoap through $PM, or build it with opam (opam install liquidsoap.$LIQUIDSOAP_WANT)"
    return 0
  fi
  if [ ! -r /etc/os-release ]; then
    warn "no /etc/os-release — cannot work out which Liquidsoap build this release needs"
    return 0
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-}"
  if [ -z "$CODENAME" ]; then
    warn "this release has no codename; install Liquidsoap $LIQUIDSOAP_WANT with opam instead"
    return 0
  fi

  ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  CHANNEL="$(liquidsoap_channel "deb/$CODENAME/$ARCH.txt")"
  if [ -z "$CHANNEL" ]; then
    warn "the Liquidsoap repository publishes no package for $CODENAME/$ARCH"
    info "it builds for Debian trixie and forky, and Ubuntu plucky and resolute — this release is not in that list"
    info "leaving the distribution's liquidsoap ($HAVE) in place."
    liquidsoap_opam_recipe
    return 0
  fi

  info "the newest release for $CODENAME/$ARCH is $CHANNEL — adding the repository and installing it"
  SRC_FILE="/etc/apt/sources.list.d/liquidsoap.sources"
  xb "$SUDO install -d -m 0755 /etc/apt/keyrings"
  # The source stanza is published per channel and target — it is what the
  # project's own setup.sh fetches — so it is downloaded rather than written
  # here: the URIs, suites and signing key stay the project's to define.
  if ! x "$SUDO curl -fsSL --retry 2 -o /etc/apt/keyrings/liquidsoap.asc $LIQUIDSOAP_REPO/liquidsoap.asc </dev/null" ||
     ! x "$SUDO curl -fsSL --retry 2 -o $SRC_FILE $LIQUIDSOAP_REPO/$CHANNEL/deb/$CODENAME/liquidsoap.sources </dev/null"; then
    warn "could not fetch the $CHANNEL repository files for $CODENAME"
    xb "$SUDO rm -f $SRC_FILE /etc/apt/keyrings/liquidsoap.asc"
    info "leaving the distribution's liquidsoap ($HAVE) in place."
    liquidsoap_opam_recipe
    return 0
  fi
  xb "$SUDO apt-get update -qq </dev/null"
  xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y liquidsoap </dev/null"

  NOW="$(liquidsoap_version)"
  if [ -n "$NOW" ] && ! version_lt "$NOW" "$LIQUIDSOAP_WANT"; then
    info "installed: $NOW (the latest release the project publishes for $CODENAME)"
    return 0
  fi

  # The repository answered but the package did not arrive, or it is still below
  # the panel's floor: put the apt sources back the way they were, and leave the
  # operator the exact recipe for a current engine.
  warn "still ${NOW:-$HAVE} after installing from $CHANNEL"
  xb "$SUDO rm -f $SRC_FILE /etc/apt/keyrings/liquidsoap.asc"
  info "leaving the distribution's liquidsoap in place."
  liquidsoap_opam_recipe
}

install_shoutcast() {
  say "Shoutcast DNAS"
  ARCH="$(uname -m)"
  if [ -x "$SC_DIR/sc_serv" ]; then
    info "already installed: $SC_DIR/sc_serv"
  elif [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
    warn "no Shoutcast build for $ARCH — skipped (Icecast still works)"
  else
    x "$SUDO mkdir -p $SC_DIR"
    if [ "$DRY_RUN" = "1" ]; then
      x "curl -fsSL --retry 2 -o /tmp/sc.tar.gz $SC_URL"
      x "tar -xzf /tmp/sc.tar.gz -C /tmp && cp <extracted>/sc_serv $SC_DIR/sc_serv"
    else
      TMP="$(mktemp -d)"
      if curl -fsSL --retry 2 -o "$TMP/sc.tar.gz" "$SC_URL" </dev/null; then
        tar -xzf "$TMP/sc.tar.gz" -C "$TMP"
        SC_BIN="$(find "$TMP" -type f -name sc_serv | head -n 1 || true)"
        if [ -n "$SC_BIN" ]; then
          x "$SUDO cp \"$SC_BIN\" $SC_DIR/sc_serv && $SUDO chmod 755 $SC_DIR/sc_serv" \
            && info "installed: $SC_DIR/sc_serv"
        else
          warn "sc_serv not found inside the archive"
        fi
      else
        warn "could not download Shoutcast from $SC_URL"
      fi
      rm -rf "$TMP"
    fi
  fi
}

# 32-bit glibc: the runtime the legacy 1.9.8 binary is linked against (an i386
# ELF from 2007 — see SC1_URL above). Installed as its own step, before the
# "is sc_serv already there" check, because the binary and its runtime age
# independently: a box that already has /opt/shoutcast1/sc_serv (copied in by
# hand, or left by an earlier run whose package step failed) still needs the
# loader, and `update` reaches install_shoutcast1 too. Idempotent, and
# best-effort like the engines: Icecast, Icecast KH and DNAS 2 run without it,
# so a failure warns instead of aborting the install.
#
# libc6-i386 is amd64-only, so on an ARM host there is nothing to add — the
# i386 binary cannot run there anyway and asking apt for the package would only
# produce a scary failure.
#
# The package manager can report success while the loader is still absent (a
# partial mirror, a package already "installed" without its files, or an
# unsupported distro). The check after the install is therefore on the exact
# path the 1.9.8 ELF asks for, and the failure prints the command that fixes it
# rather than leaving a station that fails only when someone presses Start.
sc1_loader_fix() {
  SC1_FIX_SUDO="${SUDO:+$SUDO }"
  case "$PM" in
    apt-get) printf '%sapt-get update && %sapt-get install -y libc6-i386' "$SC1_FIX_SUDO" "$SC1_FIX_SUDO" ;;
    dnf)    printf '%sdnf install -y glibc.i686' "$SC1_FIX_SUDO" ;;
    yum)    printf '%syum install -y glibc.i686' "$SC1_FIX_SUDO" ;;
    zypper) printf '%szypper -n install glibc-32bit' "$SC1_FIX_SUDO" ;;
    pacman) printf '%spacman -S --noconfirm lib32-glibc' "$SC1_FIX_SUDO" ;;
    apk)    printf 'Alpine has no 32-bit glibc package; use a glibc-based x86_64 host or container' ;;
    *)      printf 'install 32-bit glibc: libc6-i386 (apt), glibc.i686 (dnf/yum), glibc-32bit (zypper) or lib32-glibc (pacman)' ;;
  esac
}

sc1_verify_loader() {
  if [ "$DRY_RUN" = "1" ]; then
    info "would verify the 1.9.8 ELF loader at $SC1_LOADER_PATH"
    return 0
  fi
  if [ -x "$SC1_LOADER_PATH" ]; then
    info "verified: 1.9.8 ELF loader present at $SC1_LOADER_PATH"
    return 0
  fi
  warn "Shoutcast DNAS 1.9.8 cannot start: its 32-bit ELF loader $SC1_LOADER_PATH is missing after installing 32-bit glibc."
  warn "fix it with: $(sc1_loader_fix)"
  return 1
}

install_32bit_glibc() {
  case "$(uname -m)" in
    x86_64|amd64|i?86) ;;
    *) info "32-bit glibc: not needed on $(uname -m) — the 1.9.8 binary is x86-only"; return 0 ;;
  esac
  say "32-bit glibc (runtime for the legacy Shoutcast 1.9.8 engine)"
  case "$PM" in
    apt-get)
      # Refresh the package index first: a minimal or long-lived image may have
      # no lists, and without this `apt-get install libc6-i386` cannot find it.
      xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update </dev/null && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y libc6-i386 </dev/null" \
        || warn "libc6-i386 install failed — the 1.9.8 binary needs 32-bit glibc to run"
      ;;
    dnf|yum)
      xb "$SUDO $PM install -y glibc.i686 </dev/null" \
        || warn "glibc.i686 install failed — the 1.9.8 binary needs 32-bit glibc to run"
      ;;
    zypper) xb "$SUDO zypper -n install glibc-32bit </dev/null" || warn "glibc-32bit install failed" ;;
    pacman) xb "$SUDO pacman -S --noconfirm lib32-glibc </dev/null" || warn "lib32-glibc install failed" ;;
    apk)    info "Alpine has no 32-bit glibc — the 1.9.8 binary will not run here" ;;
    *)      info "no 32-bit glibc package known for ${PM:-this system} — the 1.9.8 binary may not run here" ;;
  esac
  # Best-effort like the engine itself, but never silent: a missing loader is
  # reported now, with the package command, even if sc_serv is installed later.
  sc1_verify_loader || true
}

install_shoutcast1() {
  say "Shoutcast DNAS 1.9.8 (legacy, 32-bit)"
  install_32bit_glibc
  if [ -x "$SC1_DIR/sc_serv" ]; then
    info "already installed: $SC1_DIR/sc_serv"
  else
    x "$SUDO mkdir -p $SC1_DIR"
    if [ "$DRY_RUN" = "1" ]; then
      x "curl -fsSL --retry 2 -o /tmp/sc198.tar.gz $SC1_URL"
      x "tar -xzf /tmp/sc198.tar.gz -C /tmp && cp <extracted>/sc_serv $SC1_DIR/sc_serv"
    else
      TMP1="$(mktemp -d)"
      if curl -fsSL --retry 2 -o "$TMP1/sc198.tar.gz" "$SC1_URL" </dev/null; then
        tar -xzf "$TMP1/sc198.tar.gz" -C "$TMP1"
        SC1_BIN="$(find "$TMP1" -type f -name sc_serv | head -n 1 || true)"
        if [ -n "$SC1_BIN" ]; then
          x "$SUDO cp \"$SC1_BIN\" $SC1_DIR/sc_serv && $SUDO chmod 755 $SC1_DIR/sc_serv" \
            && info "installed: $SC1_DIR/sc_serv"
        else
          warn "sc_serv not found inside the 1.9.8 archive"
        fi
      else
        warn "could not download Shoutcast 1.9.8 from $SC1_URL — the legacy engine stays unavailable (Icecast and DNAS 2 are unaffected)"
      fi
      rm -rf "$TMP1"
    fi
  fi
}

# libxml2 2.12 changed the structured-error callback to receive a `const
# xmlError *`. Icecast KH declares its handler as taking `xmlErrorPtr`
# (`xmlError *`), and gcc 14 raises that qualifier mismatch as an error instead
# of a warning, so `make` stops in cfgfile.c with "passing argument 2 of
# 'xmlSetStructuredErrorFunc' from incompatible pointer type" (gcc 12 and
# libxml2 2.9, which most 22.04-era hosts have, do not complain at all). The
# handler only reads the error it is given, so matching the qualifier in the two
# places that declare it is the whole fix. The installed header decides, so an
# older libxml2 leaves the source untouched.
patch_icecast_kh_libxml2() {
  kh_src="$1"
  kh_inc="$(xml2-config --cflags 2>/dev/null | tr ' ' '\n' | sed -n 's/^-I//p' | head -n 1)"
  [ -n "$kh_inc" ] || kh_inc="$(pkg-config --cflags libxml-2.0 2>/dev/null | tr ' ' '\n' | sed -n 's/^-I//p' | head -n 1)"
  [ -n "$kh_inc" ] || kh_inc="/usr/include/libxml2"
  grep -qs 'xmlStructuredErrorFunc) (void \*userData, const xmlError' \
    "$kh_inc/libxml/xmlerror.h" || return 0
  kh_patched=""
  kh_decl='s/\(config_xml_parse_failure (void[[:space:]]*\*[[:space:]]*[a-z]*,[[:space:]]*\)xmlErrorPtr /\1const xmlError * /'
  for kh_file in "$kh_src/src/cfgfile.h" "$kh_src/src/cfgfile.c"; do
    [ -f "$kh_file" ] || continue
    # A later KH tag may already carry the const qualifier; then there is
    # nothing to do and nothing to report.
    grep -qs 'config_xml_parse_failure (void.*xmlErrorPtr error' "$kh_file" || continue
    {
      sed -i "$kh_decl" "$kh_file" 2>/dev/null \
        || $SUDO sed -i "$kh_decl" "$kh_file"
    } || {
      warn "could not patch $(basename "$kh_file") for libxml2's const error callback — the build below may fail on gcc 14"
      return
    }
    kh_patched="$kh_patched $(basename "$kh_file")"
  done
  [ -z "$kh_patched" ] || info "patched the libxml2 2.12 const error callback in:$kh_patched"
}

# Icecast KH: Icecast 2 plus Karl Heyes' patches. Built from source because no
# distribution packages it, into its own prefix so the distribution's Icecast 2
# stays where its package manager expects it.
#
# Best-effort like the other optional engines: a build that fails (no C
# toolchain, no development headers, an unreachable GitHub) only warns, because
# every station on Icecast 2, DNAS 2 or 1.9.8 keeps working without it.
#
# It ships `status.xsl` but NOT `status-json.xsl`/`xml2json.xslt`, which is the
# pair the panel reads for now-playing and listener counts. It gets those from
# the distribution's icecast2 package, installed just above this call — worth
# knowing before "fixing" that package out of the install list.
install_icecast_kh() {
  say "Icecast KH (Karl Heyes fork, built from source)"
  # What the summary prints: the path, or the one-line reason it is not there.
  IKH_STATUS=""
  if [ -x "$IKH_DIR/bin/icecast" ]; then
    info "already installed: $IKH_DIR/bin/icecast"
    IKH_STATUS="installed: $IKH_DIR/bin/icecast"
  else
    # One package at a time. This list is eight names deep and a release that has
    # renamed one of them (`libcurl4-openssl-dev` → `libcurl4-gnutls-dev`, a
    # `-dev` merge, `pkgconfig` vs `pkgconf`) used to fail the whole command —
    # which took the C toolchain down with it and left configure with nothing to
    # compile against, the failure that reads as "the build did not run".
    case "$PM" in
      apt-get)
        IKH_PKGS="build-essential pkg-config libxml2-dev libxslt1-dev libogg-dev libvorbis-dev libcurl4-openssl-dev libssl-dev"
        IKH_PM_INSTALL="$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y"
        ;;
      dnf|yum)
        IKH_PKGS="gcc gcc-c++ make pkgconfig libxml2-devel libxslt-devel libogg-devel libvorbis-devel libcurl-devel openssl-devel"
        IKH_PM_INSTALL="$SUDO $PM install -y"
        ;;
      pacman)
        IKH_PKGS="base-devel libxml2 libxslt libogg libvorbis curl openssl"
        IKH_PM_INSTALL="$SUDO pacman -S --noconfirm"
        ;;
      apk)
        IKH_PKGS="build-base pkgconf libxml2-dev libxslt-dev libogg-dev libvorbis-dev curl-dev openssl-dev"
        IKH_PM_INSTALL="$SUDO apk add --no-cache"
        ;;
      zypper)
        IKH_PKGS="gcc gcc-c++ make pkg-config libxml2-devel libxslt-devel libogg-devel libvorbis-devel libcurl-devel libopenssl-devel"
        IKH_PM_INSTALL="$SUDO zypper -n install -y"
        ;;
      *) IKH_PKGS="" ;;
    esac
    IKH_PKG_FAILED=""
    for pkg in $IKH_PKGS; do
      xb "$IKH_PM_INSTALL $pkg </dev/null" || IKH_PKG_FAILED="$IKH_PKG_FAILED $pkg"
    done
    if [ -n "$IKH_PKG_FAILED" ]; then
      warn "these Icecast KH build packages could not be installed:$IKH_PKG_FAILED — the build below may fail without them (Icecast 2 is unaffected)"
    fi
    if ! command -v make >/dev/null 2>&1 \
      || { ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; }; then
      warn "no C compiler or make on this host, so Icecast KH cannot be built here — the engine stays unavailable (Icecast 2 is unaffected)"
      IKH_STATUS="not built: no C toolchain"
      return
    fi
    x "$SUDO mkdir -p $IKH_DIR"
    if [ "$DRY_RUN" = "1" ]; then
      x "curl -fsSL --retry 2 -o /tmp/icecast-kh.tar.gz $IKH_URL"
      x "tar -xzf /tmp/icecast-kh.tar.gz -C /tmp && cd <extracted>/ && ./configure --prefix=$IKH_DIR --with-openssl && make && make install"
    else
      TMPK="$(mktemp -d)"
      if curl -fsSL --retry 2 -o "$TMPK/icecast-kh.tar.gz" "$IKH_URL" </dev/null; then
        if tar -xzf "$TMPK/icecast-kh.tar.gz" -C "$TMPK"; then
          # The archive's top directory is named after the tag, which a caller
          # may have replaced through IKH_URL — so the source tree is found by
          # its `configure` script rather than by a guessed directory name.
          KH_CONFIGURE="$(find "$TMPK" -maxdepth 2 -type f -name configure | head -n 1 || true)"
          if [ -z "$KH_CONFIGURE" ]; then
            warn "no configure script inside the Icecast KH archive — the engine stays unavailable (Icecast 2 is unaffected)"
            IKH_STATUS="no configure script in the archive"
          else
            KH_SRC="$(dirname "$KH_CONFIGURE")"
            patch_icecast_kh_libxml2 "$KH_SRC"
            # The build log is kept next to the prefix, so "the installer did not
            # make /opt/icecast-kh/bin/icecast" has an answer on the machine that
            # says why, instead of a generic warning in the middle of the run.
            IKH_LOG="$IKH_DIR/install.log"
            : >"$IKH_LOG" 2>/dev/null || IKH_LOG="/tmp/icecast-kh-install.log"
            info "building $IKH_REF in $KH_SRC — log: $IKH_LOG"
            if x "cd \"$KH_SRC\" && ./configure --prefix=$IKH_DIR --with-openssl && make && $SUDO make install" >>"$IKH_LOG" 2>&1; then
              IKH_BUILT=1
            else
              IKH_BUILT=0
            fi
            # `make install` can fail after the binary itself is built — a doc or
            # web target landing on a path this user cannot write, a distro
            # `config.site` overriding --prefix — so a built binary is put where
            # the panel probes it rather than thrown away with the build tree.
            if [ ! -x "$IKH_DIR/bin/icecast" ] && [ -f "$KH_SRC/src/icecast" ]; then
              xb "$SUDO mkdir -p $IKH_DIR/bin" && xb "$SUDO install -m 755 \"$KH_SRC/src/icecast\" $IKH_DIR/bin/icecast"
              [ -x "$IKH_DIR/bin/icecast" ] && info "the build installed outside $IKH_DIR; the binary was put in place instead"
            fi
            if [ -x "$IKH_DIR/bin/icecast" ]; then
              xb "$SUDO chmod 755 $IKH_DIR/bin/icecast"
              info "installed: $IKH_DIR/bin/icecast (Icecast KH $IKH_REF)"
              IKH_STATUS="installed: $IKH_DIR/bin/icecast"
            else
              if [ "$IKH_BUILT" = "1" ]; then
                warn "the Icecast KH build finished but produced no binary at $IKH_DIR/bin/icecast — the engine stays unavailable"
                IKH_STATUS="build finished with no binary (log: $IKH_LOG)"
              else
                warn "building Icecast KH failed — the engine stays unavailable, Icecast 2 is unaffected"
                IKH_STATUS="build failed (log: $IKH_LOG)"
              fi
              # The tail of the log is the actual compiler or configure error; the
              # summary line above only says something went wrong.
              if [ -s "$IKH_LOG" ]; then
                warn "last lines of $IKH_LOG:"
                tail -n 12 "$IKH_LOG" 2>/dev/null | sed 's/^/      /' >&2
              fi
            fi
          fi
        else
          warn "could not unpack the Icecast KH archive"
          IKH_STATUS="could not unpack the archive"
        fi
      else
        warn "could not download Icecast KH from $IKH_URL — the engine stays unavailable (Icecast 2 and both Shoutcast servers are unaffected)"
        IKH_STATUS="could not download $IKH_URL"
      fi
      rm -rf "$TMPK"
    fi
  fi
}

# RSAS: the official static Linux build, unpacked beside its status templates.
# Best-effort like the other optional engines: an unsupported architecture or a
# failed download only warns, because every station on Icecast 2, Icecast KH,
# DNAS or 1.9.8 keeps streaming without it.
install_rsas() {
  say "Rocket Streaming Audio Server (RSAS)"
  RSAS_STATUS=""
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *)
      warn "no official RSAS Linux build for $(uname -m) — the engine stays unavailable (other audio engines are unaffected)"
      RSAS_STATUS="not available for $(uname -m)"
      return 0
      ;;
  esac
  if [ -x "$RSAS_BIN" ] && [ -d "$RSAS_HOME/templates" ] && [ -d "$RSAS_HOME/webroot" ]; then
    info "already installed: $RSAS_BIN"
    RSAS_STATUS="installed: $RSAS_BIN"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    x "mkdir -p $RSAS_HOME $RSAS_HOME/templates $RSAS_HOME/webroot"
    x "curl -fsSL --retry 2 -o /tmp/rsas.tar.gz $RSAS_URL"
    x "tar -xzf /tmp/rsas.tar.gz -C /tmp && install -m755 <extracted>/rsas $RSAS_BIN && cp -R <extracted>/templates/. $RSAS_HOME/templates/ && cp -R <extracted>/css/. $RSAS_HOME/webroot/css/"
    info "dry-run: would install RSAS from $RSAS_URL into $RSAS_HOME"
    return 0
  fi
  TMPR="$(mktemp -d)"
  if curl -fsSL --retry 2 -o "$TMPR/rsas.tar.gz" "$RSAS_URL" </dev/null; then
    if tar -xzf "$TMPR/rsas.tar.gz" -C "$TMPR"; then
      RSAS_SRC="$(find "$TMPR" -type f -name rsas | head -n 1 || true)"
      if [ -n "$RSAS_SRC" ]; then
        RSAS_ROOT="$(dirname "$RSAS_SRC")"
        # Optional engine: a failed copy warns, then the checks below report
        # what is actually missing, instead of taking the whole installer down.
        xb "$SUDO mkdir -p \"$RSAS_HOME\" \"$RSAS_HOME/templates\" \"$RSAS_HOME/webroot\""
        xb "$SUDO install -m 755 \"$RSAS_SRC\" \"$RSAS_BIN\""
        if [ -d "$RSAS_ROOT/templates" ]; then
          xb "$SUDO cp -R \"$RSAS_ROOT/templates/.\" \"$RSAS_HOME/templates/\""
        fi
        for rsas_asset in css images js; do
          if [ -d "$RSAS_ROOT/$rsas_asset" ]; then
            xb "$SUDO mkdir -p \"$RSAS_HOME/webroot/$rsas_asset\""
            xb "$SUDO cp -R \"$RSAS_ROOT/$rsas_asset/.\" \"$RSAS_HOME/webroot/$rsas_asset/\""
          fi
        done
        if [ -x "$RSAS_BIN" ] && [ -d "$RSAS_HOME/templates" ] && [ -d "$RSAS_HOME/webroot" ]; then
          info "installed: $RSAS_BIN (RSAS $RSAS_VERSION, web assets in $RSAS_HOME)"
          RSAS_STATUS="installed: $RSAS_BIN"
        elif [ ! -x "$RSAS_BIN" ]; then
          warn "RSAS installer finished but produced no binary at $RSAS_BIN"
          RSAS_STATUS="install finished with no binary"
        else
          warn "RSAS binary is installed at $RSAS_BIN but its templates/webroot could not be copied — its public status page will be unavailable"
          RSAS_STATUS="installed without web assets"
        fi
      else
        warn "rsas binary not found inside the RSAS archive — the engine stays unavailable"
        RSAS_STATUS="no rsas binary in the archive"
      fi
    else
      warn "could not unpack the RSAS archive — the engine stays unavailable (other audio engines are unaffected)"
      RSAS_STATUS="could not unpack the archive"
    fi
  else
    warn "could not download RSAS from $RSAS_URL — the engine stays unavailable (other audio engines are unaffected)"
    RSAS_STATUS="could not download $RSAS_URL"
  fi
  rm -rf "$TMPR"
}

# SRS (Simple Realtime Server) is the second video ingest. It ships an official
# prebuilt for x86_64 Linux only; other architectures keep MediaMTX and get a
# warning rather than a half-installed server. The archive is the upstream
# release layout, so the binary is found by path instead of trusting a flat zip.
#
# SRS ships as a .zip, but unzip is not present on every minimal host. The old
# inline step only looked for unzip/python3 and silently skipped SRS when both
# were absent, so a fresh install could finish with "SRS missing" in the panel.
# ensure_unzip() installs it here, which also repairs existing installs on the
# update path; python3 remains the fallback when the package cannot be added.
ensure_unzip() {
  command -v unzip >/dev/null 2>&1 && return 0
  say "unzip (SRS release archive)"
  case "$PM" in
    apt-get) xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y unzip </dev/null" ;;
    dnf|yum) xb "$SUDO $PM install -y unzip </dev/null" ;;
    pacman) xb "$SUDO pacman -S --noconfirm unzip </dev/null" ;;
    apk)     xb "$SUDO apk add --no-cache unzip </dev/null" ;;
    zypper)  xb "$SUDO zypper -n install unzip </dev/null" ;;
    *)       return 1 ;;
  esac
  command -v unzip >/dev/null 2>&1
}

install_srs() {
  say "SRS (Simple Realtime Server)"
  if [ -x "$SRS_BIN" ]; then
    info "SRS already installed: $SRS_BIN"
    return 0
  fi
  case "${ARCH:-$(uname -m)}" in
    x86_64|amd64) ;;
    *)
      warn "no official SRS prebuilt for ${ARCH:-$(uname -m)} — MediaMTX video still works"
      return 0
      ;;
  esac
  SRS_URL="https://github.com/ossrs/srs/releases/download/v$SRS_VERSION/SRS-CentOS7-x86_64-$SRS_VERSION.zip"
  SRS_DIR="$(dirname "$SRS_BIN")"
  if [ "$DRY_RUN" = "1" ]; then
    x "curl -fsSL --retry 2 -o /tmp/srs.zip $SRS_URL"
    x "mkdir -p $SRS_DIR && unzip -q /tmp/srs.zip -d /tmp/srs && install -m755 /tmp/srs/SRS-CentOS7-x86_64-$SRS_VERSION/usr/local/srs/objs/srs $SRS_BIN"
    info "dry-run: would install SRS ($SRS_VERSION) → $SRS_BIN"
    return 0
  fi
  ensure_unzip || true
  SRS_TMP="$(mktemp -d)"
  if curl -fsSL --retry 2 -o "$SRS_TMP/srs.zip" "$SRS_URL" </dev/null; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -q -o "$SRS_TMP/srs.zip" -d "$SRS_TMP" || warn "could not unpack the SRS archive"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -m zipfile -e "$SRS_TMP/srs.zip" "$SRS_TMP" || warn "could not unpack the SRS archive"
    else
      warn "neither unzip nor python3 is available — SRS skipped"
    fi
    SRS_SRC="$(find "$SRS_TMP" -type f -path '*/usr/local/srs/objs/srs' | head -n 1 || true)"
    if [ -n "$SRS_SRC" ]; then
      # The install and the executable bit are checked, not assumed: as a
      # non-root update this used to fail with "permission denied" and then
      # report "srs binary not found inside the archive", which is the wrong
      # fault. The panel reads the path itself, so only say nothing is there
      # when the archive really lacks it.
      if x "$SUDO mkdir -p \"$SRS_DIR\"" \
        && x "$SUDO install -m 755 \"$SRS_SRC\" $SRS_BIN" \
        && [ -x "$SRS_BIN" ]; then
        info "installed SRS ($SRS_VERSION) → $SRS_BIN"
      else
        warn "could not install SRS at $SRS_BIN — run the installer as root, or set SRS_BIN to a writable path"
      fi
    else
      warn "srs binary not found inside the archive — SRS skipped"
    fi
  else
    warn "could not download SRS from $SRS_URL — MediaMTX video still works"
  fi
  rm -rf "$SRS_TMP"
}

# Both Red5 distributions are Java servers. Java 21 is the minimum the current
# open-source server documents and the licensed Pro 14 line requires; keeping
# the check in one function means the update path repairs either install.
ensure_java_21() {
  RED5_JAVA_FOR="${1:-Red5}"
  JAVA_MAJOR=""
  if command -v java >/dev/null 2>&1; then
    JAVA_MAJOR="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  fi
  [ "${JAVA_MAJOR:-0}" -ge 21 ] && return 0
  [ "$DRY_RUN" = "1" ] && { x "install Java 21 (needed by $RED5_JAVA_FOR)"; return 0; }
  case "$PM" in
    apt-get) xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jre-headless </dev/null" || warn "Java 21 install failed — $RED5_JAVA_FOR will not start without it" ;;
    dnf|yum) xb "$SUDO $PM install -y java-21-openjdk-headless </dev/null" || warn "Java 21 install failed — $RED5_JAVA_FOR will not start without it" ;;
    pacman)  xb "$SUDO pacman -S --noconfirm jre21-openjdk-headless </dev/null" || warn "Java 21 install failed — $RED5_JAVA_FOR will not start without it" ;;
    apk)     xb "$SUDO apk add --no-cache openjdk21-jre-headless </dev/null" || warn "Java 21 install failed — $RED5_JAVA_FOR will not start without it" ;;
    zypper)  xb "$SUDO zypper -n install java-21-openjdk-headless </dev/null" || warn "Java 21 install failed — $RED5_JAVA_FOR will not start without it" ;;
    *)       warn "no Java 21 package for '$PM' — $RED5_JAVA_FOR will not start without a JRE" ;;
  esac
}

# Red5 Pro is complete only when the panel can use it: its launcher, licence,
# config and the live webapp the panel patches. Checking only red5.sh let update
# skip a tree that was missing one of them.
red5_pro_installed() {
  [ -x "$RED5_HOME/red5.sh" ] &&
    [ -f "$RED5_HOME/LICENSE.KEY" ] &&
    [ -f "$RED5_HOME/conf/red5.properties" ] &&
    [ -f "$RED5_HOME/webapps/live/WEB-INF/red5-web.xml" ] &&
    [ -f "$RED5_HOME/webapps/live/WEB-INF/red5-web.properties" ]
}

# Copy or download the licensed archive into $1. RED5_ARCHIVE_URL is usually a
# URL, but the archive is downloaded on the operator's workstation, so a local
# path (or file://) has to work too — curl cannot open one.
fetch_red5_archive() {
  case "$RED5_ARCHIVE_URL" in
    file://*) RED5_SOURCE="${RED5_ARCHIVE_URL#file://}" ;;
    *://*)    RED5_SOURCE="" ;;
    *)        RED5_SOURCE="$RED5_ARCHIVE_URL" ;;
  esac
  if [ -n "$RED5_SOURCE" ]; then
    if [ ! -f "$RED5_SOURCE" ]; then
      warn "Red5 Pro archive not found at $RED5_SOURCE — Red5 Pro skipped"
      return 1
    fi
    if ! cp "$RED5_SOURCE" "$1"; then
      warn "could not copy the Red5 Pro archive from $RED5_SOURCE"
      return 1
    fi
    info "using Red5 Pro archive $RED5_SOURCE"
    return 0
  fi
  if ! curl -fsSL --retry 2 -o "$1" "$RED5_ARCHIVE_URL" </dev/null; then
    warn "could not download Red5 Pro from $RED5_ARCHIVE_URL"
    return 1
  fi
  return 0
}

# Red5 Pro is licensed. The installer can only unpack an archive the operator is
# entitled to use; without RED5_ARCHIVE_URL it leaves the optional engine alone.
# Kept as a function because both install and update must repair it — the old
# inline block ran only on a fresh install, so an existing server never got the
# missing Red5 Pro binary.
install_red5_pro() {
  say "Red5 Pro (optional)"
  if red5_pro_installed; then
    info "Red5 Pro already installed: $RED5_HOME"
    return 0
  fi
  if [ -z "$RED5_ARCHIVE_URL" ]; then
    info "Red5 Pro: not installed (licensed distribution; set RED5_ARCHIVE_URL to unpack your red5.net archive, or install it at $RED5_HOME)"
    return 0
  fi
  if [ -x "$RED5_HOME/red5.sh" ]; then
    warn "Red5 Pro at $RED5_HOME is incomplete (needs LICENSE.KEY, conf and the live webapp) — reinstalling"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    case "$RED5_ARCHIVE_URL" in
      file://*) x "cp ${RED5_ARCHIVE_URL#file://} /tmp/red5.zip" ;;
      *://*)    x "curl -fsSL --retry 2 -o /tmp/red5.zip $RED5_ARCHIVE_URL" ;;
      *)        x "cp $RED5_ARCHIVE_URL /tmp/red5.zip" ;;
    esac
    x "unzip -q /tmp/red5.zip -d /tmp/red5 && cp -a /tmp/red5/*/. $RED5_HOME/"
    info "dry-run: would install Red5 Pro → $RED5_HOME"
    return 0
  fi
  ensure_java_21 "Red5 Pro"
  ensure_unzip || true
  if ! command -v unzip >/dev/null 2>&1; then
    warn "unzip is required to install Red5 Pro — Red5 Pro skipped"
    return 0
  fi
  RED5_TMP="$(mktemp -d)"
  if fetch_red5_archive "$RED5_TMP/red5.zip"; then
    if unzip -q "$RED5_TMP/red5.zip" -d "$RED5_TMP/unpacked"; then
      RED5_SRC="$(find "$RED5_TMP/unpacked" -maxdepth 4 -type f -name red5.sh | head -n 1 || true)"
      if [ -n "$RED5_SRC" ]; then
        RED5_ROOT="$(dirname "$RED5_SRC")"
        x "$SUDO mkdir -p $RED5_HOME"
        x "$SUDO cp -a \"$RED5_ROOT/.\" $RED5_HOME/"
        x "$SUDO chmod +x $RED5_HOME/red5.sh" 2>/dev/null || true
        if [ -f "$RED5_HOME/LICENSE.KEY" ]; then
          info "installed Red5 Pro → $RED5_HOME"
        else
          warn "Red5 Pro unpacked without LICENSE.KEY — add your license or Red5 will refuse to start"
        fi
      else
        warn "red5.sh not found inside the Red5 archive — Red5 Pro skipped"
      fi
    else
      warn "could not unpack the Red5 archive"
    fi
  fi
  rm -rf "$RED5_TMP"
}

# A Red5 Free tree is usable only when the panel can find everything it needs:
# the panel's own red5FreeConfigIssue() requires the same launcher, config and
# live webapp. Checking only red5.sh let update skip a half-unpacked /opt/red5
# that the panel still refused to start.
red5_free_installed() {
  [ -x "$RED5_FREE_HOME/red5.sh" ] &&
    [ -f "$RED5_FREE_HOME/conf/red5.properties" ] &&
    [ -d "$RED5_FREE_HOME/webapps/live" ]
}

# Red5 Free is the official open-source Red5 server. It is RTMP-only: the panel
# turns each station's stream into HLS with ffmpeg. The upstream release is a
# tar.gz, so this path also works on the minimal hosts where unzip is absent.
install_red5_free() {
  say "Red5 Free (open-source media server)"
  if red5_free_installed; then
    info "Red5 Free already installed: $RED5_FREE_HOME"
    return 0
  fi
  if [ -x "$RED5_FREE_HOME/red5.sh" ]; then
    warn "Red5 Free at $RED5_FREE_HOME is incomplete (needs conf/red5.properties and webapps/live) — reinstalling"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    x "curl -fsSL --retry 2 -o /tmp/red5-free.tar.gz $RED5_FREE_ARCHIVE_URL"
    x "tar -xzf /tmp/red5-free.tar.gz -C /tmp/red5-free && cp -a /tmp/red5-free/*/. $RED5_FREE_HOME/"
    info "dry-run: would install Red5 Free ($RED5_FREE_VERSION) → $RED5_FREE_HOME"
    return 0
  fi
  ensure_java_21 "Red5 Free"
  # The open-source Red5 archive is a tar.gz; repair a minimal host that does
  # not have tar before trying to unpack it.
  ensure_tar
  RED5_FREE_TMP="$(mktemp -d)"
  if curl -fsSL --retry 2 -o "$RED5_FREE_TMP/red5-free.tar.gz" "$RED5_FREE_ARCHIVE_URL" </dev/null; then
    if tar -xzf "$RED5_FREE_TMP/red5-free.tar.gz" -C "$RED5_FREE_TMP"; then
      RED5_FREE_SRC="$(find "$RED5_FREE_TMP" -maxdepth 4 -type f -name red5.sh | head -n 1 || true)"
      if [ -n "$RED5_FREE_SRC" ]; then
        RED5_FREE_ROOT="$(dirname "$RED5_FREE_SRC")"
        # Verify the tree after copying it. A non-root update cannot create
        # /opt/red5; the old sequence printed "installed Red5 Free" anyway, so
        # the update looked successful while the panel still reported
        # "/opt/red5/red5.sh: no binary at …".
        if x "$SUDO mkdir -p $RED5_FREE_HOME" \
          && x "$SUDO cp -a \"$RED5_FREE_ROOT/.\" $RED5_FREE_HOME/" \
          && { x "$SUDO chmod +x $RED5_FREE_HOME/red5.sh" 2>/dev/null || true; } \
          && red5_free_installed; then
          info "installed Red5 Free ($RED5_FREE_VERSION) → $RED5_FREE_HOME"
        else
          warn "could not install Red5 Free at $RED5_FREE_HOME — run the installer as root, or check that the archive has red5.sh, conf/red5.properties and webapps/live"
        fi
      else
        warn "red5.sh not found inside the Red5 Free archive — Red5 Free skipped"
      fi
    else
      warn "could not unpack the Red5 Free archive"
    fi
  else
    warn "could not download Red5 Free from $RED5_FREE_ARCHIVE_URL"
  fi
  rm -rf "$RED5_FREE_TMP"
}

# ---------------------------------------------------------------------------
# Mode: [install] (default) or update
#
# `curl … | sh` has no args. `curl … | sh -s -- update` lands "update" either
# in $1 or (POSIX: first operand becomes $0) in $0 — accept both.
# ---------------------------------------------------------------------------
MODE_ARG="${1:-}"
if [ -z "$MODE_ARG" ]; then
  case "${0##*/}" in
    sh|bash|dash|-sh|-bash|-dash|install.sh|install) MODE_ARG="" ;;
    *) MODE_ARG="$0" ;;
  esac
fi
case "$MODE_ARG" in
  ""|install) MODE="install" ;;
  update) MODE="update" ;;
  uninstall) MODE="uninstall" ;;
  *) die "usage: install.sh [install|update|uninstall]" ;;
esac

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

if [ "$(uname -s)" != "Linux" ]; then
  warn "This installer targets Linux (detected $(uname -s)); engines may be unavailable."
fi

PM=""
for cand in apt-get dnf yum pacman apk zypper; do
  if command -v "$cand" >/dev/null 2>&1; then PM="$cand"; break; fi
done

# ---------------------------------------------------------------------------
# App location
#
# An explicit APP_DIR is always honoured. With the default ($PWD): use the
# directory as-is when it already holds the app or is empty; a non-empty
# directory without the app (e.g. /root) gets a letsstreamit/ subfolder so the
# download has a clean destination.
# ---------------------------------------------------------------------------
if [ -z "$APP_DIR_EXPLICIT" ] && [ ! -f "$APP_DIR/package.json" ]; then
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
    APP_DIR="$APP_DIR/letsstreamit"
  fi
fi
# No source here — fall back to an existing copy of the app at /root/letsstreamit.
if [ -z "$APP_DIR_EXPLICIT" ] && [ ! -f "$APP_DIR/package.json" ] && [ -f /root/letsstreamit/package.json ]; then
  APP_DIR="/root/letsstreamit"
fi
PANEL_PID_FILE="$APP_DIR/panel.pid"
PANEL_LOG="$APP_DIR/panel.log"

# No git anywhere: source comes from $APP_DIR, /root/letsstreamit, or a tarball
# downloaded from SOURCE_URL (defaults to this panel's own /source endpoint).
if [ -z "$SOURCE_URL" ]; then
  SOURCE_URL="$DEFAULT_SOURCE_URL"
fi

# A hosted manifest may overrule that default (never an explicit SOURCE_URL), and
# it is read once, early, so both the install and the update flow use one answer.
read_manifest

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Resolve (or install) Node.js 20+ and npm. Strategy:
#   1) keep a satisfying system Node if one exists
#   2) distro packages — NodeSource for apt/dnf/yum (distro builds are often
#      too old for Next.js), native repos for pacman/apk/zypper
#   3) official binary tarball from nodejs.org into /usr/local
node_ok() {
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || return 1
  NODE_V="$(node -v 2>/dev/null || true)"
  NODE_MAJOR="${NODE_V#v}"
  NODE_MAJOR="${NODE_MAJOR%%.*}"
  case "$NODE_MAJOR" in ""|*[!0-9]*) return 1 ;; esac
  [ "$NODE_MAJOR" -ge "$NODE_MIN_MAJOR" ]
}

ensure_node() {
  say "Node.js runtime"
  if node_ok; then
    info "found $(node -v) at $(command -v node) (npm $(npm -v 2>/dev/null || echo '?'))"
  else
    info "need Node.js >= $NODE_MIN_MAJOR — installing"
    case "$PM" in
      apt-get)
        x "curl -fsSL https://deb.nodesource.com/setup_22.x | ${SUDO:+$SUDO -E }bash -" || warn "NodeSource setup failed"
        x "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs </dev/null" || warn "nodejs install failed"
        ;;
      dnf|yum)
        x "curl -fsSL https://deb.nodesource.com/setup_22.x | ${SUDO:+$SUDO -E }bash -" || warn "NodeSource setup failed"
        x "$SUDO $PM install -y nodejs </dev/null" || warn "nodejs install failed"
        ;;
      pacman)
        x "$SUDO pacman -Sy --noconfirm nodejs npm </dev/null" || warn "nodejs install failed"
        ;;
      apk)
        x "$SUDO apk add --no-cache nodejs npm </dev/null" || warn "nodejs install failed"
        ;;
      zypper)
        x "$SUDO zypper -n install npm nodejs20 </dev/null" ||
          xb "$SUDO zypper -n install npm nodejs </dev/null"
        ;;
    esac

    # Official binary tarball fallback (old distros, unusual platforms).
    if [ "$DRY_RUN" != "1" ] && ! node_ok; then
      case "$(uname -m)" in
        x86_64|amd64)   NODE_ARCH="x64" ;;
        aarch64|arm64)  NODE_ARCH="arm64" ;;
        armv7l|armhf)   NODE_ARCH="armv7l" ;;
        *)              NODE_ARCH="" ;;
      esac
      if [ -n "$NODE_ARCH" ]; then
        NODE_URL="https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-$NODE_ARCH.tar.xz"
        info "installing Node.js from $NODE_URL"
        TMPC="$(mktemp -d)"
        if curl -fsSL --retry 2 -o "$TMPC/node.tar.xz" "$NODE_URL" </dev/null &&
           $SUDO tar -xJf "$TMPC/node.tar.xz" -C /usr/local --strip-components=1; then
          info "installed to /usr/local/bin"
        else
          warn "Node.js tarball install failed"
        fi
        rm -rf "$TMPC"
      fi
    fi

    if ! node_ok; then
      if [ "$DRY_RUN" = "1" ]; then
        info "dry-run: Node.js >= $NODE_MIN_MAJOR would now be installed"
      else
        die "Node.js $NODE_MIN_MAJOR+ with npm is required — install it from https://nodejs.org and re-run"
      fi
    fi
  fi

  NODE_BIN="$(command -v node || true)"
  NPM_BIN="$(command -v npm || true)"
  if [ -z "$NODE_BIN" ] || [ -z "$NPM_BIN" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      NODE_BIN="${NODE_BIN:-/usr/local/bin/node}"
      NPM_BIN="${NPM_BIN:-/usr/local/bin/npm}"
      info "dry-run: using $NODE_BIN / $NPM_BIN"
    else
      die "node/npm not found after installation — install Node.js 20+ from https://nodejs.org and re-run"
    fi
  elif [ "$DRY_RUN" != "1" ]; then
    info "node OK: $NODE_BIN ($("$NODE_BIN" -v)) · npm $("$NPM_BIN" -v 2>/dev/null || echo '?')"
  fi
}

# Ensure `tar` exists — the source tarball (and the Node.js fallback) are unpacked
# with it. Usually already present via the base packages; this is a safety net for
# minimal images that ship without it.
ensure_tar() {
  command -v tar >/dev/null 2>&1 && return 0
  say "tar"
  info "tar not found — installing (needed to unpack the source archive)"
  case "$PM" in
    apt-get)
      x "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y tar </dev/null" || warn "tar install failed"
      ;;
    dnf|yum)
      x "$SUDO $PM install -y tar </dev/null" || warn "tar install failed"
      ;;
    pacman)
      x "$SUDO pacman -Sy --noconfirm tar </dev/null" || warn "tar install failed"
      ;;
    apk)
      x "$SUDO apk add --no-cache tar </dev/null" || warn "tar install failed"
      ;;
    zypper)
      x "$SUDO zypper -n install tar </dev/null" || warn "tar install failed"
      ;;
  esac
  if [ "$DRY_RUN" != "1" ] && ! command -v tar >/dev/null 2>&1; then
    die "tar is required to unpack the source archive — install it and re-run"
  fi
  info "tar OK: $(command -v tar 2>/dev/null || echo tar)"
}

# nginx-rtmp is the fourth video ingest. The distro nginx package does not
# include the RTMP module on every distribution, so install the matching module
# package where it exists. A custom Nginx Plus / hand-built module can be named
# with NGINX_RTMP_MODULE; if neither is present, the engine stays unavailable.
nginx_rtmp_module_present() {
  if [ -n "${NGINX_RTMP_MODULE:-}" ] && [ -f "$NGINX_RTMP_MODULE" ]; then return 0; fi
  for f in /usr/lib/nginx/modules/ngx_rtmp_module.so \
           /usr/lib64/nginx/modules/ngx_rtmp_module.so \
           /usr/share/nginx/modules/ngx_rtmp_module.so \
           /etc/nginx/modules/ngx_rtmp_module.so \
           /usr/local/nginx/modules/ngx_rtmp_module.so; do
    [ -f "$f" ] && return 0
  done
  return 1
}

ensure_nginx_rtmp() {
  if nginx_rtmp_module_present; then
    info "nginx RTMP module already installed"
    return 0
  fi
  say "nginx RTMP module"
  case "$PM" in
    apt-get) xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-rtmp </dev/null" ;;
    dnf|yum) xb "$SUDO $PM install -y nginx-mod-rtmp </dev/null" ;;
    apk)     xb "$SUDO apk add --no-cache nginx-mod-rtmp </dev/null" ;;
    *)       warn "no nginx RTMP module package for '${PM:-none}' — set NGINX_RTMP_MODULE to a module .so or install it manually" ;;
  esac
  if nginx_rtmp_module_present; then
    info "nginx RTMP module ready"
  else
    warn "nginx RTMP module not found — the NGINX RTMP video engine will be unavailable until it is installed"
  fi
}

# Install nginx on every server so a reverse proxy is always available — the
# panel does not need one (PROXY_MODE=none serves directly), but PROXY_MODE=nginx
# only writes a site config, and admins often want nginx there to terminate TLS
# or add locations later. Idempotent (skips when nginx is already present) and
# best-effort: a missing nginx must never abort the install.
ensure_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    info "nginx already installed: $(command -v nginx)"
    ensure_nginx_rtmp
    return 0
  fi
  say "nginx (reverse proxy)"
  info "installing nginx — ready for PROXY_MODE=nginx or your own sites"
  case "$PM" in
    apt-get) xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx </dev/null" ;;
    dnf|yum) xb "$SUDO $PM install -y nginx </dev/null" ;;
    pacman)  xb "$SUDO pacman -S --noconfirm nginx </dev/null" ;;
    apk)     xb "$SUDO apk add --no-cache nginx </dev/null" ;;
    zypper)  xb "$SUDO zypper -n install nginx </dev/null" ;;
    *)       warn "unknown package manager '${PM:-none}' — install nginx manually" ; return 0 ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    info "dry-run: nginx would be available at $(command -v nginx 2>/dev/null || echo /usr/sbin/nginx)"
    return 0
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    warn "nginx could not be installed — the panel still serves on port $PANEL_PORT; PROXY_MODE=nginx needs it"
  fi
  ensure_nginx_rtmp
  info "nginx: $(command -v nginx 2>/dev/null || echo 'not found')"
}

# ---------------------------------------------------------------------------
# Source fetch + production build
#
# 'next build' is memory-hungry: on a small VPS the kernel OOM-kills it and
# the shell reports a bare "Killed". So before building we make sure the box
# has swap (a 2G swap file when RAM is low), and a failed build is fatal — a
# panel without .next cannot start, and silently skipping it produces exactly
# the broken install this function now prevents.
# ---------------------------------------------------------------------------
# Download a source tarball to $1, falling back to the backup host once when the
# primary one does not answer. Used everywhere a tarball is fetched, so an
# install (or an update) keeps working through a DNS or TLS fault on one host.
download_source() {
  DEST="$1"
  x "curl -fsSL --retry 2 -o \"$DEST\" \"$SOURCE_URL\" </dev/null" && return 0
  if [ "$SOURCE_GIVEN" = "0" ] && [ -n "$BACKUP_SOURCE_URL" ] && [ "$BACKUP_SOURCE_URL" != "$SOURCE_URL" ]; then
    warn "could not reach $SOURCE_URL — trying the backup host"
    info "backup: $BACKUP_SOURCE_URL"
    x "curl -fsSL --retry 2 -o \"$DEST\" \"$BACKUP_SOURCE_URL\" </dev/null" && return 0
  fi
  return 1
}

fetch_source() {
  download_source /tmp/lss-src.tar.gz || return 1
  x "tar -xzf /tmp/lss-src.tar.gz -C \"$APP_DIR\" && rm -f /tmp/lss-src.tar.gz" || return 1
}

# Best-effort: give the machine swap before building when RAM is tight.
ensure_build_memory() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ -r /proc/meminfo ] || return 0
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  [ "${mem_kb:-0}" -ge 2097152 ] 2>/dev/null && return 0   # ≥2 GiB RAM — fine
  [ "${swap_kb:-0}" -ge 1048576 ] 2>/dev/null && return 0  # ≥1 GiB swap — fine
  say "Build memory"
  info "only $(( ${mem_kb:-0} / 1024 )) MB RAM — adding a 2G swap file so 'next build' is not OOM-killed"
  SWAPFILE="/swapfile-letsstreamit"
  if [ ! -f "$SWAPFILE" ]; then
    if x "$SUDO sh -c 'fallocate -l 2G $SWAPFILE 2>/dev/null || dd if=/dev/zero of=$SWAPFILE bs=1M count=2048 2>/dev/null; chmod 600 $SWAPFILE; mkswap $SWAPFILE >/dev/null; swapon $SWAPFILE'"; then
      fstab_line="$SWAPFILE none swap sw 0 0"
      x "$SUDO sh -c 'grep -qF \"$fstab_line\" /etc/fstab || echo \"$fstab_line\" >> /etc/fstab'" || true
      info "swap active at $SWAPFILE (persisted in /etc/fstab)"
    else
      warn "could not add swap (needs root) — the build may run out of memory"
    fi
  else
    x "$SUDO swapon $SWAPFILE" || true
  fi
  return 0
}

# Run the production build (with swap in place). Non-zero if npm fails.
build_app() {
  ensure_build_memory
  # The build needs the dev toolchain, not just the runtime dependencies: `tsx`
  # runs the prebuild source-archive step and `typescript` type-checks
  # `next build`. With NODE_ENV=production in the caller's environment — the
  # panel's one-click updater inherits it — npm omits devDependencies, so a
  # plain `npm install` leaves `tsx` out and the build dies with
  # "sh: 1: tsx: not found". `@tailwindcss/postcss` is checked too because
  # releases before 1.1.1 kept it in devDependencies. Put the whole build
  # toolchain back rather than failing an otherwise healthy install.
  if [ ! -d "$APP_DIR/node_modules/tsx" ] || [ ! -d "$APP_DIR/node_modules/@tailwindcss/postcss" ]; then
    info "the build toolchain is missing — installing build dependencies"
    x "cd \"$APP_DIR\" && \"$NPM_BIN\" install --include=dev </dev/null" || return 1
  fi
  x "cd \"$APP_DIR\" && \"$NPM_BIN\" run build"
}

panel_up() {
  curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PANEL_PORT/setup" 2>/dev/null
}

# Work out the address to show in the URL hints so the summary prints a real
# link instead of a "<server>" placeholder. Order: an explicit SERVER_IP, then
# the host's own IPv4, then the default-route source address, then a public IP
# lookup. Always succeeds — falls back to the placeholder.
resolve_server_ip() {
  if [ -n "${SERVER_IP:-}" ] && [ "$SERVER_IP" != "<server>" ]; then return 0; fi
  SERVER_IP=""
  # Link-local (169.254.x) addresses are skipped — they are not reachable from
  # other machines, so a public-IP lookup is preferred when only one exists.
  if command -v hostname >/dev/null 2>&1; then
    for ip in $(hostname -I 2>/dev/null || true); do
      case "$ip" in *:*|127.*|169.254.*|"") continue ;; esac
      SERVER_IP="$ip"
      break
    done
  fi
  if [ -z "$SERVER_IP" ] && command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    case "$ip" in ""|127.*|169.254.*) ;; *) SERVER_IP="$ip" ;; esac
  fi
  if [ -z "$SERVER_IP" ] && command -v curl >/dev/null 2>&1; then
    SERVER_IP="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$SERVER_IP" ]; then SERVER_IP="<server>"; fi
}

# Whether PANEL_PORTS asks the panel to answer on port 80 itself. The values are
# the ones the panel understands (src/lib/panel-ports.ts); normalised to `,80,`
# first so a port like 8000 or 8080 is never mistaken for it.
panel_port_80_wanted() {
  case ",$(printf '%s' "$PANEL_PORTS" | tr '+ ' ','),," in
    *",80,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The same question for 443 — the port the panel serves its own https on. Read
# from the same normalised list, so `443`, `80+443+3000` and `443+3000` all count
# and `8443` never does.
panel_port_443_wanted() {
  case ",$(printf '%s' "$PANEL_PORTS" | tr '+ ' ','),," in
    *",443,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The panel's own inbound ports as the summary names them: the direct mode's list
# (`3000`, or `3000/80`), or what the proxy in front listens on.
panel_exposure_ports() {
  case "$PROXY_MODE" in
    nginx)  printf '%s' "80" ;;
    caddy)  printf '%s' "80/443" ;;
    tunnel) printf '%s' "none" ;;
    *)      printf '%s' "$(panel_ports_direct | tr ' ' '/')" ;;
  esac
}

# The panel's own inbound ports in direct mode: PANEL_PORT, plus 80 and 443 when
# the operator asked for them.
panel_ports_direct() {
  ports=""
  if [ "$PANEL_PORT" != "80" ] && panel_port_80_wanted; then
    ports="$ports 80"
  fi
  if [ "$PANEL_PORT" != "443" ] && panel_port_443_wanted; then
    ports="$ports 443"
  fi
  printf '%s' "$(printf '%s %s' "$PANEL_PORT" "$ports" | tr -s ' ' | sed 's/ $//')"
}

# The distribution's nginx is started by its own package and answers on port 80
# with the stock welcome page (and on 443 wherever a site has been configured
# there). When the panel itself is asked to answer on 80 or 443 (PANEL_PORTS) and
# no proxy mode is in use, nginx is in the way of the listeners the panel opens
# itself — so nginx is stopped here. Stopped, not disabled: it is installed on
# every server on purpose, and PROXY_MODE=nginx later only writes a config and
# reloads it.
release_web_ports() {
  case "$PROXY_MODE" in none|"") ;; *) return 0 ;; esac
  if ! panel_port_80_wanted && ! panel_port_443_wanted; then return 0; fi
  if [ "$PANEL_PORT" = "80" ] && ! panel_port_443_wanted; then return 0; fi
  if [ "$PANEL_PORT" = "443" ] && ! panel_port_80_wanted; then return 0; fi
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-active --quiet nginx 2>/dev/null; then
    return 0
  fi
  held="80"
  panel_port_80_wanted || held=""
  if panel_port_443_wanted; then
    held="${held:+$held and }443"
  fi
  say "Ports $held"
  info "the panel answers on $held itself, so nginx is stopped to free $([ "$held" = "80" ] && printf 'port 80' || printf 'them') (it stays installed)"
  x "$SUDO systemctl stop nginx" || warn "could not stop nginx — $held stays with it"
}

# The ports that must be reachable from the internet for the chosen exposure
# mode. Direct mode needs PANEL_PORT (and 80 when PANEL_PORTS asks for it); a proxy
# mode needs only 80 (and 443 for TLS); a tunnel needs no inbound port for the
# panel at all. The station range, FTP and both RTMP ingests are added by the
# two functions below — they are needed whatever the panel is exposed through.
public_ports() {
  case "$PROXY_MODE" in
    none)   printf '%s %s %s %s %s %s' "$(panel_ports_direct)" "$VIDEO_RTMP_PORT" "$SRS_RTMP_PORT" "$RED5_RTMP_PORT" "$RED5_FREE_RTMP_PORT" "$NGINX_RTMP_PORT" ;;
    nginx)  printf '%s %s %s %s %s %s' "80" "$VIDEO_RTMP_PORT" "$SRS_RTMP_PORT" "$RED5_RTMP_PORT" "$RED5_FREE_RTMP_PORT" "$NGINX_RTMP_PORT" ;;
    caddy)  printf '%s %s %s %s %s %s %s' "80" "443" "$VIDEO_RTMP_PORT" "$SRS_RTMP_PORT" "$RED5_RTMP_PORT" "$RED5_FREE_RTMP_PORT" "$NGINX_RTMP_PORT" ;;
    tunnel) printf '%s %s %s %s %s' "$VIDEO_RTMP_PORT" "$SRS_RTMP_PORT" "$RED5_RTMP_PORT" "$RED5_FREE_RTMP_PORT" "$NGINX_RTMP_PORT" ;;   # panel needs no inbound port
    *)      printf '%s %s %s %s %s %s' "$(panel_ports_direct)" "$VIDEO_RTMP_PORT" "$SRS_RTMP_PORT" "$RED5_RTMP_PORT" "$RED5_FREE_RTMP_PORT" "$NGINX_RTMP_PORT" ;;
  esac
}

# Whether a value is a usable TCP port number. A firewall rule built from a typo
# (`STATION_PORT_MAX=90000`, `FTP_PORT=2121x`) is refused here instead of handed to
# ufw, which would fail one rule and leave the rest of the install looking fine.
valid_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# The ports to open as single rules: the panel's own exposure (mode-dependent),
# both RTMP ingests, and FTP's control port unless FTP was skipped.
firewall_single_ports() {
  PORTS="$(public_ports)"
  if [ "$OPEN_FTP" = "1" ] && valid_port "$FTP_PORT"; then
    PORTS="$PORTS $FTP_PORT"
  fi
  printf '%s' "$PORTS"
}

# The ranges to open, written `min:max` (ufw's syntax — the firewalld branch
# swaps the colon for the dash it wants). The station range is always opened: DJs
# publish to a station's own port with BUTT/Mixxx/Winamp and the tune-in links
# hand listeners the engine's port. FTP's passive range comes with it, because a
# transfer's data connection is made on one of those ports, not on the control one.
firewall_ranges() {
  RANGES=""
  if valid_port "$STATION_PORT_MIN" && valid_port "$STATION_PORT_MAX" && [ "$STATION_PORT_MIN" -le "$STATION_PORT_MAX" ]; then
    RANGES="$STATION_PORT_MIN:$STATION_PORT_MAX"
  else
    warn "STATION_PORT_MIN=$STATION_PORT_MIN / STATION_PORT_MAX=$STATION_PORT_MAX is not a port range — the station range is not opened here; set the pair the panel uses and re-run"
  fi
  if [ "$OPEN_FTP" = "1" ]; then
    if valid_port "$FTP_PASSIVE_MIN" && valid_port "$FTP_PASSIVE_MAX" && [ "$FTP_PASSIVE_MIN" -le "$FTP_PASSIVE_MAX" ]; then
      RANGES="$RANGES $FTP_PASSIVE_MIN:$FTP_PASSIVE_MAX"
    else
      warn "FTP_PASSIVE_MIN=$FTP_PASSIVE_MIN / FTP_PASSIVE_MAX=$FTP_PASSIVE_MAX is not a port range — the FTP passive range is not opened here"
    fi
  fi
  printf '%s' "$RANGES"
}

# Every port and range this install needs, as one string — what the firewall is
# given, and what the summary names.
firewall_list() {
  LIST="$(firewall_single_ports)"
  RANGES="$(firewall_ranges)"
  if [ -n "$RANGES" ]; then
    LIST="$LIST $RANGES"
  fi
  printf '%s' "$LIST"
}

# Best-effort: open every port this install needs on the host firewall — the
# panel's own ports, the station range, FTP (control + passive) and every RTMP
# ingest (MediaMTX, SRS, NGINX RTMP, plus Red5 Pro's port for operators who
# install a licensed archive). The panel's port check reports the host firewall
# for the MediaMTX and SRS RTMP ports (src/lib/port-check.ts); the NGINX RTMP and
# optional Red5 Pro ports are opened here but not probed there. A row that reads
# "not allowed through the host firewall" on the first page an operator sees is
# a rule this step could not add.
# Cloud provider security groups / NAT are outside the script's reach, so only ufw
# and firewalld are covered; anything else is named in the summary with the ports
# to allow by hand. `OPEN_FIREWALL=0` leaves the rules to whoever manages them.
open_firewall() {
  if [ "$OPEN_FIREWALL" != "1" ]; then
    say "Firewall"
    info "OPEN_FIREWALL=0 — no rules added; allow these yourself:"
    info "  single ports: $(firewall_single_ports)"
    info "  ranges:       $(firewall_ranges)"
    FIREWALL_LINE="OPEN_FIREWALL=0 — nothing was changed; allow $(firewall_list)/tcp yourself"
    return 0
  fi

  PORTS="$(firewall_single_ports)"
  RANGES="$(firewall_ranges)"
  if [ -z "$PORTS$RANGES" ]; then
    if [ "$PROXY_MODE" = "tunnel" ]; then
      say "Firewall"
      info "tunnel mode opens no inbound port — nothing to allow"
    fi
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi '^Status: active'; then
    say "Firewall (ufw)"
    for p in $PORTS; do
      x "$SUDO ufw allow $p/tcp" || warn "could not add a ufw rule for $p/tcp"
    done
    for r in $RANGES; do
      x "$SUDO ufw allow $r/tcp" || warn "could not add a ufw rule for $r/tcp"
    done
    info "allowed $(firewall_list)/tcp in ufw"
    FIREWALL_LINE="ufw: allowed $(firewall_list)/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    say "Firewall (firewalld)"
    for p in $PORTS; do
      x "$SUDO firewall-cmd --permanent --add-port=$p/tcp" || warn "could not add a firewalld rule for $p/tcp"
    done
    for r in $RANGES; do
      # firewalld writes a range with a dash where ufw writes a colon.
      RANGE_FW="$(printf '%s' "$r" | tr ':' '-')"
      x "$SUDO firewall-cmd --permanent --add-port=$RANGE_FW/tcp" || warn "could not add a firewalld rule for $RANGE_FW/tcp"
    done
    x "$SUDO firewall-cmd --reload" || warn "firewalld reload failed"
    info "allowed $(firewall_list)/tcp in firewalld"
    FIREWALL_LINE="firewalld: allowed $(firewall_list)/tcp"
  else
    # Not a pass: with no host firewall to read, the provider's security group is
    # the only thing between this host and the internet, and the port check will
    # say the same thing from inside the panel.
    info "no active ufw or firewalld on this host — allow $(firewall_list)/tcp at your provider (security group / firewall)"
    FIREWALL_LINE="no ufw or firewalld active here — allow $(firewall_list)/tcp at your provider"
  fi
}

wait_for_panel() {
  resolve_server_ip
  if [ "$DRY_RUN" = "1" ]; then
    x "wait until http://127.0.0.1:$PANEL_PORT/setup responds"
    return 0
  fi
  info "waiting for http://127.0.0.1:$PANEL_PORT/setup …"
  tries=0
  while [ "$tries" -lt 60 ]; do
    if panel_up; then
      info "the panel is up — open $(public_scheme)://$(public_host)$(public_port_suffix)/setup"
      # Surface the wizard's own availability check so a database problem shows
      # up here in the install log, not only in the browser.
      SETUP_CHECK="$(curl -fsS --max-time 5 "http://127.0.0.1:$PANEL_PORT/api/setup" 2>/dev/null || true)"
      if [ -n "$SETUP_CHECK" ]; then
        info "setup check: $SETUP_CHECK"
        case "$SETUP_CHECK" in
          *error*)
            # The panel explains the real cause (e.g. a failed migration) in its
            # own log — print it so a broken install is diagnosable in one place.
            if [ -f "$PANEL_LOG" ]; then
              info "recent panel log ($PANEL_LOG):"
              tail -n 15 "$PANEL_LOG" 2>/dev/null | while IFS= read -r line; do info "  $line"; done
            fi
            ;;
        esac
      fi
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done
  warn "the panel did not respond within 60s"
  info "logs: $PANEL_LOG  ·  systemd: systemctl status letsstreamit"
  return 0
}

bg_start() {
  if [ -f "$PANEL_PID_FILE" ]; then
    kill "$(cat "$PANEL_PID_FILE")" 2>/dev/null || true
    rm -f "$PANEL_PID_FILE"
    sleep 1
  fi
  if panel_up; then
    warn "port $PANEL_PORT already has a listener we don't manage — stop it and re-run to take over"
    return 0
  fi
  info "starting in the background (log: $PANEL_LOG)"
  (
    cd "$APP_DIR" || exit 1
    PORT="$PANEL_PORT" PANEL_PORTS="$PANEL_PORTS" nohup "$NPM_BIN" run start >> "$PANEL_LOG" 2>&1 &
    echo $! > "$PANEL_PID_FILE"
  )
}

# Public hostname to print in links: DOMAIN when set, else the resolved IP.
public_host() {
  if [ "$PROXY_MODE" = "tunnel" ] && [ -n "$TUNNEL_URL" ]; then
    printf '%s' "${TUNNEL_URL#*://}"
  elif [ -n "$DOMAIN" ]; then printf '%s' "$DOMAIN"; else printf '%s' "$SERVER_IP"; fi
}

# Scheme the public URL uses. Caddy and Cloudflare Tunnel terminate TLS, so the
# panel is reached over https; the other modes serve plain http.
public_scheme() {
  case "$PROXY_MODE" in
    caddy) printf '%s' "https" ;;
    tunnel)
      if [ -n "$TUNNEL_URL" ]; then printf '%s' "${TUNNEL_URL%%://*}"; else printf '%s' "https"; fi
      ;;
    *) printf '%s' "http" ;;
  esac
}

# Port suffix for the public URL — omitted for the proxy/tunnel modes (which use
# 80/443 or no port at all) and included for a direct PANEL_PORT listener.
public_port_suffix() {
  case "$PROXY_MODE" in
    none) printf '%s' ":$PANEL_PORT" ;;
    *)    printf '%s' "" ;;
  esac
}

# Install and configure the reverse proxy for providers that only allow 80/443.
# Runs as root (a proxy binds privileged ports). Safe to re-run.
setup_proxy() {
  case "$PROXY_MODE" in
    none) return 0 ;;
    caddy|nginx|tunnel) ;;
    *) die "unknown PROXY_MODE '$PROXY_MODE' (use none, nginx, caddy or tunnel)" ;;
  esac

  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ] && [ "$DRY_RUN" != "1" ]; then
    warn "PROXY_MODE=$PROXY_MODE needs root to install and run the proxy — skipping it"
    PROXY_MODE="none"
    return 0
  fi

  if [ -z "$DOMAIN" ]; then
    resolve_server_ip
    DOMAIN="$SERVER_IP"
    if [ "$DOMAIN" = "<server>" ]; then
      warn "PROXY_MODE=$PROXY_MODE needs a hostname — set DOMAIN=radio.example.com; skipping the proxy"
      PROXY_MODE="none"
      return 0
    fi
    warn "DOMAIN not set — using $DOMAIN (no TLS without a real domain)"
  fi

  # PROXY_MODE=tunnel — Cloudflare Tunnel: cloudflared dials out, no inbound port.
  if [ "$PROXY_MODE" = "tunnel" ]; then
    if [ -z "$TUNNEL_TOKEN" ] && [ "$DRY_RUN" != "1" ]; then
      warn "tunnel mode needs TUNNEL_TOKEN (Cloudflare Zero Trust → Networks → Tunnels) — skipping"
      PROXY_MODE="none"
      return 0
    fi
    say "Cloudflare Tunnel (no inbound ports)"
    if ! command -v cloudflared >/dev/null 2>&1; then
      case "$PM" in
        apt-get)
          x "$SUDO mkdir -p --mode=0755 /usr/share/keyrings"
          xb "curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null"
          xb "curl -fsSL https://pkg.cloudflare.com/cloudflared/any/cloudflared.list | $SUDO tee /etc/apt/sources.list.d/cloudflared.list >/dev/null"
          xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update </dev/null"
          xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared </dev/null"
          ;;
        dnf|yum)
          xb "curl -fsSL https://pkg.cloudflare.com/cloudflared/cloudflared-rpm.repo | $SUDO tee /etc/yum.repos.d/cloudflared.repo >/dev/null"
          xb "$SUDO $PM install -y cloudflared </dev/null"
          ;;
        pacman) xb "$SUDO pacman -S --noconfirm cloudflared </dev/null" ;;
        apk)    xb "$SUDO apk add --no-cache cloudflared </dev/null" ;;
        zypper) xb "$SUDO zypper -n install cloudflared </dev/null" ;;
      esac
    fi
    if ! command -v cloudflared >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
      warn "cloudflared could not be installed — install it from https://developers.cloudflare.com/cloudflare-one/ and re-run"
      PROXY_MODE="none"
      return 0
    fi
    # `cloudflared service install <token>` writes the systemd unit and starts it.
    # The token already encodes the tunnel UUID and the public hostname mapping,
    # so the tunnel routes to the panel without any local config.
    if [ "$DRY_RUN" = "1" ]; then
      x "cloudflared service install <TUNNEL_TOKEN>   # dials out; no inbound port"
      x "configure the tunnel's public hostname → http://localhost:$PANEL_PORT"
    else
      if $SUDO cloudflared service install "$TUNNEL_TOKEN" </dev/null; then
        info "cloudflared installed and started (systemctl status cloudflared)"
      else
        warn "cloudflared service install failed — check the TUNNEL_TOKEN"
        PROXY_MODE="none"
        return 0
      fi
    fi
    info "Cloudflare Tunnel → 127.0.0.1:$PANEL_PORT (no ports opened on this host)"
    return 0
  fi

  if [ "$PROXY_MODE" = "nginx" ]; then
    say "Reverse proxy (nginx → 127.0.0.1:$PANEL_PORT)"
    # Already installed by every install — this is a no-op unless it is missing.
    ensure_nginx
    CONF_DIR=""
    if [ -d /etc/nginx/conf.d ]; then
      CONF_DIR="/etc/nginx/conf.d"
    elif [ -d /etc/nginx/sites-available ]; then
      CONF_DIR="/etc/nginx/sites-available"
    fi
    if [ -z "$CONF_DIR" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        CONF_DIR="/etc/nginx/conf.d"
      else
        warn "nginx config directory not found — skipping the proxy"
        PROXY_MODE="none"
        return 0
      fi
    fi
    CONF_FILE="$CONF_DIR/letsstreamit.conf"
    # Where the panel publishes the pair it issued, inside nginx's own tree
    # (src/lib/nginx.ts, publishCertificateToNginx): the site config below and
    # the certificate it names then live in the same place, nginx never reads
    # outside /etc/nginx, and the pair survives a prune of the app's runtime
    # directory.
    NGINX_CERT_DIR="/etc/nginx/ssl/letsstreamit"
    # ...and where the panel writes it first: <runtime>/certs/letsencrypt. The
    # runtime root is $BASE_DIR/stations (src/lib/streams.ts), so `stations` is
    # part of the path — the earlier value left it out, which pointed this block
    # at a directory the panel has never written, so re-running the installer on
    # a host with a certificate still produced no HTTPS site. Read here so a
    # host that already has one gets an HTTPS site from this run; a fresh install
    # usually has none yet, and the panel rewrites this same file on the first
    # issuance (src/lib/nginx.ts).
    if [ -w /var/lib/letsstreamit ] || [ -d /var/lib/letsstreamit ]; then
      CERT_DIR="/var/lib/letsstreamit/stations/certs/letsencrypt"
    else
      CERT_DIR="$APP_DIR/.data/letsstreamit/stations/certs/letsencrypt"
    fi
    CONF_BODY="$(printf '%s\n' \
      "# LetsStreamIt reverse proxy — generated by install.sh" \
      "server {" \
      "    listen 80;" \
      "    listen [::]:80;" \
      "    server_name $DOMAIN;" \
      "" \
      "    # 1 GB uploads through the proxy — nginx spools the body to disk." \
      "    client_max_body_size 1g;" \
      "" \
      "    location /.well-known/acme-challenge/ {" \
      "        proxy_pass http://127.0.0.1:$PANEL_PORT;" \
      "        proxy_set_header Host \$host;" \
      "    }" \
      "" \
      "    location / {" \
      "        proxy_pass http://127.0.0.1:$PANEL_PORT;" \
      "        proxy_http_version 1.1;" \
      "        proxy_set_header Host \$host;" \
      "        proxy_set_header X-Real-IP \$remote_addr;" \
      "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
      "        proxy_set_header X-Forwarded-Proto \$scheme;" \
      "        proxy_set_header Upgrade \$http_upgrade;" \
      "        proxy_set_header Connection \"upgrade\";" \
      "    }" \
      "}")"
    # Which pair the HTTPS block should name: the copies the panel published
    # into nginx's tree first, and the runtime pair as the fallback for a
    # certificate issued before that publishing existed.
    SSL_CERT=""
    SSL_KEY=""
    if [ -f "$NGINX_CERT_DIR/fullchain.pem" ] && [ -f "$NGINX_CERT_DIR/privkey.pem" ]; then
      SSL_CERT="$NGINX_CERT_DIR/fullchain.pem"
      SSL_KEY="$NGINX_CERT_DIR/privkey.pem"
    elif [ -f "$CERT_DIR/current.pem" ] && [ -f "$CERT_DIR/current.key" ]; then
      SSL_CERT="$CERT_DIR/current.pem"
      SSL_KEY="$CERT_DIR/current.key"
    fi
    # A dry run previews the paths a real run would use when nothing is on disk
    # yet, rather than an empty ssl_certificate line.
    if [ -z "$SSL_CERT" ] && [ "$DRY_RUN" = "1" ]; then
      SSL_CERT="$NGINX_CERT_DIR/fullchain.pem"
      SSL_KEY="$NGINX_CERT_DIR/privkey.pem"
    fi
    # An HTTPS server block, but only when both halves of the certificate are
    # already on disk: `ssl_certificate` naming a missing file makes `nginx -t`
    # fail, and a failed config test here would leave the host with no site at
    # all. Admin → SSL rewrites this file as soon as one is issued.
    if [ "$DRY_RUN" = "1" ] || [ -n "$SSL_CERT" ]; then
      CONF_BODY="$CONF_BODY
$(printf '%s\n' \
        "" \
        "server {" \
        "    listen 443 ssl;" \
        "    listen [::]:443 ssl;" \
        "    http2 on;" \
        "    server_name $DOMAIN;" \
        "" \
        "    # Issued in Admin → Server settings → SSL; renewed in place." \
        "    ssl_certificate     $SSL_CERT;" \
        "    ssl_certificate_key $SSL_KEY;" \
        "    ssl_protocols TLSv1.2 TLSv1.3;" \
        "    ssl_session_cache shared:SSL:10m;" \
        "" \
        "    location / {" \
        "        proxy_pass http://127.0.0.1:$PANEL_PORT;" \
        "        proxy_http_version 1.1;" \
        "        proxy_set_header Host \$host;" \
        "        proxy_set_header X-Real-IP \$remote_addr;" \
        "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
        "        proxy_set_header X-Forwarded-Proto \$scheme;" \
        "        proxy_set_header Upgrade \$http_upgrade;" \
        "        proxy_set_header Connection \"upgrade\";" \
        "    }" \
        "}")"
      if [ -n "$SSL_KEY" ] && [ -f "$SSL_KEY" ]; then
        x "$SUDO chmod 640 \"$SSL_KEY\"   # nginx workers must read it"
      fi
    fi
    if [ "$DRY_RUN" = "1" ]; then
      x "write nginx site config → $CONF_FILE"
    else
      printf '%s\n' "$CONF_BODY" | $SUDO tee "$CONF_FILE" >/dev/null || { warn "could not write $CONF_FILE"; PROXY_MODE="none"; return 0; }
    fi
    # sites-enabled symlink on Debian-style layouts.
    if [ "$CONF_DIR" = "/etc/nginx/sites-available" ] && [ -d /etc/nginx/sites-enabled ]; then
      x "$SUDO ln -sf $CONF_FILE /etc/nginx/sites-enabled/letsstreamit.conf"
    fi
    if command -v nginx >/dev/null 2>&1; then
      $SUDO nginx -t >/dev/null 2>&1 || warn "nginx config test failed — check $CONF_FILE"
    fi
    # nginx has no memory_limit directive: what a worker holds is its buffers, and
    # with the 1 GB body limit above a large request is spooled to disk instead of
    # being kept in RAM. What can still grow is the service as a whole (one worker
    # per core, each with its own buffers), so the ceiling is applied where nginx is
    # actually accounted for — a systemd drop-in that caps all workers together at
    # 512 MB. MemoryHigh throttles first and MemoryMax is the hard wall, so a busy
    # proxy slows down before it is killed.
    NGINX_DROPIN_DIR="/etc/systemd/system/nginx.service.d"
    NGINX_DROPIN="$NGINX_DROPIN_DIR/memory.conf"
    NGINX_LIMIT="$(printf '%s\n' \
      "[Service]" \
      "# Written by the LetsStreamIt installer — cap the reverse proxy at 512 MB." \
      "MemoryHigh=512M" \
      "MemoryMax=512M")"
    if [ "$DRY_RUN" = "1" ]; then
      x "write $NGINX_DROPIN (MemoryHigh=512M, MemoryMax=512M)"
    elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      if $SUDO mkdir -p "$NGINX_DROPIN_DIR" &&
         printf '%s\n' "$NGINX_LIMIT" | $SUDO tee "$NGINX_DROPIN" >/dev/null; then
        $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
        # try-restart applies the cgroup limits to an nginx that is already running,
        # and does nothing when it is not — `enable --now` starts it below.
        $SUDO systemctl try-restart nginx >/dev/null 2>&1 || true
        info "nginx capped at 512 MB of memory (systemctl show nginx -p MemoryMax)"
      else
        warn "could not write $NGINX_DROPIN — nginx runs without a memory ceiling"
      fi
    else
      info "no systemd on this host — the nginx memory cap was skipped"
    fi
    x "$SUDO systemctl enable --now nginx" || xb "$SUDO service nginx restart"
    if [ "$DRY_RUN" != "1" ] && command -v systemctl >/dev/null 2>&1; then
      $SUDO systemctl reload nginx >/dev/null 2>&1 || $SUDO systemctl restart nginx >/dev/null 2>&1 || true
    fi
    if [ -f "$CERT_DIR/current.pem" ] || [ "$DRY_RUN" = "1" ]; then
      info "nginx proxies https://$DOMAIN (and http:// for ACME) → 127.0.0.1:$PANEL_PORT"
    else
      info "nginx proxies http://$DOMAIN → 127.0.0.1:$PANEL_PORT — issue a certificate in Admin → Server settings → SSL and the HTTPS site is written for you"
    fi
    return 0
  fi

  # PROXY_MODE=caddy — automatic HTTPS on 80/443.
  say "Reverse proxy + TLS (Caddy → 127.0.0.1:$PANEL_PORT)"
  if ! command -v caddy >/dev/null 2>&1; then
    case "$PM" in
      apt-get)
        xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg </dev/null"
        xb "curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
        xb "curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list"
        xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update </dev/null"
        xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y caddy </dev/null"
        ;;
      dnf|yum) xb "$SUDO $PM install -y 'dnf-command(copr)' </dev/null"; xb "$SUDO $PM copr enable -y @caddy/caddy </dev/null"; xb "$SUDO $PM install -y caddy </dev/null" ;;
      pacman)  xb "$SUDO pacman -S --noconfirm caddy </dev/null" ;;
      apk)     xb "$SUDO apk add --no-cache caddy </dev/null" ;;
      zypper)  xb "$SUDO zypper -n install caddy </dev/null" ;;
    esac
  fi
  if ! command -v caddy >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    warn "caddy could not be installed — skipping the proxy"
    PROXY_MODE="none"
    return 0
  fi
  CONF_BODY="$(printf '%s\n' \
    "# LetsStreamIt — generated by install.sh" \
    "$DOMAIN {" \
    "    reverse_proxy 127.0.0.1:$PANEL_PORT" \
    "}")"
  x "$SUDO mkdir -p /etc/caddy"
  if [ "$DRY_RUN" = "1" ]; then
    x "write Caddyfile → /etc/caddy/Caddyfile"
  else
    printf '%s\n' "$CONF_BODY" | $SUDO tee /etc/caddy/Caddyfile >/dev/null || { warn "could not write /etc/caddy/Caddyfile"; PROXY_MODE="none"; return 0; }
  fi
  x "$SUDO systemctl enable --now caddy" || xb "$SUDO service caddy restart"
  if [ "$DRY_RUN" != "1" ] && command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl reload caddy >/dev/null 2>&1 || $SUDO systemctl restart caddy >/dev/null 2>&1 || true
  fi
  info "Caddy proxies https://$DOMAIN → 127.0.0.1:$PANEL_PORT (auto TLS)"
}

# Start (or restart) the panel so /setup loads when the installer exits.
start_panel() {
  say "Starting the panel"
  release_web_ports
  if [ "$DRY_RUN" = "1" ]; then
    x "start panel from $APP_DIR on 0.0.0.0:$PANEL_PORT (systemd unit 'letsstreamit', or nohup → $PANEL_LOG)"
    return 0
  fi
  if [ ! -f "$APP_DIR/package.json" ]; then
    warn "no app at $APP_DIR — panel not started"
    return 0
  fi

  if { [ "$(id -u)" = "0" ] || [ -n "$SUDO" ]; } &&
     command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    UNIT="/etc/systemd/system/letsstreamit.service"
    UNIT_BODY="$(printf '%s\n' \
      "[Unit]" \
      "Description=LetsStreamIt radio control panel" \
      "After=network.target postgresql.service" \
      "Wants=postgresql.service" \
      "" \
      "[Service]" \
      "Type=simple" \
      "WorkingDirectory=$APP_DIR" \
      "Environment=PORT=$PANEL_PORT" \
      "Environment=PANEL_PORTS=$PANEL_PORTS" \
      "EnvironmentFile=-$APP_DIR/.env.local" \
      "ExecStart=$NPM_BIN run start" \
      "Restart=on-failure" \
      "RestartSec=3" \
      "" \
      "[Install]" \
      "WantedBy=multi-user.target")"
    if [ "$(cat "$UNIT" 2>/dev/null || true)" != "$UNIT_BODY" ]; then
      info "installing systemd unit → $UNIT"
      printf '%s\n' "$UNIT_BODY" | $SUDO tee "$UNIT" >/dev/null
    fi
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable letsstreamit >/dev/null 2>&1 || true
    if $SUDO systemctl restart letsstreamit; then
      info "panel managed by systemd (systemctl status letsstreamit)"
      return 0
    fi
    warn "systemctl restart failed — falling back to a background start"
  fi

  bg_start
}

# ---------------------------------------------------------------------------
# Mode dispatch: `uninstall` removes what the installer created and exits.
#
# `curl … | sh -s -- uninstall` cannot prompt for confirmation, so without
# UNINSTALL=yes the flow prints the full plan and exits without removing
# anything. DRY_RUN=1 prints every action instead of running it.
# ---------------------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
  say "Uninstall LetsStreamIt ($APP_DIR)"

  # Data directory — the same rule the app uses (streams.ts writableBase()).
  DATA_DIR=""
  if [ -d /var/lib/letsstreamit ]; then
    DATA_DIR="/var/lib/letsstreamit"
  elif [ -d "$APP_DIR/.data/letsstreamit" ]; then
    DATA_DIR="$APP_DIR/.data/letsstreamit"
  fi

  if [ "$UNINSTALL" != "yes" ]; then
    info "Planned actions (nothing has been removed):"
    info "  1. stop the panel   — systemd unit 'letsstreamit' + $PANEL_PID_FILE"
    info "  2. stop engines     — pids recorded under ${DATA_DIR:-/var/lib/letsstreamit}"
    info "  3. drop database    — '$DB_NAME' + role '$DB_USER'"
    info "  4. delete data      — ${DATA_DIR:-/var/lib/letsstreamit} (media, stations, TLS certs)"
    info "  5. delete engines  — $SC_DIR, $SC1_DIR, $IKH_DIR and $RSAS_HOME (downloaded/build engines)"
    info "  6. delete the app   — $APP_DIR (source, node_modules, .env.local, logs)"
    info "  7. delete proxy     — nginx/Caddy site config + the nginx memory drop-in created by PROXY_MODE (if any)"
    info "System packages (PostgreSQL, Icecast2, Liquidsoap, nginx, ffmpeg, MediaMTX, SRS, NGINX RTMP, Node.js, Caddy) are left installed."
    info "Red5 Pro is left untouched only if you installed a licensed archive at $RED5_HOME."
    info "Red5 Free is left at $RED5_FREE_HOME (remove it manually if you no longer want the open-source server)."
    info ""
    info "Preview:  curl -fsSL $INSTALL_URL | DRY_RUN=1 UNINSTALL=yes sh -s -- uninstall"
    info "Remove:   curl -fsSL $INSTALL_URL | UNINSTALL=yes sh -s -- uninstall"
    exit 0
  fi

  if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
    die "root privileges required — rerun as: curl -fsSL …/install.sh | UNINSTALL=yes sudo -E sh -s -- uninstall"
  fi

  # 1) Panel: systemd unit and/or background pid file.
  say "Stopping the panel"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    xb "$SUDO systemctl stop letsstreamit"
    xb "$SUDO systemctl disable letsstreamit"
    x  "$SUDO rm -f /etc/systemd/system/letsstreamit.service"
    xb "$SUDO systemctl daemon-reload"
  else
    info "systemd not available — skipping the unit"
  fi
  if [ -f "$PANEL_PID_FILE" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      x "kill \$(cat \"$PANEL_PID_FILE\") 2>/dev/null; rm -f \"$PANEL_PID_FILE\""
    else
      kill "$(cat "$PANEL_PID_FILE")" 2>/dev/null || true
      rm -f "$PANEL_PID_FILE"
      info "stopped the background panel (pid file removed)"
    fi
  else
    info "no background panel pid file at $PANEL_PID_FILE"
  fi

  # 2) Station engines: every pid file the panel recorded under the data dir.
  say "Stopping stream engines"
  if [ -n "$DATA_DIR" ]; then
    PID_FILES="$(find "$DATA_DIR" -name '*.pid' 2>/dev/null || true)"
    if [ -z "$PID_FILES" ]; then
      info "no engine pid files under $DATA_DIR"
    else
      for pf in $PID_FILES; do
        if [ "$DRY_RUN" = "1" ]; then
          x "kill \$(cat \"$pf\") 2>/dev/null; rm -f \"$pf\""
        else
          kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null || true
          rm -f "$pf"
        fi
      done
      if [ "$DRY_RUN" != "1" ]; then info "stopped the engines recorded in $DATA_DIR"; fi
    fi
  else
    info "no data directory found — nothing to stop"
  fi

  # 3) Database + role provisioned by the installer.
  say "Database"
  PG_PSQL=""
  if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1; then
    PG_PSQL="runuser -u postgres -- psql"
  elif command -v sudo >/dev/null 2>&1; then
    PG_PSQL="sudo -u postgres psql"
  fi
  if [ -z "$PG_PSQL" ]; then
    warn "cannot run psql as the postgres user — drop '$DB_NAME' and role '$DB_USER' manually"
  else
    xb "$PG_PSQL -c \"DROP DATABASE IF EXISTS $DB_NAME\""
    xb "$PG_PSQL -c \"DROP ROLE IF EXISTS $DB_USER\""
    if [ "$DRY_RUN" != "1" ]; then info "dropped database '$DB_NAME' and role '$DB_USER'"; fi
  fi

  # 4) Data directory (media, station runtime, TLS certs).
  say "Data directory"
  if [ -n "$DATA_DIR" ]; then
    x "$SUDO rm -rf \"$DATA_DIR\""
  else
    info "none found"
  fi

  # 5) Engine binaries the installer put in /opt — both Shoutcast servers, the
  #    Icecast KH build and RSAS (the distribution's Icecast 2 is a package and stays).
  for d in "$SC_DIR" "$SC1_DIR" "$IKH_DIR" "$RSAS_HOME"; do
    if [ -d "$d" ]; then x "$SUDO rm -rf \"$d\""; fi
  done

  # 6) Reverse-proxy site config created by PROXY_MODE (nginx/Caddy).
  say "Reverse proxy"
  removed_proxy=0
  for f in /etc/nginx/conf.d/letsstreamit.conf /etc/nginx/sites-available/letsstreamit.conf /etc/nginx/sites-enabled/letsstreamit.conf; do
    if [ -e "$f" ]; then x "$SUDO rm -f \"$f\""; removed_proxy=1; fi
  done
  # The certificate the panel published into nginx's own tree (src/lib/nginx.ts).
  # It is ours and it holds a private key, so it is removed with the site config
  # rather than left behind for the next tenant of this host.
  if [ -d /etc/nginx/ssl/letsstreamit ]; then
    x "$SUDO rm -rf /etc/nginx/ssl/letsstreamit"
    removed_proxy=1
  fi
  # The memory drop-in is ours — identified by its marker, so a hand-written
  # drop-in in the same directory is left alone.
  if [ -f /etc/systemd/system/nginx.service.d/memory.conf ] &&
     $SUDO grep -q "Written by the LetsStreamIt installer" /etc/systemd/system/nginx.service.d/memory.conf 2>/dev/null; then
    x "$SUDO rm -f /etc/systemd/system/nginx.service.d/memory.conf"
    xb "$SUDO systemctl daemon-reload"
    removed_proxy=1
  fi
  if [ -f /etc/caddy/Caddyfile ] && $SUDO grep -q "generated by install.sh" /etc/caddy/Caddyfile 2>/dev/null; then
    x "$SUDO rm -f /etc/caddy/Caddyfile"
    removed_proxy=1
  fi
  if command -v cloudflared >/dev/null 2>&1 && [ -f /etc/systemd/system/cloudflared.service ]; then
    x "$SUDO cloudflared service uninstall" || xb "$SUDO systemctl disable --now cloudflared"
    removed_proxy=1
  fi
  if [ "$removed_proxy" = "1" ]; then
    xb "$SUDO systemctl reload nginx"
    xb "$SUDO systemctl reload caddy"
  else
    info "no proxy config created by the installer"
  fi

  # 7) The app itself — only when APP_DIR actually holds the app.
  say "App directory"
  case "$APP_DIR" in
    ""|"/"|"${HOME:-}")
      warn "refusing to remove '$APP_DIR'"
      ;;
    *)
      if [ -f "$APP_DIR/package.json" ]; then
        x "$SUDO rm -rf \"$APP_DIR\""
      else
        info "no app at $APP_DIR — nothing to remove"
      fi
      ;;
  esac

  say "Uninstall complete"
  info "Removed: panel service, station engines, database '$DB_NAME', data directory, app directory."
  info "Kept: system packages (PostgreSQL, Icecast2, Liquidsoap, nginx, ffmpeg, MediaMTX, SRS, NGINX RTMP, Node.js) — remove them with"
  info "your package manager if nothing else on the server needs them."
  info "Red5 Pro is kept only if you installed a licensed archive at $RED5_HOME."
  info "Red5 Free is kept at $RED5_FREE_HOME (remove it manually if you no longer want the open-source server)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode dispatch: `update` runs its own flow and exits.
# ---------------------------------------------------------------------------
if [ "$MODE" = "update" ]; then
  say "Updating LetsStreamIt ($APP_DIR)"
  # An update writes /usr/local/bin (SRS), /opt (Red5 Free and the other
  # download engines), the app directory and the service unit — the same places
  # a fresh install writes. Without this guard a non-root update finished with
  # "Update complete" while those writes had failed with "permission denied",
  # leaving the panel's Environment card saying "no binary at
  # /usr/local/bin/srs" and "/opt/red5/red5.sh". Sudo with a non-interactive
  # rule is enough; a password cannot be typed into a piped script, so that
  # case is refused with the command that works.
  if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    if [ -z "$SUDO" ] || ! $SUDO -n true 2>/dev/null; then
      die "root privileges required to update — rerun as: curl -fsSL $INSTALL_URL | sudo sh -s -- update"
    fi
  fi
  ensure_node

  ensure_tar

  ensure_nginx

  # Engines that are downloads rather than distribution packages. Idempotent:
  # each one says "already installed" and returns when its binary is present.
  # This is how a server installed before the legacy 1.9.8 or SRS became part of
  # the install picks the binary up — updating the app alone would leave Admin →
  # Server settings → Environment reporting it missing.
  install_shoutcast
  install_shoutcast1
  install_icecast_kh
  install_rsas
  install_srs
  install_red5_pro
  install_red5_free
  install_liquidsoap

  JUST_FETCHED=0
  if [ ! -f "$APP_DIR/package.json" ]; then
    if [ -n "$SOURCE_URL" ]; then
      x "$SUDO mkdir -p \"$APP_DIR\""
      download_source /tmp/lss-src.tar.gz || die "source download failed"
      x "tar -xzf /tmp/lss-src.tar.gz -C \"$APP_DIR\" && rm -f /tmp/lss-src.tar.gz" || die "source unpack failed"
      JUST_FETCHED=1
    else
      die "no app found in $APP_DIR — run a fresh install first (or set APP_DIR / SOURCE_URL)"
    fi
    if [ "$DRY_RUN" != "1" ] && [ ! -f "$APP_DIR/package.json" ]; then
      die "still no package.json in $APP_DIR after fetching the source"
    fi
  fi

  if [ "$JUST_FETCHED" = "0" ]; then
    info "refreshing source from $SOURCE_URL"
    TMPU="$(mktemp -d)"
    if [ "$DRY_RUN" = "1" ]; then
      download_source "$TMPU/src.tar.gz"
      x "tar -xzf \"$TMPU/src.tar.gz\" -C \"$APP_DIR\""
    elif download_source "$TMPU/src.tar.gz"; then
      tar -xzf "$TMPU/src.tar.gz" -C "$APP_DIR" || warn "could not unpack the source archive"
    else
      warn "download failed: $SOURCE_URL — keeping the current source"
    fi
    rm -rf "$TMPU"
  fi

  x "cd \"$APP_DIR\" && \"$NPM_BIN\" install </dev/null" || die "npm install failed"
  if [ "$SKIP_BUILD" != "1" ]; then
    build_app || die "production build failed — usually out of memory during 'next build'. Add swap (done automatically when RAM is low), use a bigger server, or set SKIP_BUILD=1 and build later."
  else
    info "SKIP_BUILD=1 — skipping build"
  fi

  resolve_server_ip
  setup_proxy
  start_panel
  open_firewall
  wait_for_panel

  report_version
  report_install update
  UPDATE_LINE="${MANIFEST_UPDATE:-curl -fsSL $INSTALL_URL | sudo sh -s -- update}"
  say "Update complete"
  info "Panel: $(public_scheme)://$(public_host)$(public_port_suffix)/setup"
  info "Update again: $UPDATE_LINE"
  # The two engines this release can newly provision are named here on purpose:
  # "Update complete" followed by an Environment card that says "no binary at …"
  # is the report these lines answer. Either the path the panel will read, or a
  # warning that points back at the engine's own step above. A dry run installs
  # nothing, so it would only produce two false "still missing" lines.
  if [ "$DRY_RUN" != "1" ]; then
    if [ -x "$SRS_BIN" ]; then
      info "SRS        : $SRS_BIN"
    else
      warn "SRS is still missing at $SRS_BIN — the SRS step above says why (download, unzip, or root permissions)"
    fi
    if red5_free_installed; then
      info "Red5 Free  : $RED5_FREE_HOME/red5.sh"
    else
      warn "Red5 Free is still missing at $RED5_FREE_HOME/red5.sh — the Red5 Free step above says why (download, Java 21, or root permissions)"
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Install mode
# ---------------------------------------------------------------------------
if [ -z "$PM" ] && [ "$DRY_RUN" != "1" ]; then
  die "no supported package manager found (apt/dnf/yum/pacman/apk/zypper)"
fi
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
  die "root privileges required — rerun as: curl -fsSL …/install.sh | sudo sh"
fi
say "Host: $(uname -srm) · package manager: ${PM:-none}"

# ---------------------------------------------------------------------------
# Base packages + PostgreSQL
# ---------------------------------------------------------------------------
say "Base packages + PostgreSQL"
# bash  → NodeSource setup scripts
# xz    → extracts the official Node.js fallback tarball
case "$PM" in
  apt-get)
    xb "$SUDO apt-get update -y"
    x "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip bash xz-utils unzip postgresql </dev/null" \
      || die "base package install failed"
    ;;
  dnf)
    x "$SUDO dnf install -y curl ca-certificates tar gzip bash xz unzip postgresql postgresql-server </dev/null" \
      || die "base package install failed"
    xb "$SUDO postgresql-setup --initdb"
    ;;
  yum)
    xb "$SUDO yum install -y epel-release </dev/null"
    x "$SUDO yum install -y curl ca-certificates tar gzip bash xz unzip postgresql postgresql-server </dev/null" \
      || die "base package install failed"
    xb "$SUDO postgresql-setup --initdb"
    ;;
  pacman)
    x "$SUDO pacman -Sy --noconfirm curl ca-certificates tar gzip bash xz unzip postgresql </dev/null" \
      || die "base package install failed"
    xb "$SUDO -u postgres initdb -D /var/lib/postgresql/data"
    ;;
  apk)
    x "$SUDO apk add --no-cache curl ca-certificates tar gzip bash xz unzip postgresql postgresql-client </dev/null" \
      || die "base package install failed"
    ;;
  zypper)
    x "$SUDO zypper -n install curl ca-certificates tar gzip bash xz unzip postgresql postgresql-server </dev/null" \
      || die "base package install failed"
    ;;
esac

# pgcrypto supplies gen_random_uuid() on PostgreSQL < 13 (built in from 13+).
# Best-effort: a modern server works fine without it.
case "$PM" in
  apt-get) xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-contrib </dev/null" ;;
  dnf|yum) xb "$SUDO $PM install -y postgresql-contrib </dev/null" ;;
  pacman)  xb "$SUDO pacman -S --noconfirm postgresql-contrib </dev/null" ;;
  apk)     xb "$SUDO apk add --no-cache postgresql-contrib </dev/null" ;;
  zypper)  xb "$SUDO zypper -n install postgresql-contrib </dev/null" ;;
esac

# ---------------------------------------------------------------------------
# nginx — always installed, configured only for PROXY_MODE=nginx
# ---------------------------------------------------------------------------
ensure_nginx

# ---------------------------------------------------------------------------
# Stream engines: Icecast2 + Liquidsoap
# ---------------------------------------------------------------------------
say "Stream engines (Icecast2, Liquidsoap)"
case "$PM" in
  apt-get)
    xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y icecast2 liquidsoap </dev/null" ||
      xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y icecast liquidsoap </dev/null"
    ;;
  dnf|yum)
    xb "$SUDO $PM install -y icecast liquidsoap </dev/null"
    ;;
  pacman)
    xb "$SUDO pacman -S --noconfirm icecast liquidsoap </dev/null"
    ;;
  apk)
    xb "$SUDO apk add --no-cache icecast liquidsoap </dev/null"
    ;;
  zypper)
    xb "$SUDO zypper -n install icecast liquidsoap </dev/null"
    ;;
esac

# Both Shoutcast binaries — the x86_64 DNAS 2 and the legacy 1.9.8 — plus Icecast
# KH, which is a source build, and RSAS, which is an official static download.
# All four are defined above so `update` provisions them too. Liquidsoap is
# checked after them because it is the one engine whose *version* matters: an
# old one plays the station, badly.
install_shoutcast
install_shoutcast1
install_icecast_kh
install_rsas
install_liquidsoap

# ---------------------------------------------------------------------------
# Live video: ffmpeg (test signal / transcoding) + MediaMTX (RTMP -> HLS ingest)
#
# Both are best-effort: audio stations work fine without them, so a failure
# warns instead of aborting.
# ---------------------------------------------------------------------------
say "Live video (ffmpeg, MediaMTX, SRS, Red5 Free; optional Red5 Pro with a licensed archive; NGINX RTMP when the module is installed)"
case "$PM" in
  apt-get)
    xb "$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y ffmpeg </dev/null" \
      || warn "ffmpeg install failed — video test signal unavailable"
    ;;
  dnf|yum) xb "$SUDO $PM install -y ffmpeg </dev/null" || warn "ffmpeg install failed" ;;
  pacman)  xb "$SUDO pacman -S --noconfirm ffmpeg </dev/null" || warn "ffmpeg install failed" ;;
  apk)     xb "$SUDO apk add --no-cache ffmpeg </dev/null" || warn "ffmpeg install failed" ;;
  zypper)  xb "$SUDO zypper -n install ffmpeg </dev/null" || warn "ffmpeg install failed" ;;
esac
info "ffmpeg: $(command -v ffmpeg 2>/dev/null || echo 'not found (video test signal disabled)')"

MTX_BIN="/usr/local/bin/mediamtx"
if [ -x "$MTX_BIN" ]; then
  info "MediaMTX already installed: $MTX_BIN"
else
  case "$ARCH" in
    x86_64|amd64)  MTX_ARCH="amd64" ;;
    aarch64|arm64) MTX_ARCH="arm64" ;;
    armv7l|armhf)  MTX_ARCH="armv7" ;;
    *)             MTX_ARCH="" ;;
  esac
  if [ -z "$MTX_ARCH" ]; then
    warn "no MediaMTX build for $ARCH — live video is disabled (audio still works)"
  else
    MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/$MTX_VERSION/mediamtx_${MTX_VERSION}_linux_${MTX_ARCH}.tar.gz"
    if [ "$DRY_RUN" = "1" ]; then
      x "curl -fsSL --retry 2 -o /tmp/mediamtx.tar.gz $MTX_URL"
      x "tar -xzf /tmp/mediamtx.tar.gz -C /tmp && install -m755 mediamtx $MTX_BIN"
    else
      MTMP="$(mktemp -d)"
      if curl -fsSL --retry 2 -o "$MTMP/mediamtx.tar.gz" "$MTX_URL" </dev/null; then
        if tar -xzf "$MTMP/mediamtx.tar.gz" -C "$MTMP"; then
          MTX_SRC="$(find "$MTMP" -type f -name mediamtx | head -n 1 || true)"
          if [ -n "$MTX_SRC" ]; then
            x "$SUDO install -m 755 \"$MTX_SRC\" $MTX_BIN" \
              && info "installed MediaMTX ($MTX_VERSION) → $MTX_BIN"
          else
            warn "mediamtx binary not found inside the archive"
          fi
        else
          warn "could not unpack the MediaMTX archive"
        fi
      else
        warn "could not download MediaMTX from $MTX_URL"
      fi
      rm -rf "$MTMP"
    fi
  fi
fi

# SRS is installed through the same idempotent function the update path calls,
# so an existing server repairs a missing /usr/local/bin/srs without a reinstall.
install_srs

# The licensed and free Red5 servers are both optional, both Java, and both
# installed through functions the update path also calls — so a panel installed
# before the engine was added can repair either missing server on update.
install_red5_pro
install_red5_free

# ---------------------------------------------------------------------------
# Node.js runtime (also verifies node + npm resolve anywhere)
# ---------------------------------------------------------------------------
ensure_node

# ---------------------------------------------------------------------------
# PostgreSQL: start, provision role + database, write DATABASE_URL
# ---------------------------------------------------------------------------
say "PostgreSQL setup"
if [ "$DRY_RUN" = "1" ]; then
  x "$SUDO systemctl enable --now postgresql   # or: service postgresql start"
  x "wait for the server, then create role '$DB_USER' + database '$DB_NAME'"
else
  if [ "$PM" = "apk" ]; then
    xb "$SUDO rc-update add postgresql default"
    xb "$SUDO rc-service postgresql start"
  elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    xb "$SUDO systemctl enable --now postgresql"
  elif command -v service >/dev/null 2>&1; then
    xb "$SUDO service postgresql start"
  fi
fi

PG_PSQL=""
if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1; then
  PG_PSQL="runuser -u postgres -- psql"
elif command -v sudo >/dev/null 2>&1; then
  PG_PSQL="sudo -u postgres psql"
fi

gen_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

ENV_FILE="$APP_DIR/.env.local"
have_env=0
if [ -f "$ENV_FILE" ] && grep -q "^DATABASE_URL=" "$ENV_FILE" 2>/dev/null; then
  have_env=1
fi

# DATABASE_URL is written *after* the source is fetched (see "Write
# DATABASE_URL" below): on a fresh install APP_DIR may not exist yet — it is
# created by the source step.
NEW_DATABASE_URL=""

# Create or refresh the app role with a fresh URL-safe (hex) password.
provision_db_role() {
  DB_PW="$(gen_pw)"
  if $PG_PSQL -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    $PG_PSQL -c "ALTER ROLE $DB_USER PASSWORD '$DB_PW' CREATEDB" || warn "could not set role password"
    info "role '$DB_USER' — password set for this install"
  else
    # CREATEDB lets the panel create its own database on first boot when the
    # postgres-side CREATE DATABASE could not run (self-heal).
    $PG_PSQL -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PW' CREATEDB" || warn "could not create role"
    info "created role '$DB_USER'"
  fi
}

if [ "$DRY_RUN" = "1" ]; then
  x "psql: create role '$DB_USER' (login, password) + database '$DB_NAME' if missing"
  if [ "$have_env" = "0" ]; then
    info "DATABASE_URL will be written to $ENV_FILE (single line, password included) once the source is in place"
  else
    info "DATABASE_URL already present in $ENV_FILE — kept if it has a password, repaired if it does not"
  fi
else
  if [ -z "$PG_PSQL" ]; then
    warn "cannot run psql as the postgres user (need root or sudo)"
  else
    # wait for the server to accept connections
    tries=0
    while [ "$tries" -lt 15 ] && ! $PG_PSQL -tAc "SELECT 1" >/dev/null 2>&1; do
      sleep 1
      tries=$((tries + 1))
    done
    if ! $PG_PSQL -tAc "SELECT 1" >/dev/null 2>&1; then
      warn "PostgreSQL did not come up — check its service logs"
    fi

    if [ "$have_env" = "1" ]; then
      EXISTING_URL="$(grep '^DATABASE_URL=' "$ENV_FILE" 2>/dev/null | tail -n 1)"
      case "$EXISTING_URL" in
        *://*:*@*)
          info "DATABASE_URL already present in $ENV_FILE — credentials untouched"
          ;;
        *://*127.0.0.1*/"$DB_NAME"*|*://*localhost*/"$DB_NAME"*|*://*\[::1\]*/"$DB_NAME"*|"DATABASE_URL=")
          # A LOCAL url without a password fails SCRAM login with the confusing
          # "client password must be a string" — rewrite it with a real one.
          # Only the canonical local install URL is touched; anything else
          # (custom user/db/host) gets instructions instead of being overwritten.
          warn "DATABASE_URL in $ENV_FILE has no password — repairing it"
          provision_db_role
          NEW_DATABASE_URL="postgres://$DB_USER:$DB_PW@127.0.0.1:5432/$DB_NAME"
          ;;
        *)
          warn "DATABASE_URL in $ENV_FILE has no password — edit it by hand: postgres://user:PASSWORD@host:5432/dbname (URL-encode special characters)"
          ;;
      esac
    else
      provision_db_role
      NEW_DATABASE_URL="postgres://$DB_USER:$DB_PW@127.0.0.1:5432/$DB_NAME"
      info "provisioned role '$DB_USER' + database '$DB_NAME' — DATABASE_URL saved for $ENV_FILE"
    fi

    # Role FIRST, database second: on a fresh box the old order ran
    # "CREATE DATABASE … OWNER app" before the role existed, the OWNER error
    # was warned away, and the panel then booted with "database does not
    # exist". Also make sure the role may create the database itself on first
    # boot (self-heal — the panel retries when the database is missing).
    if $PG_PSQL -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
      $PG_PSQL -c "ALTER ROLE $DB_USER CREATEDB" || warn "could not grant CREATEDB to '$DB_USER'"
    fi
    $PG_PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 ||
      $PG_PSQL -c "CREATE DATABASE $DB_NAME OWNER $DB_USER" ||
      warn "could not create database '$DB_NAME' — the panel will retry creating it on first boot"
  fi
fi

# pgcrypto provides gen_random_uuid() on PostgreSQL < 13; harmless on 13+.
# Created as the postgres superuser because the app role may not be allowed to.
if [ "$DRY_RUN" != "1" ] && [ -n "$PG_PSQL" ] &&
   $PG_PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
  if $PG_PSQL -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto" >/dev/null 2>&1; then
    info "ensured the pgcrypto extension in '$DB_NAME'"
  else
    warn "could not create the pgcrypto extension (only needed on PostgreSQL < 13)"
  fi
fi

# ---------------------------------------------------------------------------
# App source: use a COMPLETE local copy, else download the source tarball
# from SOURCE_URL. A stale or half-unpacked copy that fails to build is
# refreshed from the tarball once before giving up.
# ---------------------------------------------------------------------------
say "App source"
if [ -f "$APP_DIR/package.json" ] && [ -d "$APP_DIR/src" ]; then
  info "found app at $APP_DIR"
  x "cd \"$APP_DIR\" && \"$NPM_BIN\" install </dev/null" || die "npm install failed"
  if [ "$SKIP_BUILD" != "1" ]; then
    if ! build_app; then
      warn "build failed — re-downloading the source tarball from $SOURCE_URL and retrying once"
      fetch_source || die "source download failed from $SOURCE_URL"
      x "cd \"$APP_DIR\" && \"$NPM_BIN\" install </dev/null" || die "npm install failed"
      build_app || die "production build failed even after re-fetching the source — usually out of memory during 'next build'. Add swap (done automatically when RAM is low), use a bigger server, or set SKIP_BUILD=1 and build later."
    fi
  fi
else
  ensure_tar
  info "no local source — downloading $SOURCE_URL → $APP_DIR"
  x "$SUDO mkdir -p \"$APP_DIR\""
  fetch_source || die "source download failed from $SOURCE_URL"
  if [ "$DRY_RUN" = "1" ] || [ -f "$APP_DIR/package.json" ]; then
    x "cd \"$APP_DIR\" && \"$NPM_BIN\" install </dev/null" || die "npm install failed"
    if [ "$SKIP_BUILD" != "1" ]; then
      build_app || die "production build failed — usually out of memory during 'next build'. Add swap (done automatically when RAM is low), use a bigger server, or set SKIP_BUILD=1 and build later."
    fi
  else
    die "no package.json after unpacking $SOURCE_URL — check the archive layout or set APP_DIR / SOURCE_URL"
  fi
fi

# ---------------------------------------------------------------------------
# Write DATABASE_URL to .env.local — deferred until after the source step so
# APP_DIR is guaranteed to exist (the download/unpack creates it).
# ---------------------------------------------------------------------------
if [ -n "$NEW_DATABASE_URL" ]; then
  ENV_DIR="$(dirname "$ENV_FILE")"
  x "$SUDO mkdir -p \"$ENV_DIR\"" || die "could not create $ENV_DIR"
  # Upsert: drop any old DATABASE_URL lines first so the file ends up with
  # exactly one — appending duplicates leaves the winner up to loader
  # precedence, and a stale passwordless line is what breaks SCRAM login.
  TMPE="$(mktemp)"
  grep -v '^DATABASE_URL=' "$ENV_FILE" > "$TMPE" 2>/dev/null || true
  printf 'DATABASE_URL=%s\n' "$NEW_DATABASE_URL" >> "$TMPE" || die "could not write DATABASE_URL"
  $SUDO mv "$TMPE" "$ENV_FILE" || die "could not replace $ENV_FILE"
  info "wrote DATABASE_URL to $ENV_FILE (single line, password included)"
fi

# ---------------------------------------------------------------------------
# Outbound mail (optional). Pass SMTP_HOST (and its friends) to configure the
# mail server during the install; the same settings are editable afterwards in
# Admin → Server settings → Email, and an environment variable always wins over
# a saved value.
#
# Written into .env.local rather than into the database because the panel has no
# database at this point (the setup wizard creates the first admin on first
# visit) — and because the Next server reads .env.local itself, so the panel
# picks the values up without a restart.
# ---------------------------------------------------------------------------
if [ -n "${SMTP_HOST:-}" ]; then
  ENV_DIR="$(dirname "$ENV_FILE")"
  x "$SUDO mkdir -p \"$ENV_DIR\"" || die "could not create $ENV_DIR"
  TMPE="$(mktemp)"
  # Upsert each key: drop the old line, append the new one, so re-running the
  # installer cannot leave two SMTP_HOST lines and an unpredictable winner.
  grep -v -e '^SMTP_HOST=' -e '^SMTP_PORT=' -e '^SMTP_SECURE=' -e '^SMTP_USER=' -e '^SMTP_PASS=' -e '^EMAIL_FROM=' "$ENV_FILE" > "$TMPE" 2>/dev/null || true
  printf 'SMTP_HOST=%s\n' "$SMTP_HOST" >> "$TMPE"
  printf 'SMTP_PORT=%s\n' "${SMTP_PORT:-587}" >> "$TMPE"
  if [ -n "${SMTP_SECURE:-}" ]; then printf 'SMTP_SECURE=%s\n' "$SMTP_SECURE" >> "$TMPE"; fi
  if [ -n "${SMTP_USER:-}" ]; then printf 'SMTP_USER=%s\n' "$SMTP_USER" >> "$TMPE"; fi
  if [ -n "${SMTP_PASS:-}" ]; then printf 'SMTP_PASS=%s\n' "$SMTP_PASS" >> "$TMPE"; fi
  if [ -n "${EMAIL_FROM:-}" ]; then printf 'EMAIL_FROM=%s\n' "$EMAIL_FROM" >> "$TMPE"; fi
  $SUDO mv "$TMPE" "$ENV_FILE" || die "could not replace $ENV_FILE"
  info "wrote the mail server settings to $ENV_FILE (SMTP_HOST=${SMTP_HOST}:${SMTP_PORT:-587})"
else
  info "no SMTP_HOST set — the panel will log mail instead of sending it; configure it in Admin → Server settings → Email or set SMTP_HOST and friends"
fi

# ---------------------------------------------------------------------------
# Start the panel, open the host firewall and wait until /setup responds
# ---------------------------------------------------------------------------
resolve_server_ip
setup_proxy
start_panel
open_firewall
wait_for_panel

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
say "Summary"
psql_bin="$(command -v psql || true)"
ice_bin="$(command -v icecast2 || command -v icecast || true)"
lq_bin="$(command -v liquidsoap || true)"
nginx_bin="$(command -v nginx || true)"
ffmpeg_bin="$(command -v ffmpeg || true)"
mtx_bin="$(command -v mediamtx || true)"
srs_bin=""
if [ -x "$SRS_BIN" ]; then srs_bin="$SRS_BIN"; fi
red5_bin=""
if red5_pro_installed; then red5_bin="$RED5_HOME/red5.sh"; fi
red5_free_bin=""
if red5_free_installed; then red5_free_bin="$RED5_FREE_HOME/red5.sh"; fi
node_bin="$(command -v node || true)"
npm_bin="$(command -v npm || true)"
info "PostgreSQL : ${psql_bin:-not found}"
info "Icecast2   : ${ice_bin:-not found}"
if [ -x "$RSAS_BIN" ] && [ -d "$RSAS_HOME/templates" ] && [ -d "$RSAS_HOME/webroot" ]; then
  info "RSAS       : $RSAS_BIN (Rocket Streaming Audio Server)"
elif [ -n "${RSAS_STATUS:-}" ]; then
  info "RSAS       : not available — $RSAS_STATUS"
else
  info "RSAS       : not installed"
fi
info "Liquidsoap : ${lq_bin:-not found}"
if [ -x "$SC_DIR/sc_serv" ]; then info "Shoutcast  : $SC_DIR/sc_serv (DNAS 2)"; else info "Shoutcast  : not found"; fi
if [ -x "$SC1_DIR/sc_serv" ]; then
  if [ -x "$SC1_LOADER_PATH" ]; then
    info "Shoutcast1 : $SC1_DIR/sc_serv (legacy 1.9.8, 32-bit loader present)"
  else
    info "Shoutcast1 : $SC1_DIR/sc_serv (legacy 1.9.8) — UNUSABLE: missing $SC1_LOADER_PATH"
    info "             fix: $(sc1_loader_fix)"
  fi
else
  info "Shoutcast1 : not found"
fi
# Icecast KH is the one engine that is neither packaged nor downloaded whole, so
# it is also the one whose absence needs a reason: "not installed" on this line
# with the build log path beside it is what turns "the installer did not make
# /opt/icecast-kh/bin/icecast" into an answer.
if [ -x "$IKH_DIR/bin/icecast" ]; then
  info "Icecast KH : $IKH_DIR/bin/icecast (Karl Heyes fork, built from source)"
elif [ -n "${IKH_STATUS:-}" ]; then
  info "Icecast KH : not available — $IKH_STATUS"
else
  info "Icecast KH : not installed"
fi
info "nginx      : ${nginx_bin:-not installed} (reverse proxy, unused unless PROXY_MODE=nginx)"
nginx_rtmp_bin=""
for f in /usr/lib/nginx/modules/ngx_rtmp_module.so \
         /usr/lib64/nginx/modules/ngx_rtmp_module.so \
         /usr/share/nginx/modules/ngx_rtmp_module.so \
         /etc/nginx/modules/ngx_rtmp_module.so \
         /usr/local/nginx/modules/ngx_rtmp_module.so; do
  [ -f "$f" ] && nginx_rtmp_bin="$f" && break
done
if [ -n "${NGINX_RTMP_MODULE:-}" ] && [ -f "$NGINX_RTMP_MODULE" ]; then nginx_rtmp_bin="$NGINX_RTMP_MODULE"; fi
info "NGINX RTMP : ${nginx_rtmp_bin:-module not found} (RTMP $NGINX_RTMP_PORT → HLS on $NGINX_HLS_PORT)"
info "ffmpeg     : ${ffmpeg_bin:-not installed} (video test signal, HLS audio packager)"
if [ -n "$ice_bin" ] && [ -n "$ffmpeg_bin" ]; then
  info "HLS audio  : available (Icecast origin + ffmpeg)"
else
  info "HLS audio  : unavailable — needs Icecast2 and ffmpeg"
fi
info "MediaMTX   : ${mtx_bin:-not installed} (RTMP $VIDEO_RTMP_PORT → HLS for video stations)"
info "SRS        : ${srs_bin:-not installed} (RTMP $SRS_RTMP_PORT → HLS for video stations)"
info "Red5 Pro   : ${red5_bin:-not installed — optional, requires a licensed archive (RED5_ARCHIVE_URL)} (RTMP $RED5_RTMP_PORT → HLS on $RED5_HTTP_PORT)"
info "Red5 Free  : ${red5_free_bin:-not installed — open-source RTMP server (RED5_FREE_HOME)} (RTMP $RED5_FREE_RTMP_PORT → HLS via ffmpeg)"
info "Node.js    : ${node_bin:-not found} ($(node -v 2>/dev/null || echo '?'))"
info "npm        : ${npm_bin:-not found}"
resolve_server_ip
PUBLIC_URL="$(public_scheme)://$(public_host)$(public_port_suffix)"
# Every port beyond the panel's own that this install needs, named for the
# summary. Each one is opened on the host firewall above (unless OPEN_FIREWALL=0).
# The panel's port check has rows for the station range, FTP and every video
# ingest, including the optional Red5 Pro port opened here.
OTHER_PORTS="$STATION_PORT_MIN-$STATION_PORT_MAX (stations), $VIDEO_RTMP_PORT (MediaMTX, RTMP from OBS), $SRS_RTMP_PORT (SRS, RTMP from OBS), $RED5_RTMP_PORT (Red5 Pro, optional licensed archive; RTMP from OBS), $RED5_FREE_RTMP_PORT (Red5 Free, RTMP from OBS), $NGINX_RTMP_PORT (NGINX RTMP, RTMP from OBS)"
if [ "$OPEN_FTP" = "1" ]; then
  OTHER_PORTS="$OTHER_PORTS, $FTP_PORT + $FTP_PASSIVE_MIN-$FTP_PASSIVE_MAX (FTP, all interfaces when enabled)"
fi
info "Panel      : 0.0.0.0:$PANEL_PORT → $PUBLIC_URL/setup"
if [ "$PROXY_MODE" = "none" ] && [ "$PANEL_PORT" != "80" ] && panel_port_80_wanted; then
  info "Also on    : port 80 → $(public_scheme)://$(public_host)/ (the panel serves it itself — no proxy needed)"
fi
if [ "$PROXY_MODE" != "none" ] && panel_port_80_wanted; then
  warn "PANEL_PORTS=$PANEL_PORTS asks the panel for port 80, but PROXY_MODE=$PROXY_MODE already listens there — the panel will say so on Admin → System overview. Use PANEL_PORTS=3000 and keep reaching the panel through the proxy."
fi
# Port 443 is the one this panel is asked for when there is no proxy to serve the
# domain over https: the panel does it itself, from the certificate issued in
# Admin → SSL. Said here because "the streams are on https and my panel is not"
# is the report this whole option exists for.
if [ "$PROXY_MODE" = "none" ] && [ "$PANEL_PORT" != "443" ] && panel_port_443_wanted; then
  info "Also on    : port 443 → https://$(public_host)/ (the panel serves https itself, once a certificate is issued in Admin → SSL)"
fi
if [ "$PROXY_MODE" != "none" ] && panel_port_443_wanted; then
  warn "PANEL_PORTS=$PANEL_PORTS asks the panel for port 443, but PROXY_MODE=$PROXY_MODE serves https there — issue the certificate and let the proxy keep that port, or re-run with PANEL_PORTS=3000."
fi
# This panel serves its own hosted manifest, so an operator who wants their own
# feed does not have to write one: it is already at /hosted.manifest.json, and
# pointing another machine at it makes that machine update from here.
info "Manifest   : ${MANIFEST_URL:-$PUBLIC_URL/hosted.manifest.json}"
report_version
report_install install
case "$PROXY_MODE" in
  nginx) info "Proxy      : nginx on :80 → 127.0.0.1:$PANEL_PORT" ;;
  caddy) info "Proxy      : Caddy on :80/:443 (auto TLS) → 127.0.0.1:$PANEL_PORT" ;;
  tunnel) info "Proxy      : Cloudflare Tunnel (outbound only) → 127.0.0.1:$PANEL_PORT" ;;
esac

say "Next steps"
info "1. Open the wizard:  $PUBLIC_URL/setup"
if [ "$SERVER_IP" = "<server>" ] && [ -z "$DOMAIN" ]; then
  info "   (replace <server> with this machine's IP: run 'hostname -I' on the server)"
fi
info "2. Create your first station — engines are listed under Admin → Server settings."
info "3. Update later:     ${MANIFEST_UPDATE:-curl -fsSL $INSTALL_URL | sudo sh -s -- update}"
# Only when no manifest named the update command: otherwise the line above is
# already this install's own feed, and a second address would be noise.
if [ -z "$MANIFEST_UPDATE" ]; then
  info "   backup host:      curl -fsSL $BACKUP_INSTALL_URL | sudo sh -s -- update"
fi
info "Panel service: systemctl status letsstreamit   (log file: $PANEL_LOG without systemd)"
if [ "$PROXY_MODE" = "none" ]; then
  info "Open ports:  $PANEL_PORT (panel), $OTHER_PORTS."
elif [ "$PROXY_MODE" = "tunnel" ]; then
  info "Open ports:  none for the panel (tunnel dials out); $OTHER_PORTS."
else
  info "Open ports:  $(panel_exposure_ports) (panel, served by $PROXY_MODE), $OTHER_PORTS."
fi
if [ -n "$FIREWALL_LINE" ]; then
  info "Firewall   : $FIREWALL_LINE"
fi
if [ "$PROXY_MODE" = "none" ]; then
  info ""
  info "If the page still does not load, port $PANEL_PORT is blocked before the panel:"
  info "  · Cloud VPS: allow $PANEL_PORT/tcp in your provider's security group / firewall."
  info "  · Provider blocks port $PANEL_PORT? Re-run with PANEL_PORTS=80+3000 and the panel"
  info "    answers on port 80 as well — or pick '80 and 3000' in the setup wizard, no re-install."
  info "  · Provider allows only 80/443? nginx is already installed — re-run with"
  info "    PROXY_MODE=nginx DOMAIN=your.domain (or"
  info "    PROXY_MODE=caddy for automatic HTTPS) so the panel is reachable without port $PANEL_PORT."
  info "  · Reachable only on localhost? Tunnel it: ssh -L $PANEL_PORT:127.0.0.1:$PANEL_PORT user@$SERVER_IP"
  info "  · Provider blocks every inbound port? Re-run with PROXY_MODE=tunnel TUNNEL_TOKEN=…"
  info "    (Cloudflare Tunnel) — the panel then needs no open port at all."
fi

#!/bin/sh
# setup-sstp-tunnel-fixed-v3.sh
# OpenWrt SSTP management tunnel installer.
# Allows from SSTP zone only: SSH 22, HTTP 80, ICMP ping.
# Optional: route from this router to LAN behind SSTP server for file download.
# For OpenWrt 24.10.x forces sstp-client downgrade to 1.0.15-1
# because sstp-client 1.0.20-r1 may pass a broken empty option to pppd.

set -u

SCRIPT_NAME="$(basename "$0")"
BACKUP_DIR="/root/sstp-backup"
HOTPLUG_FILE="/etc/hotplug.d/iface/95-sstp-wan"
SSTP_IF="sstp"
FIXED_SSTP_VERSION="1.0.15-1"
FIXED_OWRT_RELEASE="23.05.5"

ROUTE_SECTION="sstp_server_lan_route"
FILE_RULE_SECTION="allow_router_to_server_file_over_sstp"

DEFAULT_SERVER_LAN_CIDR="192.168.65.0/24"
DEFAULT_SERVER_FILE_IP="192.168.65.10"
DEFAULT_SERVER_FILE_PORT="80"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
cat <<USAGE
Usage:
  sh $SCRIPT_NAME install   Configure SSTP tunnel
  sh $SCRIPT_NAME status    Show SSTP status and diagnostics
  sh $SCRIPT_NAME remove    Remove SSTP tunnel config

The installer asks for:
  - SSTP server hostname, for example: remout.crazedns.ru
  - username
  - password
  - optional route to LAN behind SSTP server, default: 192.168.65.0/24
  - optional file server IP/port, default: 192.168.65.10:80

Firewall policy from SSTP to this router is minimal:
  - allow TCP 22
  - allow TCP 80
  - allow ICMP echo-request
  - deny everything else

Optional file mode allows only router-originated TCP access to one server-side IP:port.
It does NOT open client LAN and does NOT allow SSTP clients into LAN.
USAGE
}

need_root() {
    [ "$(id -u)" = "0" ] || die "Run as root."
}

need_openwrt() {
    [ -x /sbin/uci ] || die "uci not found. This script is for OpenWrt."
    [ -x /bin/opkg ] || die "opkg not found. This script is for OpenWrt."
}

backup_configs() {
    TS="$(date +%F-%H%M%S)"
    mkdir -p "$BACKUP_DIR" || die "Cannot create $BACKUP_DIR"

    [ -f /etc/config/network ] && cp /etc/config/network "$BACKUP_DIR/network.$TS.bak" || true
    [ -f /etc/config/firewall ] && cp /etc/config/firewall "$BACKUP_DIR/firewall.$TS.bak" || true

    log "Backups saved to $BACKUP_DIR"
}

read_line() {
    PROMPT="$1"
    DEFAULT="${2:-}"

    if [ -n "$DEFAULT" ]; then
        MSG="$PROMPT [$DEFAULT]: "
    else
        MSG="$PROMPT: "
    fi

    if [ -r /dev/tty ]; then
        printf "%s" "$MSG" > /dev/tty
        IFS= read -r VALUE < /dev/tty
    else
        printf "%s" "$MSG" >&2
        IFS= read -r VALUE
    fi

    [ -n "$VALUE" ] || VALUE="$DEFAULT"
    printf "%s" "$VALUE"
}

read_secret() {
    PROMPT="$1"

    if [ -r /dev/tty ]; then
        printf "%s" "$PROMPT" > /dev/tty
        stty -echo < /dev/tty 2>/dev/null || true
        IFS= read -r VALUE < /dev/tty
        stty echo < /dev/tty 2>/dev/null || true
        printf "\n" > /dev/tty
    else
        printf "%s" "$PROMPT" >&2
        stty -echo 2>/dev/null || true
        IFS= read -r VALUE
        stty echo 2>/dev/null || true
        printf "\n" >&2
    fi

    printf "%s" "$VALUE"
}

trim() {
    # Trim leading/trailing spaces and tabs. BusyBox-compatible.
    printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

sanitize_server() {
    S="$(trim "$1")"
    S="${S#http://}"
    S="${S#https://}"
    S="${S%%/*}"
    S="${S%%:*}"
    printf "%s" "$S"
}

validate_hostname() {
    H="$1"
    [ -n "$H" ] || return 1
    case "$H" in
        *[!A-Za-z0-9._-]* ) return 1 ;;
        .*|*..*|*.) return 1 ;;
    esac
    return 0
}

validate_ipv4() {
    IP="$(trim "$1")"
    [ -n "$IP" ] || return 1
    echo "$IP" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/) exit 1
                if ($i < 0 || $i > 255) exit 1
            }
        }
    ' >/dev/null 2>&1
}

validate_cidr() {
    C="$(trim "$1")"
    [ -n "$C" ] || return 1
    case "$C" in
        */*) ;;
        *) return 1 ;;
    esac
    IP="${C%/*}"
    MASK="${C#*/}"
    validate_ipv4 "$IP" || return 1
    case "$MASK" in
        *[!0-9]*|'') return 1 ;;
    esac
    [ "$MASK" -ge 0 ] 2>/dev/null && [ "$MASK" -le 32 ] 2>/dev/null
}

validate_port() {
    P="$1"
    [ -n "$P" ] || return 1
    case "$P" in
        *[!0-9]* ) return 1 ;;
    esac
    [ "$P" -ge 1 ] 2>/dev/null && [ "$P" -le 65535 ] 2>/dev/null
}

ask_yes_no() {
    PROMPT="$1"
    DEFAULT="$2"

    case "$DEFAULT" in
        y|Y) SUFFIX="[Y/n]" ;;
        *)   SUFFIX="[y/N]" ;;
    esac

    ANSWER="$(read_line "$PROMPT $SUFFIX" "")"
    [ -n "$ANSWER" ] || ANSWER="$DEFAULT"

    case "$ANSWER" in
        y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;;
        *) return 1 ;;
    esac
}

ask_credentials() {
    echo
    echo "=== SSTP connection parameters ==="

    RAW_SERVER="$(read_line "SSTP server hostname, without https://" "")"
    SERVER="$(sanitize_server "$RAW_SERVER")"

    VPNUSER="$(trim "$(read_line "Username" "")")"
    VPNPASS="$(read_secret "Password: ")"

    [ -n "$SERVER" ] || die "Server is empty."
    [ -n "$VPNUSER" ] || die "Username is empty."
    [ -n "$VPNPASS" ] || die "Password is empty."

    validate_hostname "$SERVER" || die "Server contains unsupported characters after sanitizing: $SERVER"

    ENABLE_SERVER_FILE_ROUTE="0"
    SERVER_LAN_CIDR=""
    SERVER_FILE_IP=""
    SERVER_FILE_PORT=""

    echo
    echo "=== Optional server-side file access ==="
    echo "Use this only if this OpenWrt router must download a file from LAN behind SSTP server."
    echo "Default server-side LAN: ${DEFAULT_SERVER_LAN_CIDR}, Debian/file server: ${DEFAULT_SERVER_FILE_IP}:${DEFAULT_SERVER_FILE_PORT}."
    echo "Press Enter on the next prompts to use these defaults."

    if ask_yes_no "Add route to LAN behind SSTP server and allow router to one file server" "n"; then
        ENABLE_SERVER_FILE_ROUTE="1"
        SERVER_LAN_CIDR="$(trim "$(read_line "Server-side LAN CIDR" "$DEFAULT_SERVER_LAN_CIDR")")"
        SERVER_FILE_IP="$(trim "$(read_line "Debian/file server IP" "$DEFAULT_SERVER_FILE_IP")")"
        SERVER_FILE_PORT="$(trim "$(read_line "Debian/file server TCP port" "$DEFAULT_SERVER_FILE_PORT")")"

        # If user enters only spaces, fall back to defaults too.
        [ -n "$SERVER_LAN_CIDR" ] || SERVER_LAN_CIDR="$DEFAULT_SERVER_LAN_CIDR"
        [ -n "$SERVER_FILE_IP" ] || SERVER_FILE_IP="$DEFAULT_SERVER_FILE_IP"
        [ -n "$SERVER_FILE_PORT" ] || SERVER_FILE_PORT="$DEFAULT_SERVER_FILE_PORT"

        validate_cidr "$SERVER_LAN_CIDR" || die "Invalid server-side LAN CIDR: $SERVER_LAN_CIDR"
        validate_ipv4 "$SERVER_FILE_IP" || die "Invalid file server IP: $SERVER_FILE_IP"
        validate_port "$SERVER_FILE_PORT" || die "Invalid file server port: $SERVER_FILE_PORT"
    fi

    echo
    log "Server: $SERVER"
    log "Username: $VPNUSER"
    if [ "$ENABLE_SERVER_FILE_ROUTE" = "1" ]; then
        log "Server-side LAN route: $SERVER_LAN_CIDR via SSTP"
        log "Allowed router-originated file access: $SERVER_FILE_IP:$SERVER_FILE_PORT via SSTP"
    else
        log "Server-side LAN route: disabled"
    fi
}

get_arch() {
    opkg print-architecture | awk '$1=="arch" && $2!="all" && $2!="noarch" { if ($3>p) { p=$3; a=$2 } } END { print a }'
}

stop_sstp() {
    ifdown "$SSTP_IF" 2>/dev/null || true
    killall sstpc 2>/dev/null || true
    killall pppd 2>/dev/null || true
}

install_sstp_package_fixed() {
    log "Updating package lists..."
    opkg update || die "opkg update failed. Check WAN/internet access."

    log "Installing sstp-client dependencies/package from current OpenWrt repo..."
    opkg install sstp-client || die "Cannot install sstp-client from current repo."

    ARCH="$(get_arch)"
    [ -n "$ARCH" ] || die "ARCH detection failed."
    log "Detected opkg architecture: $ARCH"

    PKG="sstp-client_${FIXED_SSTP_VERSION}_${ARCH}.ipk"
    URL="https://downloads.openwrt.org/releases/${FIXED_OWRT_RELEASE}/packages/${ARCH}/packages/${PKG}"

    log "Downloading known-working sstp-client ${FIXED_SSTP_VERSION}: $URL"
    wget -O "/tmp/$PKG" "$URL" || die "Cannot download fixed sstp-client package: $URL"

    log "Forcing downgrade/install of sstp-client ${FIXED_SSTP_VERSION}"
    opkg install --force-downgrade "/tmp/$PKG" || die "Failed to install fixed sstp-client package."

    [ -x /usr/bin/sstpc ] || die "/usr/bin/sstpc not found after install."
    [ -x /lib/netifd/proto/sstp.sh ] || die "/lib/netifd/proto/sstp.sh not found after install."

    log "Installed package: $(opkg list-installed | grep '^sstp-client' || true)"
}

configure_network() {
    log "Configuring network interface: $SSTP_IF"

    uci -q delete network.$SSTP_IF
    uci -q delete network.$ROUTE_SECTION

    uci set network.$SSTP_IF='interface'
    uci set network.$SSTP_IF.proto='sstp'
    uci set network.$SSTP_IF.server="$SERVER"
    uci set network.$SSTP_IF.username="$VPNUSER"
    uci set network.$SSTP_IF.password="$VPNPASS"
    uci set network.$SSTP_IF.log_level='4'
    uci set network.$SSTP_IF.sstp_options='--tls-ext'
    uci set network.$SSTP_IF.defaultroute='0'
    uci set network.$SSTP_IF.peerdns='0'
    uci set network.$SSTP_IF.ipv6='0'
    uci set network.$SSTP_IF.auto='1'

    if [ "$ENABLE_SERVER_FILE_ROUTE" = "1" ]; then
        uci set network.$ROUTE_SECTION='route'
        uci set network.$ROUTE_SECTION.interface="$SSTP_IF"
        uci set network.$ROUTE_SECTION.target="$SERVER_LAN_CIDR"
    fi

    uci commit network || die "uci commit network failed."
}

configure_firewall() {
    log "Configuring firewall: allow ONLY SSH(22), HTTP(80), ping from SSTP"

    uci -q delete firewall.sstp
    uci -q delete firewall.allow_ssh_from_sstp
    uci -q delete firewall.allow_http_from_sstp
    uci -q delete firewall.allow_https_from_sstp
    uci -q delete firewall.allow_ping_from_sstp
    uci -q delete firewall.sstp_to_lan
    uci -q delete firewall.lan_to_sstp
    uci -q delete firewall.$FILE_RULE_SECTION

    uci set firewall.sstp='zone'
    uci set firewall.sstp.name='sstp'
    uci set firewall.sstp.network='sstp'
    uci set firewall.sstp.input='REJECT'
    uci set firewall.sstp.forward='REJECT'
    uci set firewall.sstp.output='REJECT'

    uci set firewall.allow_ssh_from_sstp='rule'
    uci set firewall.allow_ssh_from_sstp.name='Allow-SSH-from-SSTP'
    uci set firewall.allow_ssh_from_sstp.src='sstp'
    uci set firewall.allow_ssh_from_sstp.proto='tcp'
    uci set firewall.allow_ssh_from_sstp.dest_port='22'
    uci set firewall.allow_ssh_from_sstp.target='ACCEPT'

    uci set firewall.allow_http_from_sstp='rule'
    uci set firewall.allow_http_from_sstp.name='Allow-HTTP-from-SSTP'
    uci set firewall.allow_http_from_sstp.src='sstp'
    uci set firewall.allow_http_from_sstp.proto='tcp'
    uci set firewall.allow_http_from_sstp.dest_port='80'
    uci set firewall.allow_http_from_sstp.target='ACCEPT'

    uci set firewall.allow_ping_from_sstp='rule'
    uci set firewall.allow_ping_from_sstp.name='Allow-Ping-from-SSTP'
    uci set firewall.allow_ping_from_sstp.src='sstp'
    uci set firewall.allow_ping_from_sstp.proto='icmp'
    uci set firewall.allow_ping_from_sstp.icmp_type='echo-request'
    uci set firewall.allow_ping_from_sstp.family='ipv4'
    uci set firewall.allow_ping_from_sstp.target='ACCEPT'

    if [ "$ENABLE_SERVER_FILE_ROUTE" = "1" ]; then
        log "Configuring firewall: allow router-originated TCP access to $SERVER_FILE_IP:$SERVER_FILE_PORT via SSTP"

        uci set firewall.$FILE_RULE_SECTION='rule'
        uci set firewall.$FILE_RULE_SECTION.name='Allow-router-to-server-file-over-SSTP'
        uci set firewall.$FILE_RULE_SECTION.src='*'
        uci set firewall.$FILE_RULE_SECTION.dest='sstp'
        uci set firewall.$FILE_RULE_SECTION.dest_ip="$SERVER_FILE_IP"
        uci set firewall.$FILE_RULE_SECTION.proto='tcp'
        uci set firewall.$FILE_RULE_SECTION.dest_port="$SERVER_FILE_PORT"
        uci set firewall.$FILE_RULE_SECTION.target='ACCEPT'
    fi

    uci commit firewall || die "uci commit firewall failed."
}

configure_hotplug() {
    log "Configuring safe SSTP autostart after WAN is up"

    cat > "$HOTPLUG_FILE" <<'EOH'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

LOCK="/tmp/sstp-wan-restart.lock"
[ -e "$LOCK" ] && exit 0
touch "$LOCK"

(
    sleep 30

    STATUS="$(ifstatus sstp 2>/dev/null)"
    echo "$STATUS" | grep -q '"up": true' && rm -f "$LOCK" && exit 0
    echo "$STATUS" | grep -q '"pending": true' && rm -f "$LOCK" && exit 0

    logger -t sstp-autostart "SSTP is down after WAN ifup, trying one restart"
    ifdown sstp 2>/dev/null || true
    sleep 3
    ifup sstp 2>/dev/null || true

    rm -f "$LOCK"
) &

exit 0
EOH

    chmod +x "$HOTPLUG_FILE" || die "Cannot chmod $HOTPLUG_FILE"
}

reload_services() {
    log "Restarting network and firewall"
    /etc/init.d/firewall restart 2>/dev/null || /etc/init.d/firewall reload 2>/dev/null || true
    /etc/init.d/network restart || die "network restart failed"
    sleep 10
}

install_cmd() {
    need_root
    need_openwrt
    ask_credentials
    backup_configs
    stop_sstp
    install_sstp_package_fixed
    configure_network
    configure_firewall
    configure_hotplug
    reload_services

    log "Bringing SSTP up"
    ifup "$SSTP_IF" 2>/dev/null || true
    sleep 12

    echo
    echo "=== DONE ==="
    echo "SSTP tunnel configured. Allowed from SSTP only: SSH 22, HTTP 80, ping."
    if [ "$ENABLE_SERVER_FILE_ROUTE" = "1" ]; then
        echo "Server-side file route enabled: $SERVER_LAN_CIDR via SSTP, file server $SERVER_FILE_IP:$SERVER_FILE_PORT."
        echo "Test from router: wget -O - http://$SERVER_FILE_IP:$SERVER_FILE_PORT/"
    fi
    echo "Check status with: sh $SCRIPT_NAME status"
    echo
    status_cmd
}

status_cmd() {
    echo "=== SSTP package ==="
    opkg list-installed | grep '^sstp-client' || true
    echo

    echo "=== SSTP proto handler ==="
    ls -l /lib/netifd/proto/sstp.sh 2>/dev/null || true
    echo

    echo "=== Network config ==="
    uci show network.$SSTP_IF 2>/dev/null | sed "s/password='.*'/password='***hidden***'/" || true
    uci show network.$ROUTE_SECTION 2>/dev/null || true
    echo

    echo "=== Firewall config ==="
    uci show firewall.sstp 2>/dev/null || true
    uci show firewall.allow_ssh_from_sstp 2>/dev/null || true
    uci show firewall.allow_http_from_sstp 2>/dev/null || true
    uci show firewall.allow_ping_from_sstp 2>/dev/null || true
    uci show firewall.$FILE_RULE_SECTION 2>/dev/null || true
    echo

    echo "=== Interface status ==="
    ifstatus "$SSTP_IF" 2>/dev/null || true
    echo

    echo "=== Routes ==="
    ip route 2>/dev/null | grep -E 'sstp|ppp|192\.168\.|172\.16\.66\.' || true
    FILE_IP="$(uci -q get firewall.$FILE_RULE_SECTION.dest_ip 2>/dev/null || true)"
    if [ -n "$FILE_IP" ]; then
        echo
        echo "=== Route to configured file server ==="
        ip route get "$FILE_IP" 2>/dev/null || true
    fi
    echo

    echo "=== Processes ==="
    ps w | grep -E 'sstp|sstpc|pppd' | grep -v grep || true
    echo

    echo "=== Active ppp/sstp interfaces ==="
    ip a 2>/dev/null | grep -A3 -E 'ppp|sstp' || true
    echo

    echo "=== Recent SSTP/PPP log ==="
    logread 2>/dev/null | grep -Ei 'sstp|ppp|pppd|chap|mschap|auth' | tail -80 || true
}

remove_cmd() {
    need_root
    need_openwrt
    backup_configs
    log "Removing SSTP config"

    stop_sstp

    uci -q delete network.$SSTP_IF
    uci -q delete network.$ROUTE_SECTION

    uci -q delete firewall.sstp
    uci -q delete firewall.allow_ssh_from_sstp
    uci -q delete firewall.allow_http_from_sstp
    uci -q delete firewall.allow_https_from_sstp
    uci -q delete firewall.allow_ping_from_sstp
    uci -q delete firewall.sstp_to_lan
    uci -q delete firewall.lan_to_sstp
    uci -q delete firewall.$FILE_RULE_SECTION

    uci commit network || true
    uci commit firewall || true

    rm -f "$HOTPLUG_FILE"

    /etc/init.d/firewall restart 2>/dev/null || /etc/init.d/firewall reload 2>/dev/null || true
    /etc/init.d/network restart || true

    echo "SSTP config removed. Package sstp-client is left installed."
}

case "${1:-}" in
    install) install_cmd ;;
    status)  status_cmd ;;
    remove)  remove_cmd ;;
    -h|--help|help|"") usage ;;
    *) usage; exit 1 ;;
esac

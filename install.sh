#!/bin/sh
# openwrt-sstp-tunnel - management tunnel installer for OpenWrt.
#
# Builds an SSTP tunnel to a management server and opens, from that tunnel only,
# SSH 22, HTTP 80 and ICMP echo to the router itself. Nothing else: no forwarding
# into the client LAN, no default route, no DNS takeover.
#
# sstp-client 1.0.20-r1, the build shipped by 24.10 and 25.12, fails on OpenWrt
# in two unrelated ways. This installer fixes both causes instead of papering
# over them with a package downgrade.
#
# 1. Overflowed pppd argument list, hence this script's own netifd protocol
#    handler (sstpm). sstp-client stores the pppd command line in a fixed
#    "const char *args[20]" (src/sstp-pppd.c, sstp_pppd_start). Eleven slots
#    plus the NULL terminator are taken by sstpc itself (pppd, tty, speed,
#    user+value, file+tmpfile, plugin+name+sstp-sock+socket), leaving room for
#    8 pppd arguments. The stock /lib/netifd/proto/sstp.sh passes 13 even with
#    defaultroute/peerdns/ipv6 off. In 1.0.20 the clobbered stack slot is the
#    local "speed" buffer, so pppd dies with "unrecognized option <garbage>";
#    in 1.0.15 the same overflow lands somewhere harmless, which is the only
#    reason that version "works". openwrt/packages#27318, still open.
#    Our handler keeps every pppd option in files and passes 2.
#
# 2. Missing MD4, hence libopenssl-legacy. Since 1.0.17 sstpc builds the
#    MS-CHAPv2 password hash with
#        EVP_MD_fetch(NULL, OSSL_DIGEST_NAME_MD4, "provider=legacy")
#    and under OpenSSL 3 that provider is a separate package. Without it the
#    fetch returns NULL, sstpc logs "Could not create password hash", derives no
#    MPPE keys, and sends a bogus SSTP crypto binding. PPP authentication still
#    succeeds, so the router log looks almost clean and only the server complains:
#    "invalid Compound MAC", then the session is terminated.
#
# If the tunnel still refuses to come up and opkg is available, the installer
# falls back to pinning sstp-client 1.0.15-1 from 23.05.6, which predates both
# problems. Under apk there is nothing to pin: 25.12 ships the same 1.0.20-r1.

set -u

VERSION="2.0"

# The protocol name is baked into the generated handler as well (netifd derives
# proto_<name>_setup from it), so do not change it here alone.
PROTO="sstpm"
NET_SECTION="sstp"
ZONE="sstp"

PROTO_FILE="/lib/netifd/proto/${PROTO}.sh"
PPP_OPTS_FILE="/etc/ppp/options.${PROTO}"
HOTPLUG_FILE="/etc/hotplug.d/iface/95-sstp-tunnel"
BACKUP_DIR="/root/sstp-backup"
STATE_DIR="/tmp/sstp-install"

PIN_VERSION="1.0.15-1"
PIN_RELEASE="23.05.6"

# Shared library of the OpenSSL legacy provider, where MD4 lives under OpenSSL 3.
MD4_MODULE="/usr/lib/ossl-modules/legacy.so"

# DNS servers the tunnel resolves its endpoint through, ahead of the system
# resolver. The first entry is where podkop-style setups keep their own DNS
# proxy; the public ones after it are what keeps the management tunnel able to
# find its server when that stack is down, which is exactly when the tunnel is
# needed. Answering "n" at the prompt leaves the system resolver alone.
DEFAULT_RESOLVERS="127.0.0.10 8.8.8.8 1.1.1.1"
RESOLVERS=""

# Seconds the unattended rollback waits for the installer to confirm success.
ROLLBACK_WAIT="600"
# Seconds to wait for the tunnel to come up.
UP_TIMEOUT="75"
# KiB of available RAM required before letting opkg build its package lists.
MIN_MEM_KB="20000"
# KiB of free overlay space required. Measured on a bare 24.10.3 where none of
# it was present: sstp-client 273, libevent2-7 260, libopenssl-legacy 133,
# resolveip 64, libopenssl-conf 19, plus opkg's own control files. The overlay
# grew by 988 KiB in total, so the old 600 would have let an install start that
# could not finish. Routers that already carry libevent2 and the openssl bits
# need much less, which is why this is not the full figure.
MIN_OVERLAY_KB="900"

# How to invoke this script again, for the hints it prints. Piped into sh, which
# is the documented way to run it, $0 is just "sh" and any "sh $0 status" would
# read as "sh sh status". In that case point at the same one-liner that fetched
# it in the first place.
REPO_RAW="https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main"
SCRIPT_NAME="$(basename "$0")"
case "$SCRIPT_NAME" in
	sh|-sh|ash|-ash|dash|bash|"")
		PIPED=1
		SCRIPT_NAME="install.sh"
		SELF_CMD="wget -O - ${REPO_RAW}/install.sh | sh -s"
		;;
	*)
		PIPED=0
		SELF_CMD="sh ${SCRIPT_NAME}"
		;;
esac

# Sections this script owns, plus leftovers from older versions that used to
# route into the server-side LAN. Listed once, purged from install and remove.
NET_SECTIONS="$NET_SECTION sstp_server_lan_route"
FW_SECTIONS="$ZONE allow_ssh_from_sstp allow_http_from_sstp allow_ping_from_sstp
	allow_https_from_sstp sstp_to_lan lan_to_sstp
	allow_router_to_server_file_over_sstp"

log()  { echo "[..] $*"; }
ok()   { echo "[ok] $*"; }
warn() { echo "[!!] $*" >&2; }
err()  { echo "[EE] $*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
cat <<USAGE
openwrt-sstp-tunnel $VERSION

Usage:
  sh $SCRIPT_NAME install   configure the management tunnel
  sh $SCRIPT_NAME status    show state and diagnostics
  sh $SCRIPT_NAME remove    remove the tunnel configuration

install asks for the SSTP server (host or host:port), username and password,
then does everything else by itself: package, protocol handler, interface,
firewall, autostart, bring-up and verification.

Access granted from the tunnel to this router:
  TCP 22, TCP 80, ICMP echo-request. Everything else is rejected.

While applying the configuration an unattended rollback is armed: if the
installer does not confirm success within $ROLLBACK_WAIT seconds (lost session,
broken config, unreachable router), /etc/config/network and /etc/config/firewall
are restored from $BACKUP_DIR and the network is restarted.
USAGE

	[ "$PIPED" = "1" ] && cat <<USAGE

This copy was piped into sh, so there is no ${SCRIPT_NAME} on the router. Repeat
the one-liner with the command you want:
  ${SELF_CMD} status
USAGE
	return 0
}

# ---------------------------------------------------------------- environment

require_root() {
	[ "$(id -u)" = "0" ] || die "Run as root."
}

detect_platform() {
	[ -x /sbin/uci ] || die "uci not found. This script is for OpenWrt."
	have ubus || die "ubus not found. This script is for OpenWrt."

	# 25.12 and later ship apk, 23.05/24.10 ship opkg. Check apk first: some
	# images keep an opkg shim around that cannot install anything.
	if have apk && [ -d /lib/apk ]; then
		PKG="apk"
	elif have opkg; then
		PKG="opkg"
	else
		die "Neither apk nor opkg found, cannot install packages."
	fi

	RELEASE="unknown"
	[ -r /etc/os-release ] && RELEASE="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}")"

	log "OpenWrt ${RELEASE}, package manager: ${PKG}"
}

check_resources() {
	MEM_KB="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	[ -n "${MEM_KB:-}" ] || MEM_KB="$(awk '/^MemFree:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	[ -n "${MEM_KB:-}" ] || MEM_KB="0"

	OVERLAY_KB="$(df -k /overlay 2>/dev/null | awk 'NR==2 { print $4; exit }')"
	[ -n "${OVERLAY_KB:-}" ] || OVERLAY_KB="$(df -k / 2>/dev/null | awk 'NR==2 { print $4; exit }')"
	[ -n "${OVERLAY_KB:-}" ] || OVERLAY_KB="0"

	log "Available RAM: ${MEM_KB} KiB, free overlay: ${OVERLAY_KB} KiB"
	# The overlay requirement is only enforced when a package has to be
	# installed, see install_package. Reconfiguring an existing install needs
	# barely any space and must not fail on a tightly packed router.
}

# -------------------------------------------------------------------- prompts

# The installer is usually piped into sh, so the answers cannot come from stdin
# and it asks on the terminal directly. "[ -r /dev/tty ]" is not the way to find
# out whether there is one: on OpenWrt the device node exists and is readable by
# root even with no controlling terminal, so the test passes, every read fails,
# and under "set -u" the script dies on an unset variable instead of falling back
# to stdin. Opening it is the only honest check.
tty_usable() {
	[ -c /dev/tty ] || return 1
	( exec < /dev/tty ) 2>/dev/null
}

read_line() {
	_prompt="$1"
	_default="${2:-}"
	_value=""

	if [ -n "$_default" ]; then
		_msg="$_prompt [$_default]: "
	else
		_msg="$_prompt: "
	fi

	if tty_usable; then
		printf "%s" "$_msg" > /dev/tty
		IFS= read -r _value < /dev/tty || _value=""
	else
		printf "%s" "$_msg" >&2
		IFS= read -r _value || _value=""
	fi

	[ -n "$_value" ] || _value="$_default"
	printf "%s" "$_value"
}

read_secret() {
	_prompt="$1"
	_value=""

	if tty_usable; then
		printf "%s" "$_prompt" > /dev/tty
		stty -echo < /dev/tty 2>/dev/null || true
		IFS= read -r _value < /dev/tty || _value=""
		stty echo < /dev/tty 2>/dev/null || true
		printf "\n" > /dev/tty
	else
		printf "%s" "$_prompt" >&2
		stty -echo 2>/dev/null || true
		IFS= read -r _value || _value=""
		stty echo 2>/dev/null || true
		printf "\n" >&2
	fi

	printf "%s" "$_value"
}

trim() {
	printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

validate_hostname() {
	case "$1" in
		"") return 1 ;;
		*[!A-Za-z0-9._-]*) return 1 ;;
		.*|*..*|*.) return 1 ;;
	esac
	return 0
}

validate_port() {
	case "$1" in
		"") return 1 ;;
		*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

# Accepts "host", "host:port", "https://host/path" and anything in between.
parse_server() {
	_s="$(trim "$1")"
	_s="${_s#http://}"
	_s="${_s#https://}"
	_s="${_s%%/*}"

	SERVER="${_s%%:*}"
	case "$_s" in
		*:*) PORT="${_s##*:}" ;;
		*)   PORT="" ;;
	esac
}

ask_params() {
	echo
	echo "=== SSTP management tunnel ==="

	parse_server "$(read_line "SSTP server (host or host:port)" "")"
	USERNAME="$(trim "$(read_line "Username" "")")"
	PASSWORD="$(read_secret "Password: ")"
	# Offer what is already configured, so a reinstall does not silently reset a
	# list someone tuned for this router.
	_cur_res="$(uci -q get "network.${NET_SECTION}.resolvers" || true)"
	_def_res="${_cur_res:-$DEFAULT_RESOLVERS}"

	# Asked as a confirmation rather than as a blank to fill in: the common case
	# is pressing Enter, and a prompt that only shows a default without saying
	# what to do with it reads like a question with no clear answer.
	echo
	echo "DNS servers the tunnel will use to resolve ${SERVER}:"
	echo "  ${_def_res}"
	_ans="$(trim "$(read_line "Enter to accept, 'n' for the system resolver, or type your own" "y")")"
	case "$_ans" in
		y|Y|yes|Yes|YES)              RESOLVERS="$_def_res" ;;
		n|N|no|No|NO|none|None|NONE|-) RESOLVERS="" ;;
		*)                            RESOLVERS="$_ans" ;;
	esac

	# Commas are as natural as spaces when typing a list of addresses.
	RESOLVERS="$(echo "$RESOLVERS" | tr ',;' '  ' | tr -s ' ' | sed 's/^ //;s/ $//')"

	validate_hostname "$SERVER" || die "Bad server name: '${SERVER}'"
	[ -z "$PORT" ] || validate_port "$PORT" || die "Bad port: '${PORT}'"
	[ -n "$USERNAME" ] || die "Username is empty."
	[ -n "$PASSWORD" ] || die "Password is empty."

	case "$USERNAME" in
		*[\'\"\\]*) die "Username contains quotes or backslashes, sstpc cannot take it." ;;
	esac

	for _r in $RESOLVERS; do
		is_ipv4 "$_r" || die "Bad DNS server address: '${_r}'"
	done

	echo
	log "Server: ${SERVER}${PORT:+:$PORT}"
	log "Username: ${USERNAME}"
	if [ -n "$RESOLVERS" ]; then
		log "DNS for the tunnel: ${RESOLVERS}, then the system resolver"
	else
		log "DNS for the tunnel: system resolver"
	fi
}

# --------------------------------------------------------------- preflight

is_ipv4() {
	case "$1" in
		*[!0-9.]*) return 1 ;;
	esac
	echo "$1" | awk -F. 'NF != 4 { exit 1 } { for (i = 1; i <= 4; i++) if ($i == "" || $i + 0 > 255) exit 1 }'
}

# Ask nslookup, optionally against a specific server, and print the IPv4
# answers. Two formats are in the wild: busybox built with FEATURE_NSLOOKUP_BIG,
# which is what OpenWrt ships, prints answers as "Address: 1.2.3.4" after a
# "Name:" line, while the older code prints "Address 1: 1.2.3.4 name". Either
# way the resolver's own address comes first, as "Address:<tab>127.0.0.1#53", so
# skip to the first answer marker before reading anything.
nslookup_ips() {
	have nslookup || return 0
	nslookup "$1" ${2:+"$2"} 2>/dev/null | awk '
		/^Name:/ { answers = 1 }
		/^[[:space:]]*$/ { answers = 1; next }
		!answers { next }
		/^Address/ {
			for (i = 1; i <= NF; i++)
				if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) print $i
		}' | head -3
}

resolve_host() {
	if is_ipv4 "$1"; then
		echo "$1"
		return
	fi

	# The servers the tunnel itself will use come first, so an install run while
	# the local resolver is down behaves the way the tunnel will, and the check
	# does not pass on a resolver the tunnel is never going to ask.
	for _r in ${RESOLVERS:-}; do
		_ips="$(nslookup_ips "$1" "$_r")"
		[ -z "$_ips" ] || { echo "$_ips"; return; }
	done

	# resolveip comes with sstp-client, so on a first install it is usually not
	# there yet and nslookup does the work.
	if have resolveip; then
		_ips="$(resolveip -4 -t 5 "$1" 2>/dev/null | head -3)"
		[ -z "$_ips" ] || { echo "$_ips"; return; }
	fi

	_ips="$(nslookup_ips "$1")"
	[ -z "$_ips" ] || { echo "$_ips"; return; }

	ping -4 -c 1 -w 5 "$1" 2>/dev/null | sed -n '1s/.*(\([0-9.]*\)).*/\1/p'
}

# Separate from resolve_host: tells us whether the name resolves at all, even
# when no address could be parsed out of the output.
host_resolves() {
	have nslookup || return 1
	nslookup "$1" >/dev/null 2>&1
}

check_uplink() {
	log "Checking that ${SERVER} resolves"
	SERVER_IPS="$(resolve_host "$SERVER")"

	if [ -n "$SERVER_IPS" ]; then
		ok "Resolved to: $(echo "$SERVER_IPS" | tr '\n' ' ')"
	elif host_resolves "$SERVER"; then
		# The name does resolve, we just could not read an address out of the
		# output. Never block an install over a parsing difference.
		warn "${SERVER} resolves but its address could not be parsed, continuing."
	else
		die "Cannot resolve ${SERVER}. Fix WAN/DNS first, nothing was changed."
	fi

	_port="${PORT:-443}"
	probe_port "$_port"
}

# An SSTP server says nothing until it gets a TLS client hello, so a successful
# probe looks like a connection that hangs. Anything that returns quickly with a
# message is a real connect failure.
probe_port() {
	have nc || return 0
	_p="$1"

	# The nc in some busybox builds is the stripped one: no -w, no -z, just
	# "nc IPADDR PORT". Feeding it flags only prints a usage text, so find out
	# first and bound the run with timeout instead.
	if nc -w 1 127.0.0.1 1 </dev/null 2>&1 | grep -qi '^usage'; then
		have timeout || return 0
		log "Probing TCP ${SERVER}:${_p}"
		_out="$(timeout 5 nc "$SERVER" "$_p" </dev/null 2>&1)"
		_rc="$?"
		case "$_rc" in
			0)         ok "Port ${_p} accepts connections" ;;
			124|137|143) ok "Port ${_p} is open (server stays silent until the TLS handshake)" ;;
			*)
				warn "Cannot open TCP ${SERVER}:${_p}: ${_out:-exit ${_rc}}"
				warn "Continuing, but the tunnel needs that port to be reachable."
				;;
		esac
		return 0
	fi

	log "Probing TCP ${SERVER}:${_p}"
	_out="$(nc -w 5 "$SERVER" "$_p" </dev/null 2>&1)"
	_rc="$?"
	if [ "$_rc" = "0" ]; then
		ok "Port ${_p} accepts connections"
	else
		case "$_out" in
			*timeout*)
				ok "Port ${_p} is open (server stays silent until the TLS handshake)"
				;;
			*)
				warn "Cannot open TCP ${SERVER}:${_p}: ${_out:-exit ${_rc}}"
				warn "Continuing, but the tunnel needs that port to be reachable."
				;;
		esac
	fi
}

check_listeners() {
	have netstat || return 0
	_l="$(netstat -ltn 2>/dev/null)"
	case "$_l" in
		*":22 "*) ;;
		*) warn "Nothing is listening on TCP 22 (dropbear off?), SSH over the tunnel will fail." ;;
	esac
	case "$_l" in
		*":80 "*) ;;
		*) warn "Nothing is listening on TCP 80 (uhttpd off?), LuCI over the tunnel will fail." ;;
	esac
}

# ---------------------------------------------------------------- backup

# Keep the last 3 pairs. These files contain the tunnel password, and on a 16 MB
# router the older generations are not worth their space.
prune_backups() {
	ls -1t "$BACKUP_DIR"/network.*.bak 2>/dev/null | tail -n +4 | while read -r f; do rm -f "$f"; done
	ls -1t "$BACKUP_DIR"/firewall.*.bak 2>/dev/null | tail -n +4 | while read -r f; do rm -f "$f"; done
}

backup_configs() {
	umask 077
	mkdir -p "$BACKUP_DIR" || die "Cannot create ${BACKUP_DIR}"
	chmod 700 "$BACKUP_DIR"

	# Reinstalls and repeated runs are the normal way this script is used, and
	# each one used to leave another identical pair on the overlay. Flash is the
	# scarce resource on a router, not RAM, so reuse the newest backup when
	# nothing has changed since it was taken. Rollback is unaffected: the file it
	# would restore holds exactly the same bytes.
	_prev_net="$(ls -1t "$BACKUP_DIR"/network.*.bak 2>/dev/null | head -1)"
	_prev_fw="$(ls -1t "$BACKUP_DIR"/firewall.*.bak 2>/dev/null | head -1)"
	if have cmp && [ -n "$_prev_net" ] && [ -n "$_prev_fw" ] &&
		cmp -s /etc/config/network "$_prev_net" &&
		cmp -s /etc/config/firewall "$_prev_fw"; then
		NET_BAK="$_prev_net"
		FW_BAK="$_prev_fw"
		prune_backups
		umask 022
		ok "Configs unchanged, reusing backups: ${NET_BAK}, ${FW_BAK}"
		return 0
	fi

	TS="$(date +%F-%H%M%S)"
	NET_BAK="${BACKUP_DIR}/network.${TS}.bak"
	FW_BAK="${BACKUP_DIR}/firewall.${TS}.bak"

	cp /etc/config/network "$NET_BAK" || die "Cannot back up /etc/config/network"
	cp /etc/config/firewall "$FW_BAK" || die "Cannot back up /etc/config/firewall"

	prune_backups

	umask 022
	ok "Backups: ${NET_BAK}, ${FW_BAK}"
}

# ---------------------------------------------------------------- packages

pkg_version() {
	case "$PKG" in
		opkg)
			opkg list-installed sstp-client 2>/dev/null | awk '{ print $3; exit }'
			;;
		apk)
			# Read the package db directly instead of parsing apk CLI output.
			awk -v want="sstp-client" '
				/^P:/ { pkg = substr($0, 3) }
				/^V:/ { if (pkg == want) { print substr($0, 3); exit } }
			' /lib/apk/db/installed 2>/dev/null
			;;
	esac
}

# opkg package lists land in /var/opkg-lists, which is tmpfs. On a 64 MB router
# that is the single biggest memory cost of this script, so skip the update when
# the lists are less than a day old and drop them as soon as we are done.
opkg_lists_fresh() {
	[ -d /var/opkg-lists ] || return 1
	[ -n "$(find /var/opkg-lists -maxdepth 1 -type f -mtime -1 2>/dev/null | head -1)" ]
}

pkg_cache_clean() {
	case "$PKG" in
		opkg) rm -rf /var/opkg-lists/* 2>/dev/null || true ;;
		apk)  rm -rf /var/cache/apk/* 2>/dev/null || true ;;
	esac
	sync 2>/dev/null || true
}

pkg_refresh_index() {
	case "$PKG" in
		opkg)
			if opkg_lists_fresh; then
				log "Package lists are fresh, skipping opkg update"
				return 0
			fi
			[ "$MEM_KB" -ge "$MIN_MEM_KB" ] 2>/dev/null || die \
				"Only ${MEM_KB} KiB RAM available, opkg update needs about ${MIN_MEM_KB} KiB. Reboot and retry."
			log "opkg update"
			opkg update >/dev/null || { pkg_cache_clean; die "opkg update failed, check the uplink."; }
			;;
		apk)
			log "apk update"
			apk update >/dev/null 2>&1 || warn "apk update failed, trying the cached index"
			;;
	esac
}

# Installs one package, refreshing the index at most once per run.
pkg_install_one() {
	[ "${INDEX_READY:-0}" = "1" ] || { pkg_refresh_index; INDEX_READY=1; }

	log "Installing $1"
	case "$PKG" in
		opkg) opkg install "$1" >/dev/null || return 1 ;;
		apk)  apk add "$1" >/dev/null 2>&1 || return 1 ;;
	esac
	return 0
}

# sstp-client 1.0.17 and later fetch MD4 explicitly from the OpenSSL legacy
# provider to build the MS-CHAPv2 password hash:
#
#   EVP_MD_fetch(NULL, OSSL_DIGEST_NAME_MD4, "provider=legacy")   sstp-chap.c
#
# Without that provider the fetch returns NULL, sstpc logs "Could not create
# password hash", never derives the MPPE keys, and the SSTP crypto binding it
# sends is wrong. PPP authentication still succeeds, so the only visible symptom
# is on the server: "invalid Compound MAC" immediately after a successful
# MS-CHAPv2, followed by a terminated session. The 1.0.15 build used the static
# EVP_md4() instead and needs none of this.
needs_md4_provider() {
	[ "$(pkg_version)" != "$PIN_VERSION" ]
}

ensure_md4_provider() {
	needs_md4_provider || return 0

	if [ -f "$MD4_MODULE" ]; then
		ok "OpenSSL legacy provider present (MD4 for MS-CHAPv2)"
	else
		log "sstp-client $(pkg_version) needs MD4 from the OpenSSL legacy provider"
		if ! pkg_install_one libopenssl-legacy; then
			warn "Could not install libopenssl-legacy. MS-CHAPv2 will fail with"
			warn "'Could not create password hash' and the server will report"
			warn "'invalid Compound MAC'. The ${PIN_VERSION} fallback can still save this."
			return 1
		fi
	fi

	# The package activates itself through uci, but an earlier manual install may
	# have left it disabled.
	if [ "$(uci -q get openssl.legacy.enabled 2>/dev/null)" != "1" ]; then
		log "Enabling the legacy provider in /etc/config/openssl"
		uci set openssl.legacy=provider 2>/dev/null || true
		uci set openssl.legacy.enabled=1 2>/dev/null || true
		uci commit openssl 2>/dev/null || true
		/etc/init.d/openssl reload >/dev/null 2>&1 || true
	fi
	return 0
}

install_package() {
	_installed="$(pkg_version)"
	if [ -n "$_installed" ] && [ -x /usr/bin/sstpc ]; then
		ok "sstp-client ${_installed} already installed, not touching the repos"
	else
		[ "$OVERLAY_KB" -ge "$MIN_OVERLAY_KB" ] 2>/dev/null \
			|| die "Only ${OVERLAY_KB} KiB free on the overlay, the packages need about ${MIN_OVERLAY_KB} KiB."
		pkg_install_one sstp-client || { pkg_cache_clean; die "Cannot install sstp-client."; }
		ok "Installed sstp-client $(pkg_version)"
	fi

	ensure_md4_provider || true

	# resolveip arrives as a dependency of sstp-client and the handler cannot
	# resolve the server without it, while check_package_files refuses to go on.
	# This covers the case where the package was pruned from an existing install.
	have resolveip || pkg_install_one resolveip \
		|| warn "Cannot install resolveip, the handler will not be able to resolve the server."

	pkg_cache_clean
}

check_package_files() {
	[ -x /usr/bin/sstpc ] || die "/usr/bin/sstpc missing after install."
	[ -f /usr/lib/sstp-pppd-plugin.so ] || warn "/usr/lib/sstp-pppd-plugin.so missing, pppd integration may fail."
	[ -x /usr/sbin/pppd ] || die "/usr/sbin/pppd missing, install the ppp package."
	have resolveip || die "resolveip missing, the protocol handler needs it to resolve the server."
	[ -x /lib/netifd/ppp-up ] || die "/lib/netifd/ppp-up missing, netifd ppp support is incomplete."
}

# Fallback for opkg systems when the current build still cannot establish the
# tunnel: 1.0.15-1 predates both the args[20] blowup in practice and the MD4
# provider fetch. Not possible under apk, 25.12 ships the same 1.0.20-r1.
pin_old_sstp_client() {
	[ "$PKG" = "opkg" ] || return 1

	_arch="$(opkg print-architecture | awk '$1 == "arch" && $2 != "all" && $2 != "noarch" { if (+$3 > +p) { p = $3; a = $2 } } END { print a }')"
	[ -n "$_arch" ] || { warn "Cannot detect the opkg architecture, skipping the pin."; return 1; }

	_pkg="sstp-client_${PIN_VERSION}_${_arch}.ipk"
	_url="https://downloads.openwrt.org/releases/${PIN_RELEASE}/packages/${_arch}/packages/${_pkg}"

	log "Downloading sstp-client ${PIN_VERSION} (${_arch})"
	if ! wget -q -O "/tmp/${_pkg}" "$_url"; then
		rm -f "/tmp/${_pkg}"
		warn "Cannot download ${_url}"
		return 1
	fi

	log "Installing sstp-client ${PIN_VERSION} over the current one"
	if ! opkg install --force-downgrade "/tmp/${_pkg}" >/dev/null; then
		rm -f "/tmp/${_pkg}"
		warn "Cannot install ${_pkg}"
		return 1
	fi

	rm -f "/tmp/${_pkg}"
	ok "Pinned sstp-client $(pkg_version). An opkg upgrade will undo this."
	return 0
}

# ------------------------------------------------------- protocol handler

install_proto_files() {
	log "Installing the ${PROTO} protocol handler"

	mkdir -p /etc/ppp /lib/netifd/proto

	cat > "$PPP_OPTS_FILE" <<'EOF'
# Managed by openwrt-sstp-tunnel, edits are overwritten on reinstall.
#
# These options live in a file instead of the sstpc command line because
# sstp-client can only forward 8 arguments to pppd before it overflows its
# fixed args[20] buffer (openwrt/packages#27318).
#
# pppd is started as root, so "file" on its command line keeps privileged_option
# set while reading this file. That is what makes the OPT_PRIV options below
# (ip-up-script and friends) acceptable here rather than only on the argv.
require-mschap-v2
refuse-pap
noauth
nodefaultroute
noipv6
ip-up-script /lib/netifd/ppp-up
ipv6-up-script /lib/netifd/ppp-up
ip-down-script /lib/netifd/ppp-down
ipv6-down-script /lib/netifd/ppp-down
lcp-echo-interval 20
lcp-echo-failure 3
EOF
	chmod 644 "$PPP_OPTS_FILE"

	cat > "$PROTO_FILE" <<'EOF'
#!/bin/sh
# Managed by openwrt-sstp-tunnel, edits are overwritten on reinstall.
#
# Minimal SSTP protocol handler for a management tunnel. It exists because the
# stock /lib/netifd/proto/sstp.sh hands pppd 13 arguments while sstp-client can
# only carry 8 (fixed args[20] in sstp_pppd_start, 11 slots plus NULL are used
# by sstpc itself). The overflow corrupts sstpc's stack and pppd then dies with
# "unrecognized option <garbage>". See openwrt/packages#27318.
#
# Permanent pppd options are in /etc/ppp/options.sstpm and the per-interface
# ones in a generated /var/etc/sstpm-<config>.options, so this passes 2
# arguments no matter what is configured, which fits.

[ -x /usr/bin/sstpc ] || exit 0

PPP_OPTS="/etc/ppp/options.sstpm"

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_sstpm_init_config() {
	proto_config_add_string "server"
	proto_config_add_string "port"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_string "sstp_options"
	proto_config_add_string "resolvers"
	proto_config_add_int "log_level"
	proto_config_add_int "mtu"
	available=1
	no_device=1
}

# Parse IPv4 answers out of nslookup, optionally against a given server. Two
# busybox formats are in the wild: "Address: 1.2.3.4" under a "Name:" line, and
# the older "Address 1: 1.2.3.4 name". Either way the resolver's own address is
# printed first, so skip to the first answer marker before reading anything.
sstpm_lookup() {
	nslookup "$1" ${2:+"$2"} 2>/dev/null | awk '
		/^Name:/ { answers = 1 }
		/^[[:space:]]*$/ { answers = 1; next }
		!answers { next }
		/^Address/ {
			for (i = 1; i <= NF; i++)
				if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) print $i
		}'
}

# Resolve through the servers listed in the interface's "resolvers" option, in
# order, and fall back to the system resolver when none of them answers. This is
# the difference between a management tunnel that survives a broken resolver and
# one that does not: on a router where something like podkop owns DNS, that
# something going down takes the system resolver with it, and a tunnel that
# cannot resolve its server is a tunnel that cannot be used to go fix the router.
# Nothing here touches /etc/resolv.conf or dnsmasq, so the rest of the box keeps
# resolving exactly as it did.
#
# A server that refuses the connection costs nothing, one that black-holes it
# costs five seconds before nslookup gives up, which is why the local resolver
# belongs first in the list and public ones after it.
sstpm_resolve() {
	local host="$1"
	local servers="$2"
	local s ips

	for s in $servers; do
		ips="$(sstpm_lookup "$host" "$s")"
		[ -n "$ips" ] && { echo "$ips"; return 0; }
	done

	ips="$(resolveip -4 -t 5 "$host" 2>/dev/null)"
	[ -n "$ips" ] && { echo "$ips"; return 0; }

	sstpm_lookup "$host"
}

proto_sstpm_setup() {
	local config="$1"
	local ifname="sstp-$config"
	local ip serv_addr server port username password sstp_options log_level mtu
	local resolvers
	local _opts _local _peer _addrs _count _try _target _state

	[ -f "$PPP_OPTS" ] || {
		echo "Missing $PPP_OPTS, reinstall openwrt-sstp-tunnel"
		proto_notify_error "$config" NO_PPP_OPTIONS
		proto_block_restart "$config"
		exit 1
	}

	json_get_vars server port username password sstp_options resolvers log_level mtu

	_addrs=""
	for ip in $(sstpm_resolve "$server" "$resolvers" | sort -u); do
		( proto_add_host_dependency "$config" "$ip" )
		_addrs="${_addrs}${ip} "
		serv_addr=1
	done
	[ -n "$serv_addr" ] || {
		echo "Could not resolve $server"
		sleep 5
		proto_setup_failed "$config"
		exit 1
	}

	# sstp-client resolves the server itself and only ever tries the first
	# address: sstp_client_lookup in src/sstp-client.c takes list->ai_addr from
	# getaddrinfo and never walks the rest of the list. Names published through a
	# service like KeenDNS carry several A records of which only some accept 443,
	# and the local resolver keeps handing out the same cached order for the whole
	# TTL, so one dead address in front means netifd retries into the same timeout
	# for as long as that lasts. Walk the addresses here instead, one per attempt,
	# and hand sstpc the name separately: --host is what it uses for SNI, the HTTP
	# Host header and certificate verification, which matters when the endpoint is
	# behind a host-routed proxy. The option is missing from --help but has been in
	# the option table since 1.0.15.
	_count="$(echo $_addrs | wc -w)"
	if [ "$_count" -gt 1 ]; then
		_state="/var/run/sstpm-${config}.attempt"
		_try="$(cat "$_state" 2>/dev/null)"
		case "$_try" in ''|*[!0-9]*) _try=0 ;; esac
		_target="$(echo $_addrs | cut -d' ' -f$(( _try % _count + 1 )))"
		echo $(( (_try + 1) % _count )) > "$_state"
		echo "Connecting to ${_target}, address $(( _try % _count + 1 )) of ${_count} for ${server}"
	fi

	[ -n "$log_level" ] || log_level=1

	# No interface update before pppd here on purpose. An empty update marks the
	# interface up seconds after ifup, long before IPCP, and anything waiting on
	# ifstatus then sees "up": true with no address. /lib/netifd/ppp-up reports
	# the real state once the address exists, same as the stock ppp handlers.

	# Everything that varies per interface goes into a generated options file
	# instead of the command line. pppd gets "ipparam" that way, which is what
	# /lib/netifd/ppp-up reads out of its sixth argument to know which netifd
	# interface to report to. sstpc accepts --ipparam but keeps it to itself: it
	# never reaches pppd (src/sstp-pppd.c builds the argv without it), so with
	# the stock handler ppp-up calls proto_send_update with an empty name and
	# netifd never learns the address. This also keeps the pppd argument count
	# at 2 of the 8 sstpc can forward, mtu or no mtu.
	mkdir -p /var/etc
	_opts="/var/etc/sstpm-${config}.options"
	{
		echo "file $PPP_OPTS"
		echo "ifname $ifname"
		echo "ipparam $config"
		[ -n "$mtu" ] && echo "mtu $mtu" && echo "mru $mtu"
	} > "$_opts"

	# Unquoted optional expansions on purpose: an empty argument would reach
	# pppd as "" and be reported as an unrecognized option.
	proto_run_command "$config" /usr/bin/sstpc \
		--cert-warn \
		--log-level "$log_level" \
		--save-server-route \
		--ipparam "$config" \
		--user "$username" \
		--password "$password" \
		${_target:+--host "$server"} \
		$sstp_options \
		"${_target:-$server}${port:+:$port}" \
		file "$_opts"

	# The ppp device shows up after sstpc and pppd have negotiated, netifd and
	# fw4 need a nudge to attach the zone to it (same workaround as upstream).
	# proto_set_keep matters here: ppp-up has already reported the address by
	# now, and without keep this second update would drop it.
	sleep 10
	_local="$(ip -4 -o addr show dev "$ifname" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
	_peer="$(ip -4 -o addr show dev "$ifname" 2>/dev/null | sed -n 's/.*peer \([0-9.]*\).*/\1/p' | head -1)"
	proto_init_update "$ifname" 1
	proto_set_keep 1
	# Same address ppp-up reported, repeated from the device itself: netifd
	# dedupes it, and an interface that is up with no address stays impossible
	# even if the ip-up hook never runs. No default route and no DNS on purpose,
	# this is a management tunnel.
	[ -n "$_local" ] && proto_add_ipv4_address "$_local" 32 "" "$_peer"
	proto_send_update "$config"
	/etc/init.d/firewall reload >/dev/null 2>&1
}

proto_sstpm_teardown() {
	local config="$1"

	case "$ERROR" in
		11|19)
			proto_notify_error "$config" AUTH_FAILED
			proto_block_restart "$config"
		;;
		2)
			proto_notify_error "$config" INVALID_OPTIONS
			proto_block_restart "$config"
		;;
	esac
	proto_kill_command "$config"
	rm -f "/var/etc/sstpm-${config}.options"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol sstpm
}
EOF
	chmod 755 "$PROTO_FILE"
	sh -n "$PROTO_FILE" || die "Generated ${PROTO_FILE} is not valid shell."
	ok "Handler installed, pppd argument count: 2 of 8 allowed"
}

install_hotplug() {
	mkdir -p "$(dirname "$HOTPLUG_FILE")"

	cat > "$HOTPLUG_FILE" <<EOF
#!/bin/sh
# Managed by openwrt-sstp-tunnel, edits are overwritten on reinstall.
# Safety net for the case where netifd gave up on the tunnel while the uplink
# was down. One restart per five minutes at most.

[ "\$ACTION" = "ifup" ] || exit 0
[ "\$INTERFACE" = "${NET_SECTION}" ] && exit 0
case "\${DEVICE:-}" in sstp-*) exit 0 ;; esac

LOCK="/tmp/sstp-tunnel-nudge.lock"
NOW="\$(date +%s)"
if [ -f "\$LOCK" ]; then
	read -r THEN < "\$LOCK" 2>/dev/null || THEN=0
	[ "\$(( NOW - \${THEN:-0} ))" -lt 300 ] && exit 0
fi
echo "\$NOW" > "\$LOCK"

(
	sleep 20
	STATUS="\$(ifstatus ${NET_SECTION} 2>/dev/null)"
	case "\$STATUS" in
		*'"up": true'*|*'"pending": true'*) exit 0 ;;
	esac

	logger -t sstp-tunnel "tunnel down after \$INTERFACE came up, restarting it once"
	ifdown ${NET_SECTION} 2>/dev/null
	sleep 3
	ifup ${NET_SECTION} 2>/dev/null
) &
# The lock is deliberately left behind: its age is what rate limits this to one
# attempt per five minutes, however many interfaces come up in a row.

exit 0
EOF
	chmod 755 "$HOTPLUG_FILE"
	sh -n "$HOTPLUG_FILE" || die "Generated ${HOTPLUG_FILE} is not valid shell."
}

# ------------------------------------------------------------------- config

purge_sections() {
	for _s in $NET_SECTIONS; do
		uci -q delete "network.${_s}" || true
	done
	for _s in $FW_SECTIONS; do
		uci -q delete "firewall.${_s}" || true
	done
}

stop_tunnel() {
	# ifdown prints "Interface <name> not found" on stdout, not stderr, so both
	# streams go to /dev/null: before the first install there is nothing to stop.
	ifdown "$NET_SECTION" >/dev/null 2>&1 || true

	# Kill only what belongs to this tunnel: sstpc is started with
	# "--ipparam sstp" and its pppd with "ifname sstp-sstp". A PPPoE WAN or a
	# second tunnel must survive.
	if have pgrep; then
		for _p in $(pgrep -f "ipparam ${NET_SECTION}" 2>/dev/null) \
			  $(pgrep -f "ifname sstp-${NET_SECTION}" 2>/dev/null); do
			kill "$_p" 2>/dev/null || true
		done
	else
		killall sstpc 2>/dev/null || true
	fi
}

configure_network() {
	log "Configuring network.${NET_SECTION}"

	uci set "network.${NET_SECTION}=interface"
	uci set "network.${NET_SECTION}.proto=${PROTO}"
	uci set "network.${NET_SECTION}.server=${SERVER}"
	[ -z "$PORT" ] || uci set "network.${NET_SECTION}.port=${PORT}"
	uci set "network.${NET_SECTION}.username=${USERNAME}"
	uci set "network.${NET_SECTION}.password=${PASSWORD}"
	uci set "network.${NET_SECTION}.sstp_options=--tls-ext"
	if [ -n "$RESOLVERS" ]; then
		uci set "network.${NET_SECTION}.resolvers=${RESOLVERS}"
	else
		uci -q delete "network.${NET_SECTION}.resolvers" || true
	fi
	# Read by netifd itself, not by the handler. /lib/netifd/ppp-up offers a
	# default route through the peer and the server's DNS; a management tunnel
	# must not take over the routing table or resolution of the whole router.
	uci set "network.${NET_SECTION}.defaultroute=0"
	uci set "network.${NET_SECTION}.peerdns=0"
	uci set "network.${NET_SECTION}.log_level=1"
	uci set "network.${NET_SECTION}.auto=1"
}

configure_firewall() {
	log "Configuring the ${ZONE} firewall zone: 22, 80, ping in, nothing else"

	uci set "firewall.${ZONE}=zone"
	uci set "firewall.${ZONE}.name=${ZONE}"
	uci set "firewall.${ZONE}.network=${NET_SECTION}"
	uci set "firewall.${ZONE}.input=REJECT"
	uci set "firewall.${ZONE}.forward=REJECT"
	uci set "firewall.${ZONE}.output=REJECT"

	uci set firewall.allow_ssh_from_sstp=rule
	uci set firewall.allow_ssh_from_sstp.name=Allow-SSH-from-SSTP
	uci set firewall.allow_ssh_from_sstp.src="$ZONE"
	uci set firewall.allow_ssh_from_sstp.proto=tcp
	uci set firewall.allow_ssh_from_sstp.dest_port=22
	uci set firewall.allow_ssh_from_sstp.target=ACCEPT

	uci set firewall.allow_http_from_sstp=rule
	uci set firewall.allow_http_from_sstp.name=Allow-HTTP-from-SSTP
	uci set firewall.allow_http_from_sstp.src="$ZONE"
	uci set firewall.allow_http_from_sstp.proto=tcp
	uci set firewall.allow_http_from_sstp.dest_port=80
	uci set firewall.allow_http_from_sstp.target=ACCEPT

	uci set firewall.allow_ping_from_sstp=rule
	uci set firewall.allow_ping_from_sstp.name=Allow-Ping-from-SSTP
	uci set firewall.allow_ping_from_sstp.src="$ZONE"
	uci set firewall.allow_ping_from_sstp.proto=icmp
	uci set firewall.allow_ping_from_sstp.icmp_type=echo-request
	uci set firewall.allow_ping_from_sstp.family=ipv4
	uci set firewall.allow_ping_from_sstp.target=ACCEPT
}

# ------------------------------------------------------------------ rollback

# Armed before the first service restart: if this installer never confirms
# success, the previous configs come back without anyone having to log in.
rollback_arm() {
	mkdir -p "$STATE_DIR"
	rm -f "${STATE_DIR}/ok"

	cat > "${STATE_DIR}/rollback.sh" <<EOF
#!/bin/sh
waited=0
while [ "\$waited" -lt ${ROLLBACK_WAIT} ]; do
	[ -f "${STATE_DIR}/ok" ] && exit 0
	sleep 5
	waited="\$(( waited + 5 ))"
done

logger -t sstp-tunnel "installer did not confirm success in ${ROLLBACK_WAIT}s, restoring previous config"
ifdown ${NET_SECTION} 2>/dev/null
killall sstpc 2>/dev/null
cp "${NET_BAK}" /etc/config/network
cp "${FW_BAK}" /etc/config/firewall
rm -f "${HOTPLUG_FILE}"
/etc/init.d/firewall restart >/dev/null 2>&1
/etc/init.d/network restart >/dev/null 2>&1
logger -t sstp-tunnel "previous config restored"
EOF
	chmod 755 "${STATE_DIR}/rollback.sh"

	if have setsid; then
		setsid "${STATE_DIR}/rollback.sh" >/dev/null 2>&1 &
	else
		"${STATE_DIR}/rollback.sh" >/dev/null 2>&1 &
	fi

	ok "Unattended rollback armed for ${ROLLBACK_WAIT}s"
}

rollback_disarm() {
	mkdir -p "$STATE_DIR"
	: > "${STATE_DIR}/ok"
}

rollback_now() {
	warn "Restoring the previous configuration"
	rollback_disarm
	stop_tunnel
	cp "$NET_BAK" /etc/config/network 2>/dev/null || true
	cp "$FW_BAK" /etc/config/firewall 2>/dev/null || true
	rm -f "$HOTPLUG_FILE"
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
	/etc/init.d/network reload >/dev/null 2>&1 || true
	warn "Rolled back. ${PROTO_FILE} is left in place but inactive."
}

# -------------------------------------------------------------------- apply

apply_config() {
	uci commit network || die "uci commit network failed."
	uci commit firewall || die "uci commit firewall failed."
	chmod 600 /etc/config/network

	log "Reloading firewall"
	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true

	log "Reloading network"
	/etc/init.d/network reload >/dev/null 2>&1 || true
	sleep 3

	# netifd registers protocol handlers at startup, so a brand new handler is
	# unknown until it restarts. Avoid that restart whenever we can: it briefly
	# flaps every interface on the router. An interface whose protocol is
	# unknown either disappears or falls back to "none", so check the protocol
	# netifd actually reports, not just that the interface exists.
	if proto_is_live; then
		ok "netifd already knows the ${PROTO} protocol, no restart needed"
	else
		warn "netifd does not know ${PROTO} yet, restarting it once (brief network flap)"
		/etc/init.d/network restart >/dev/null 2>&1 || die "network restart failed."
		sleep 8
		proto_is_live \
			|| die "netifd still does not accept protocol ${PROTO}, check 'logread -e netifd'."
	fi
}

proto_is_live() {
	ifstatus "$NET_SECTION" 2>/dev/null | grep -q "\"proto\": *\"${PROTO}\""
}

# The IPv4 address netifd holds for the tunnel, empty until IPCP is done and
# /lib/netifd/ppp-up has reported it. Both the bring-up gate and verify ask for
# it, and asking too early is the whole reason the first working tunnel was
# rolled back as a failure.
parse_ipv4() {
	sed -n 's/.*"address": *"\([0-9][0-9.]*\)".*/\1/p' | head -1
}

tunnel_ipv4() {
	ifstatus "$NET_SECTION" 2>/dev/null | parse_ipv4
}

bring_up() {
	log "Bringing the tunnel up, waiting up to ${UP_TIMEOUT}s"
	ifup "$NET_SECTION" >/dev/null 2>&1 || true

	_waited=0
	while [ "$_waited" -lt "$UP_TIMEOUT" ]; do
		_status="$(ifstatus "$NET_SECTION" 2>/dev/null)"
		case "$_status" in
			*AUTH_FAILED*)  err "Server rejected the credentials (AUTH_FAILED)."; return 2 ;;
			*NO_PPP_OPTIONS*) err "The handler cannot find ${PPP_OPTS_FILE}."; return 2 ;;
		esac
		# "up": true alone is not readiness: the address arrives with it when
		# ppp-up reports, and a link without one is not a usable tunnel.
		case "$_status" in
			*'"up": true'*)
				[ -n "$(printf '%s\n' "$_status" | parse_ipv4)" ] && return 0
				;;
		esac
		sleep 3
		_waited="$(( _waited + 3 ))"
		# The handler itself waits 10s before its second interface update, so
		# without this the installer looks frozen for over a minute.
		[ "$(( _waited % 15 ))" = "0" ] && log "still negotiating, ${_waited}s of ${UP_TIMEOUT}s"
	done
	return 1
}

# Remember how long the ring buffer is, so the overflow check below only ever
# looks at lines produced by our own attempt. A stale "unrecognized option" from
# an earlier attempt must not trigger the version pin.
log_mark() {
	LOG_MARK="$(logread 2>/dev/null | wc -l | tr -d ' ')"
	[ -n "$LOG_MARK" ] || LOG_MARK="0"
}

log_since_mark() {
	logread 2>/dev/null | tail -n "+$(( ${LOG_MARK:-0} + 1 ))"
}

# Did we hit the args[20] overflow? That is one of the two defects the pin fixes.
hit_arg_overflow() {
	log_since_mark | grep -qi 'unrecognized option'
}

# The other one: no MD4, so no password hash, so a crypto binding the server
# rejects as "invalid Compound MAC" while the router's log looks almost clean.
hit_md4_failure() {
	log_since_mark | grep -qi 'could not create password hash'
}

verify() {
	_rc=0

	_dev="$(ifstatus "$NET_SECTION" 2>/dev/null | sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' | head -1)"
	if [ -n "$_dev" ] && ip link show "$_dev" >/dev/null 2>&1; then
		ok "Device: ${_dev}"
	else
		err "No ppp device for the tunnel"
		_rc=1
	fi

	_ip="$(tunnel_ipv4)"
	if [ -n "$_ip" ]; then
		ok "Tunnel address: ${_ip}"
	else
		err "The tunnel has no IPv4 address"
		_rc=1
	fi

	if have nft; then
		if nft list table inet fw4 2>/dev/null | grep -q 'Allow-SSH-from-SSTP'; then
			ok "Firewall rules are live in nftables"
		else
			err "Allow-SSH-from-SSTP is not in the live ruleset"
			_rc=1
		fi
	elif have iptables-save; then
		if iptables-save 2>/dev/null | grep -q 'Allow-SSH-from-SSTP'; then
			ok "Firewall rules are live in iptables"
		else
			err "Allow-SSH-from-SSTP is not in the live ruleset"
			_rc=1
		fi
	fi

	check_listeners
	return "$_rc"
}

# --------------------------------------------------------------- commands

install_cmd() {
	require_root
	detect_platform
	check_resources
	ask_params
	check_uplink

	backup_configs
	PINNED=0
	install_package
	check_package_files

	stop_tunnel
	install_proto_files
	install_hotplug

	purge_sections
	configure_network
	configure_firewall

	rollback_arm
	apply_config

	log_mark
	bring_up
	_up="$?"

	# A timeout (1), unlike rejected credentials (2), can still be a package
	# defect, so try the known good build once before giving up.
	if [ "$_up" = "1" ] && [ "$PINNED" = "0" ] && [ "$(pkg_version)" != "$PIN_VERSION" ]; then
		if hit_arg_overflow; then
			warn "pppd reported an unrecognized option: the args[20] overflow is still happening."
		elif hit_md4_failure; then
			warn "sstpc could not hash the password: MD4 from the OpenSSL legacy provider"
			warn "is still unavailable, so the crypto binding cannot be computed."
		else
			warn "No usable tunnel and no obvious cause in the log, trying sstp-client ${PIN_VERSION}."
		fi
		if pin_old_sstp_client; then
			PINNED=1
			stop_tunnel
			log_mark
			bring_up
			_up="$?"
		fi
	fi

	if [ "$_up" != "0" ]; then
		err "The tunnel did not come up."
		echo
		echo "--- last SSTP/PPP log lines ---"
		logread 2>/dev/null | grep -Ei 'sstp|pppd|chap|auth' | tail -25
		echo "-------------------------------"
		echo "If this log looks clean, check the server side too: when the crypto"
		echo "binding fails, the server logs 'invalid Compound MAC' right after a"
		echo "successful MS-CHAPv2 and the router sees nothing unusual."
		rollback_now
		exit 1
	fi

	ok "Tunnel is up"
	if verify; then
		rollback_disarm
		echo
		echo "=== done ==="
		echo "From the tunnel this router accepts only TCP 22, TCP 80 and ping."
		echo "Server: ${SERVER}${PORT:+:$PORT}   interface: ${NET_SECTION}   protocol: ${PROTO}"
		[ "$PINNED" = "1" ] && echo "sstp-client was pinned to ${PIN_VERSION}: an opkg upgrade will undo that."
		echo "Status any time: ${SELF_CMD} status"
	else
		err "The tunnel is up but the checks above failed."
		rollback_now
		exit 1
	fi
}

status_cmd() {
	# Soft detection: status must work even on a half-installed or unusual box.
	if have apk && [ -d /lib/apk ]; then
		PKG="apk"
	elif have opkg; then
		PKG="opkg"
	else
		PKG=""
	fi

	echo "=== package ==="
	if [ -n "$PKG" ]; then
		echo "sstp-client: $(pkg_version) (${PKG})"
		if needs_md4_provider; then
			if [ -f "$MD4_MODULE" ]; then
				echo "OpenSSL legacy provider: present, enabled=$(uci -q get openssl.legacy.enabled || echo '?')"
			else
				echo "OpenSSL legacy provider: MISSING, this version needs MD4 from it"
			fi
		fi
	fi
	[ -x /usr/bin/sstpc ] && /usr/bin/sstpc --version 2>&1 | head -1

	echo
	echo "=== protocol handler ==="
	if [ -f "$PROTO_FILE" ]; then
		echo "${PROTO_FILE}: present"
	else
		echo "${PROTO_FILE}: MISSING, run install"
	fi
	if [ -f "$PPP_OPTS_FILE" ]; then
		echo "${PPP_OPTS_FILE}: present"
	else
		echo "${PPP_OPTS_FILE}: MISSING, run install"
	fi
	[ -f /lib/netifd/proto/sstp.sh ] && echo "stock sstp.sh is also present (unused, untouched)"

	echo
	echo "=== network config ==="
	uci show "network.${NET_SECTION}" 2>/dev/null | sed "s/password='.*'/password='***'/" || echo "not configured"

	echo
	echo "=== dns ==="
	_srv="$(uci -q get "network.${NET_SECTION}.server" || true)"
	_res="$(uci -q get "network.${NET_SECTION}.resolvers" || true)"
	if [ -z "$_res" ]; then
		echo "resolvers: not set, the system resolver is used"
	else
		for _r in $_res; do
			if [ -n "$_srv" ]; then
				_a="$(nslookup_ips "$_srv" "$_r")"
				if [ -n "$_a" ]; then
					echo "${_r}: $(echo $_a | tr '\n' ' ')"
				else
					echo "${_r}: no answer"
				fi
			else
				echo "${_r}: configured"
			fi
		done
	fi
	[ -z "$_srv" ] || echo "system resolver: $(nslookup_ips "$_srv" | tr '\n' ' ' | sed 's/ $//')"

	echo
	echo "=== firewall config ==="
	for _s in "$ZONE" allow_ssh_from_sstp allow_http_from_sstp allow_ping_from_sstp; do
		uci show "firewall.${_s}" 2>/dev/null || true
	done

	echo
	echo "=== interface ==="
	ifstatus "$NET_SECTION" 2>/dev/null || echo "netifd does not know ${NET_SECTION}"

	echo
	echo "=== live rules ==="
	if have nft; then
		nft list table inet fw4 2>/dev/null | grep -i 'sstp' || echo "no sstp rules in the live ruleset"
	elif have iptables-save; then
		iptables-save 2>/dev/null | grep -i 'sstp' || echo "no sstp rules in the live ruleset"
	fi

	echo
	echo "=== processes ==="
	ps w 2>/dev/null | grep -E 'sstpc|pppd' | grep -v grep || echo "none"

	echo
	echo "=== autostart ==="
	[ -f "$HOTPLUG_FILE" ] && echo "${HOTPLUG_FILE}: present" || echo "${HOTPLUG_FILE}: missing"

	echo
	echo "=== recent log ==="
	logread 2>/dev/null | grep -Ei 'sstp|pppd|chap|auth' | tail -40 || true
}

remove_cmd() {
	require_root
	detect_platform
	backup_configs

	log "Removing the tunnel configuration"
	stop_tunnel
	purge_sections
	uci commit network || true
	uci commit firewall || true

	rm -f "$HOTPLUG_FILE" "$PROTO_FILE" "$PPP_OPTS_FILE"
	rm -rf "$STATE_DIR"

	# A reload is enough to drop the interface. netifd keeps the now deleted
	# protocol handler registered until the next reboot, which is harmless, so
	# do not restart the network and flap every interface over it.
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
	/etc/init.d/network reload >/dev/null 2>&1 || true

	ok "Removed. sstp-client stays installed, backups are in ${BACKUP_DIR}."
}

case "${1:-}" in
	install) install_cmd ;;
	status)  status_cmd ;;
	remove)  remove_cmd ;;
	-h|--help|help|"") usage ;;
	*) usage; exit 1 ;;
esac

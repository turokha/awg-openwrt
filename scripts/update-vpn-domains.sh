#!/bin/sh
set -eu

PRIMARY_URL='https://raw.githubusercontent.com/turokha/awg-openwrt/master/lists/vpn-domains.txt'
FALLBACK_API_URL='https://api.github.com/repos/turokha/awg-openwrt/contents/lists/vpn-domains.txt?ref=master'
DIR='/etc/pbr'
DEST="$DIR/vpn-domains.txt"
BAK="$DIR/vpn-domains.txt.bak"
RAW="$(mktemp /tmp/vpn-domains.raw.XXXXXX)"
NEW="$(mktemp /tmp/vpn-domains.new.XXXXXX)"
APIJSON="$(mktemp /tmp/vpn-domains.api.XXXXXX)"

cleanup() {
	rm -f "$RAW" "$NEW" "$APIJSON"
}
trap cleanup EXIT INT TERM

log() {
	logger -t vpn-domains "$*"
	echo "$*"
}

mkdir -p "$DIR"

download_primary() {
	curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 45 --retry 2 "$PRIMARY_URL" -o "$RAW"
}

download_fallback() {
	curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 45 --retry 2 \
		-H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		"$FALLBACK_API_URL" -o "$APIJSON" || return 1

	[ "$(jsonfilter -i "$APIJSON" -e '@.encoding' 2>/dev/null)" = 'base64' ] || return 1
	jsonfilter -i "$APIJSON" -e '@.content' 2>/dev/null | tr -d '\r\n ' | base64 -d > "$RAW"
	[ -s "$RAW" ]
}

if [ "${FORCE_FALLBACK:-0}" = '1' ]; then
	log "FORCE_FALLBACK=1: skipping direct source"
	if ! download_fallback; then
		log "ERROR: VPN fallback download failed; keeping current list"
		exit 1
	fi
	log "Downloaded list through GitHub API fallback"
elif download_primary; then
	log "Downloaded list from direct source"
else
	log "Direct source failed; trying GitHub API fallback through AWG"
	if ! download_fallback; then
		log "ERROR: both direct and VPN fallback downloads failed; keeping current list"
		exit 1
	fi
	log "Downloaded list through GitHub API fallback"
fi

if ! awk '
{
	gsub(/\r/, "")
	sub(/#.*/, "")
	gsub(/^[ \t]+|[ \t]+$/, "")
	if ($0 == "") next
	d = tolower($0)
	if (d !~ /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/ || d !~ /\./ || d ~ /\.\./) {
		print "Invalid domain: " $0 > "/dev/stderr"
		bad = 1
		next
	}
	print d
}
END { if (bad) exit 2 }
' "$RAW" | sort -u > "$NEW"; then
	log "ERROR: validation failed; keeping current list"
	exit 1
fi

COUNT="$(wc -l < "$NEW" | tr -d ' ')"
if [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 50000 ]; then
	log "ERROR: unreasonable domain count ($COUNT); keeping current list"
	exit 1
fi

if [ -f "$DEST" ] && cmp -s "$NEW" "$DEST"; then
	log "No changes ($COUNT domains)"
	exit 0
fi

if [ -f "$DEST" ]; then
	cp -f "$DEST" "$BAK"
fi

cp -f "$NEW" "$DEST"
chmod 0644 "$DEST"

(/etc/init.d/pbr reload >/tmp/vpn-domains-pbr.log 2>&1 || true)
sleep 1

if /etc/init.d/pbr running >/dev/null 2>&1 && nft list set inet fw4 pbr_awg0_4_dst_ip_vpn_domains >/dev/null 2>&1 && grep -q 'pbr_awg0_4_dst_ip_vpn_domains' /var/run/pbr.dnsmasq 2>/dev/null; then
	log "Updated successfully ($COUNT domains)"
	exit 0
fi

log "ERROR: PBR validation failed; rolling back"
if [ -f "$BAK" ]; then
	cp -f "$BAK" "$DEST"
	(/etc/init.d/pbr reload >/dev/null 2>&1 || true)
fi
exit 1

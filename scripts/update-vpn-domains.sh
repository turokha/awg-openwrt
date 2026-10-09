#!/bin/sh
set -eu

UPSTREAM_RAW_URL='https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/ru-blocked.txt'
UPSTREAM_API_URL='https://api.github.com/repos/runetfreedom/russia-blocked-geosite/contents/ru-blocked.txt?ref=release'
MANUAL_RAW_URL='https://raw.githubusercontent.com/turokha/awg-openwrt/master/lists/vpn-domains.txt'
MANUAL_API_URL='https://api.github.com/repos/turokha/awg-openwrt/contents/lists/vpn-domains.txt?ref=master'

DIR='/etc/pbr'
DEST="$DIR/vpn-domains.txt"
BAK="$DIR/vpn-domains.txt.bak"
RAW="$(mktemp /tmp/vpn-domains.raw.XXXXXX)"
MANUAL="$(mktemp /tmp/vpn-domains.manual.XXXXXX)"
NEW="$(mktemp /tmp/vpn-domains.new.XXXXXX)"

cleanup() {
	rm -f "$RAW" "$MANUAL" "$NEW"
}
trap cleanup EXIT INT TERM

log() {
	logger -t vpn-domains "$*"
	echo "$*"
}

mkdir -p "$DIR"

download_raw() {
	url="$1"
	out="$2"
	curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 90 --retry 2 "$url" -o "$out"
}

download_api_raw() {
	url="$1"
	out="$2"
	curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 90 --retry 2 \
		-H 'Accept: application/vnd.github.raw+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		"$url" -o "$out"
}

if [ "${FORCE_FALLBACK:-0}" = '1' ]; then
	log "FORCE_FALLBACK=1: using GitHub API through AWG"
	download_api_raw "$UPSTREAM_API_URL" "$RAW" || {
		log "ERROR: upstream VPN fallback download failed; keeping current list"
		exit 1
	}
else
	if download_raw "$UPSTREAM_RAW_URL" "$RAW"; then
		log "Downloaded upstream blocked-domain list directly"
	else
		log "Direct upstream download failed; trying GitHub API through AWG"
		download_api_raw "$UPSTREAM_API_URL" "$RAW" || {
			log "ERROR: upstream direct and VPN fallback downloads failed; keeping current list"
			exit 1
		}
		log "Downloaded upstream blocked-domain list through GitHub API fallback"
	fi
fi

if ! download_raw "$MANUAL_RAW_URL" "$MANUAL"; then
	log "Manual list direct download failed; trying GitHub API through AWG"
	download_api_raw "$MANUAL_API_URL" "$MANUAL" || {
		log "WARNING: manual additions unavailable; continuing with upstream only"
		: > "$MANUAL"
	}
fi

{
	awk '
	/^domain:/ {
		d=$0
		sub(/^domain:/, "", d)
		gsub(/\r/, "", d)
		d=tolower(d)
		if (d ~ /^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/ && d ~ /\./ && d !~ /\.\./) print d
	}
	' "$RAW"

	awk '
	{
		gsub(/\r/, "")
		sub(/#.*/, "")
		gsub(/^[ \t]+|[ \t]+$/, "")
		if ($0 == "") next
		d=tolower($0)
		if (d ~ /^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/ && d ~ /\./ && d !~ /\.\./) print d
	}
	' "$MANUAL"
} | sort -u > "$NEW"

COUNT="$(wc -l < "$NEW" | tr -d ' ')"
if [ "$COUNT" -lt 10000 ] || [ "$COUNT" -gt 150000 ]; then
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
sleep 2

if /etc/init.d/pbr running >/dev/null 2>&1 \
	&& nft list set inet fw4 pbr_awg0_4_dst_ip_user >/dev/null 2>&1 \
	&& grep -q 'pbr_awg0_4_dst_ip_user' /var/run/pbr.dnsmasq 2>/dev/null; then
	log "Updated successfully ($COUNT domains)"
	exit 0
fi

log "ERROR: PBR validation failed; rolling back"
if [ -f "$BAK" ]; then
	cp -f "$BAK" "$DEST"
	(/etc/init.d/pbr reload >/dev/null 2>&1 || true)
fi
exit 1

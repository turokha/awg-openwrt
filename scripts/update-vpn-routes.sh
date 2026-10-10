#!/bin/sh
set -eu

DOMAIN_RAW='https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/ru-blocked.txt'
DOMAIN_API='https://api.github.com/repos/runetfreedom/russia-blocked-geosite/contents/ru-blocked.txt?ref=release'
NETWORK_RAW='https://antifilter.download/list/subnet.lst'

MANUAL_DOMAIN_RAW='https://raw.githubusercontent.com/turokha/awg-openwrt/master/lists/manual-vpn-domains.txt'
MANUAL_DOMAIN_API='https://api.github.com/repos/turokha/awg-openwrt/contents/lists/manual-vpn-domains.txt?ref=master'
MANUAL_NETWORK_RAW='https://raw.githubusercontent.com/turokha/awg-openwrt/master/lists/manual-vpn-networks.txt'
MANUAL_NETWORK_API='https://api.github.com/repos/turokha/awg-openwrt/contents/lists/manual-vpn-networks.txt?ref=master'

DIR='/etc/pbr'
DOMAIN_DEST="$DIR/vpn-domains.txt"
NETWORK_DEST="$DIR/vpn-networks.txt"
DOMAIN_BAK="$DIR/vpn-domains.txt.bak"
NETWORK_BAK="$DIR/vpn-networks.txt.bak"
MANUAL_DOMAIN_CACHE="$DIR/manual-vpn-domains.txt"
MANUAL_NETWORK_CACHE="$DIR/manual-vpn-networks.txt"

DOMAIN_RAW_TMP="$(mktemp /tmp/vpn-domain-upstream.XXXXXX)"
NETWORK_RAW_TMP="$(mktemp /tmp/vpn-network-upstream.XXXXXX)"
MANUAL_DOMAIN_TMP="$(mktemp /tmp/vpn-domain-manual.XXXXXX)"
MANUAL_NETWORK_TMP="$(mktemp /tmp/vpn-network-manual.XXXXXX)"
DOMAIN_NEW="$(mktemp /tmp/vpn-domains.new.XXXXXX)"
NETWORK_NEW="$(mktemp /tmp/vpn-networks.new.XXXXXX)"

cleanup() {
	rm -f "$DOMAIN_RAW_TMP" "$NETWORK_RAW_TMP"
	rm -f "$MANUAL_DOMAIN_TMP" "$MANUAL_NETWORK_TMP"
	rm -f "$DOMAIN_NEW" "$NETWORK_NEW"
}
trap cleanup EXIT INT TERM

log() {
	logger -t vpn-routes "$*"
	echo "$*"
}

mkdir -p "$DIR"

download_raw() {
	url="$1"
	out="$2"
	curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 "$url" -o "$out"
}

download_api_raw() {
	url="$1"
	out="$2"
	curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 \
		-H 'Accept: application/vnd.github.raw+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		"$url" -o "$out"
}

download_github_source() {
	raw_url="$1"
	api_url="$2"
	out="$3"
	label="$4"

	if [ "${FORCE_FALLBACK:-0}" = '1' ]; then
		download_api_raw "$api_url" "$out" || return 1
		log "Downloaded $label through GitHub API fallback"
		return 0
	fi

	if download_raw "$raw_url" "$out"; then
		log "Downloaded $label directly"
		return 0
	fi

	log "Direct $label download failed; trying GitHub API through AWG"
	download_api_raw "$api_url" "$out" || return 1
	log "Downloaded $label through GitHub API fallback"
}

download_github_source "$DOMAIN_RAW" "$DOMAIN_API" "$DOMAIN_RAW_TMP" 'blocked-domain list' || {
	log "ERROR: blocked-domain source unavailable; keeping current routes"
	exit 1
}

NETWORK_SOURCE_CACHE="$DIR/auto-vpn-networks.txt"

if download_raw "$NETWORK_RAW" "$NETWORK_RAW_TMP"; then
	log "Downloaded explicit blocked-subnet list directly"
	cp -f "$NETWORK_RAW_TMP" "$NETWORK_SOURCE_CACHE"
elif [ -s "$NETWORK_SOURCE_CACHE" ]; then
	log "WARNING: blocked-subnet source unavailable; using cached copy"
	cp -f "$NETWORK_SOURCE_CACHE" "$NETWORK_RAW_TMP"
else
	log "ERROR: blocked-subnet source unavailable and no cache exists; keeping current routes"
	exit 1
fi

if download_github_source "$MANUAL_DOMAIN_RAW" "$MANUAL_DOMAIN_API" "$MANUAL_DOMAIN_TMP" 'manual domain list'; then
	cp -f "$MANUAL_DOMAIN_TMP" "$MANUAL_DOMAIN_CACHE"
elif [ -s "$MANUAL_DOMAIN_CACHE" ]; then
	log "WARNING: using cached manual domain list"
	cp -f "$MANUAL_DOMAIN_CACHE" "$MANUAL_DOMAIN_TMP"
else
	log "ERROR: manual domain list unavailable and no cache exists"
	exit 1
fi

if download_github_source "$MANUAL_NETWORK_RAW" "$MANUAL_NETWORK_API" "$MANUAL_NETWORK_TMP" 'manual network list'; then
	cp -f "$MANUAL_NETWORK_TMP" "$MANUAL_NETWORK_CACHE"
elif [ -s "$MANUAL_NETWORK_CACHE" ]; then
	log "WARNING: using cached manual network list"
	cp -f "$MANUAL_NETWORK_CACHE" "$MANUAL_NETWORK_TMP"
else
	log "ERROR: manual network list unavailable and no cache exists"
	exit 1
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
	' "$DOMAIN_RAW_TMP"

	awk '
	{
		gsub(/\r/, "")
		sub(/#.*/, "")
		gsub(/^[ \t]+|[ \t]+$/, "")
		if ($0 == "") next
		d=tolower($0)
		if (d ~ /^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/ && d ~ /\./ && d !~ /\.\./) print d
	}
	' "$MANUAL_DOMAIN_TMP"
} | sort -u > "$DOMAIN_NEW"

{
	cat "$NETWORK_RAW_TMP"
	cat "$MANUAL_NETWORK_TMP"
} | awk '
{
	gsub(/\r/, "")
	sub(/#.*/, "")
	gsub(/^[ \t]+|[ \t]+$/, "")
	if ($0 == "") next

	n=split($0, p, "/")
	if (n < 1 || n > 2) next

	m=split(p[1], a, ".")
	if (m != 4) next

	ok=1
	for (i=1; i<=4; i++) {
		if (a[i] !~ /^[0-9]+$/ || a[i] < 0 || a[i] > 255) ok=0
	}
	if (!ok) next

	prefix=(n == 2 ? p[2] : 32)
	if (prefix !~ /^[0-9]+$/ || prefix < 0 || prefix > 32) next

	printf "%d.%d.%d.%d/%d\n", a[1], a[2], a[3], a[4], prefix
}
' | sort -u > "$NETWORK_NEW"

DOMAIN_COUNT="$(wc -l < "$DOMAIN_NEW" | tr -d ' ')"
NETWORK_COUNT="$(wc -l < "$NETWORK_NEW" | tr -d ' ')"

if [ "$DOMAIN_COUNT" -lt 10000 ] || [ "$DOMAIN_COUNT" -gt 150000 ]; then
	log "ERROR: unreasonable domain count ($DOMAIN_COUNT); keeping current routes"
	exit 1
fi

if [ "$NETWORK_COUNT" -lt 1 ] || [ "$NETWORK_COUNT" -gt 2000 ]; then
	log "ERROR: unreasonable IPv4 network count ($NETWORK_COUNT); keeping current routes"
	exit 1
fi

if grep -qx '0.0.0.0/0' "$NETWORK_NEW"; then
	log "ERROR: default route found in IPv4 network list; keeping current routes"
	exit 1
fi

if grep -Eq '/([0-7])

DOMAIN_CHANGED=1
NETWORK_CHANGED=1
[ -f "$DOMAIN_DEST" ] && cmp -s "$DOMAIN_NEW" "$DOMAIN_DEST" && DOMAIN_CHANGED=0
[ -f "$NETWORK_DEST" ] && cmp -s "$NETWORK_NEW" "$NETWORK_DEST" && NETWORK_CHANGED=0

if [ "$DOMAIN_CHANGED" -eq 0 ] && [ "$NETWORK_CHANGED" -eq 0 ]; then
	log "No changes ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
	exit 0
fi

DOMAIN_HAD_OLD=0
NETWORK_HAD_OLD=0

if [ -f "$DOMAIN_DEST" ]; then
	cp -f "$DOMAIN_DEST" "$DOMAIN_BAK"
	DOMAIN_HAD_OLD=1
fi

if [ -f "$NETWORK_DEST" ]; then
	cp -f "$NETWORK_DEST" "$NETWORK_BAK"
	NETWORK_HAD_OLD=1
fi

cp -f "$DOMAIN_NEW" "$DOMAIN_DEST"
cp -f "$NETWORK_NEW" "$NETWORK_DEST"
chmod 0644 "$DOMAIN_DEST" "$NETWORK_DEST"

(/etc/init.d/pbr reload >/tmp/vpn-routes-pbr.log 2>&1 || true)
sleep 2

if /etc/init.d/pbr running >/dev/null 2>&1 \
	&& nft list set inet fw4 pbr_awg0_4_dst_ip_user >/dev/null 2>&1 \
	&& grep -q 'pbr_awg0_4_dst_ip_user' /var/run/pbr.dnsmasq 2>/dev/null \
	&& nft list set inet fw4 pbr_awg0_4_dst_ip_user 2>/dev/null | grep -q 'elements = {'; then
	log "Updated successfully ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
	exit 0
fi

log "ERROR: PBR validation failed; rolling back"

if [ "$DOMAIN_HAD_OLD" -eq 1 ]; then
	cp -f "$DOMAIN_BAK" "$DOMAIN_DEST"
else
	rm -f "$DOMAIN_DEST"
fi

if [ "$NETWORK_HAD_OLD" -eq 1 ]; then
	cp -f "$NETWORK_BAK" "$NETWORK_DEST"
else
	rm -f "$NETWORK_DEST"
fi

(/etc/init.d/pbr reload >/dev/null 2>&1 || true)
exit 1
 "$NETWORK_NEW"; then
	log "ERROR: dangerously broad IPv4 prefix found; keeping current routes"
	exit 1
fi

DOMAIN_CHANGED=1
NETWORK_CHANGED=1
[ -f "$DOMAIN_DEST" ] && cmp -s "$DOMAIN_NEW" "$DOMAIN_DEST" && DOMAIN_CHANGED=0
[ -f "$NETWORK_DEST" ] && cmp -s "$NETWORK_NEW" "$NETWORK_DEST" && NETWORK_CHANGED=0

if [ "$DOMAIN_CHANGED" -eq 0 ] && [ "$NETWORK_CHANGED" -eq 0 ]; then
	log "No changes ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
	exit 0
fi

DOMAIN_HAD_OLD=0
NETWORK_HAD_OLD=0

if [ -f "$DOMAIN_DEST" ]; then
	cp -f "$DOMAIN_DEST" "$DOMAIN_BAK"
	DOMAIN_HAD_OLD=1
fi

if [ -f "$NETWORK_DEST" ]; then
	cp -f "$NETWORK_DEST" "$NETWORK_BAK"
	NETWORK_HAD_OLD=1
fi

cp -f "$DOMAIN_NEW" "$DOMAIN_DEST"
cp -f "$NETWORK_NEW" "$NETWORK_DEST"
chmod 0644 "$DOMAIN_DEST" "$NETWORK_DEST"

(/etc/init.d/pbr reload >/tmp/vpn-routes-pbr.log 2>&1 || true)
sleep 2

if /etc/init.d/pbr running >/dev/null 2>&1 \
	&& nft list set inet fw4 pbr_awg0_4_dst_ip_user >/dev/null 2>&1 \
	&& grep -q 'pbr_awg0_4_dst_ip_user' /var/run/pbr.dnsmasq 2>/dev/null \
	&& nft list set inet fw4 pbr_awg0_4_dst_ip_user 2>/dev/null | grep -q 'elements = {'; then
	log "Updated successfully ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
	exit 0
fi

log "ERROR: PBR validation failed; rolling back"

if [ "$DOMAIN_HAD_OLD" -eq 1 ]; then
	cp -f "$DOMAIN_BAK" "$DOMAIN_DEST"
else
	rm -f "$DOMAIN_DEST"
fi

if [ "$NETWORK_HAD_OLD" -eq 1 ]; then
	cp -f "$NETWORK_BAK" "$NETWORK_DEST"
else
	rm -f "$NETWORK_DEST"
fi

(/etc/init.d/pbr reload >/dev/null 2>&1 || true)
exit 1

#!/bin/sh
# Compatibility wrapper. The unified updater now handles domains and IPv4 networks.
exec /etc/pbr/update-vpn-routes.sh "$@"

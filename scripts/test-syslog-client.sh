#!/usr/bin/env bash
# Run on a Linux host INSIDE syslog_allowed_source_cidrs.
#   ./test-syslog-client.sh syslog.internal.contoso.com
set -euo pipefail
TARGET="${1:?usage: $0 <collector-ip-or-dns>}"
TAG="lz-syslog-test-$(hostname)-$(date +%s)"

logger --server "$TARGET" --port 514 --udp "$TAG udp"            && echo "sent UDP/514"
logger --server "$TARGET" --port 514 --tcp "$TAG tcp"            && echo "sent TCP/514"
echo "<134>$TAG nc-udp" | nc -u -w1 "$TARGET" 514                && echo "sent nc UDP/514"

if command -v openssl >/dev/null; then
  # RFC 5425 octet-counted frame over TLS.
  MSG="<134>1 $(date -u +%FT%TZ) $(hostname) lztest - - - $TAG tls"
  printf '%s %s' "${#MSG}" "$MSG" |
    timeout 5 openssl s_client -connect "$TARGET:6514" -quiet 2>/dev/null && echo "sent TLS/6514"
fi

echo
echo "Check on the collector:  sudo grep -r '$TAG' /var/log/remote/"
echo "Check in Log Analytics:  Syslog | where SyslogMessage has '$TAG'"

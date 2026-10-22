#!/usr/bin/env bash
# Capture the machine's network state, so "works with WARP, not without"
# can be diffed instead of guessed at.
#
#   scripts/net-diag.sh > /tmp/net-diag-with-warp.txt   # WARP on
#   scripts/net-diag.sh > /tmp/net-diag-no-warp.txt     # WARP off
#   diff /tmp/net-diag-with-warp.txt /tmp/net-diag-no-warp.txt
set -u

section() { printf '\n===== %s =====\n' "$1"; }

section "WARP processes"
ps aux | grep -iE "cloudflare ?warp|cloudflared" | grep -v grep | sed 's/--token [^ ]*/--token <redacted>/' | cut -c1-140 || echo "(none)"

section "interfaces"
ifconfig 2>/dev/null | grep -E "^[a-z0-9]+:|inet " | grep -v "inet6" | head -40

section "routes that matter"
netstat -rn -f inet 2>/dev/null | awk 'NR<=3 || $1 ~ /^(default|10\.|172\.|192\.168\.|224\.)/ {print}' | head -25

section "default route"
route -n get default 2>/dev/null | grep -E "gateway|interface"

section "DNS resolvers (scutil)"
scutil --dns 2>/dev/null | grep -E "resolver #|nameserver|search domain" | head -20

section "DNS per network service"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r s; do
  case "$s" in
    "An asterisk"*) continue ;;
  esac
  printf '%-30s ' "$s"
  networksetup -getdnsservers "$s" 2>/dev/null | tr '\n' ' '
  echo
done

section "system resolver test"
for h in github.com devstroop.com; do
  printf '%-24s ' "$h"
  dscacheutil -q host -a name "$h" 2>/dev/null | awk '/ip_address/{printf "%s ", $2} END{print ""}' | head -1
  [ -z "$(dscacheutil -q host -a name "$h" 2>/dev/null)" ] && echo "NO ANSWER (system resolver)"
done

section "raw TCP egress (no DNS, no proxy)"
for target in 1.1.1.1:443 140.82.121.4:443 8.8.8.8:53; do
  host=${target%:*}; port=${target##*:}
  printf '%-22s ' "$target"
  nc -z -G 5 "$host" "$port" >/dev/null 2>&1 && echo "OK" || echo "BLOCKED"
done

section "HTTP through the system stack"
for u in https://github.com/ https://api.github.com/; do
  printf '%-30s ' "$u"
  curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" --max-time 10 "$u" 2>&1 || echo FAILED
done

section "git transport"
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || cd .
printf 'git ls-remote: '
timeout 25 git ls-remote origin HEAD >/dev/null 2>&1 && echo OK || echo FAILED
printf 'gh api:       '
timeout 25 gh api rate_limit >/dev/null 2>&1 && echo OK || echo FAILED

section "the app's own LAN bind (the seam over the network)"
APP_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/apps/net-spike"
if [ -x "$APP_DIR/zig-out/bin/net-spike" ]; then
  for iface in en0 en1 en5; do
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
    [ -z "$ip" ] && continue
    printf 'bind %-6s %-16s ' "$iface" "$ip"
    ROS_SPIKE_BIND="$ip" timeout 12 "$APP_DIR/zig-out/bin/net-spike" 2>&1 | grep -oE "SEAM OK|SEAM FAILED|no answer within the timeout" | head -1
  done
  printf 'bind loopback  '
  timeout 12 "$APP_DIR/zig-out/bin/net-spike" 2>&1 | grep -oE "SEAM OK|SEAM FAILED|no answer within the timeout" | head -1
else
  echo "(the spike is not built: native build apps/net-spike)"
fi

section "macOS application firewall"
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null

section "system proxy"
scutil --proxy 2>/dev/null

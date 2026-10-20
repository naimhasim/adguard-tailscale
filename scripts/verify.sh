#!/usr/bin/env bash
# =============================================================================
#  verify.sh - prove the containerised stack is healthy.
#
#  With Tailscale inside a Docker network the host cannot reach 100.x.y.z at
#  all (correctly - there is no route and no interface), so every network check
#  is executed *inside* the tailscale container's namespace via nsenter. That
#  is the same namespace AdGuard lives in, so it is a faithful test of "what a
#  tailnet peer sees".
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
sec() { printf '\n\033[1m%s\033[0m\n' "$1"; }

TSPID=$(docker inspect -f '{{.State.Pid}}' tailscale 2>/dev/null)
in_ts() { nsenter -t "$TSPID" -n -- "$@"; }
TSIP=$(docker exec tailscale tailscale ip -4 2>/dev/null | tr -d '\r' | head -1)

# ------------------------------------------------------------------ 1. tailscale
sec "1. Tailscale connected"
TS_JSON=$(docker exec tailscale tailscale status --json 2>/dev/null)
grep -q '"BackendState": *"Running"' <<<"$TS_JSON" \
    && ok "tailscaled BackendState = Running" || bad "tailscaled is not Running"
DNSNAME=$(grep -o '"DNSName": *"[^"]*"' <<<"$TS_JSON" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
[[ -n "$DNSNAME" ]] && ok "tailnet name: ${DNSNAME%.}"
# NOTE: parse Self only. ExitNodeOption also appears on *peers* (other devices
# in the tailnet that offer to be an exit node) - grepping the whole JSON would
# report someone else's node as ours.
if command -v python3 >/dev/null 2>&1; then
    EXITOPT=$(python3 -c "import json,sys;print(json.load(sys.stdin)['Self'].get('ExitNodeOption'))" <<<"$TS_JSON" 2>/dev/null)
    [[ "$EXITOPT" == "True" ]] \
        && ok "this node advertises itself as an exit node (Self.ExitNodeOption=$EXITOPT)" \
        || bad "this node is NOT advertising itself as an exit node"
else
    skip "exit-node check needs host python3"
fi

# ---------------------------------------------------------------------- 2. IP
sec "2. The 100.x address lives in the container, not on the host"
if [[ "$TSIP" =~ ^100\. ]]; then ok "Tailscale IPv4 = $TSIP"; else bad "no 100.x address"; fi

if in_ts ip -4 addr show tailscale0 2>/dev/null | grep -q "$TSIP"; then
    ok "tailscale0 carries $TSIP inside the tailscale container"
else
    bad "tailscale0 does not carry $TSIP inside the container"
fi

# The whole point of this layout: the host must NOT be on the tailnet.
if ip -4 addr show tailscale0 >/dev/null 2>&1; then
    bad "HOST still has a tailscale0 interface - it must not"
else
    ok "host has NO tailscale0 interface"
fi
if ip -4 -brief addr show | grep -q '100\.'; then
    bad "host still holds a 100.x address"
else
    ok "host holds no 100.x address"
fi

# ------------------------------------------------------------------ 3. adguard
sec "3. AdGuard Home running"
[[ "$(docker inspect -f '{{.State.Status}}' adguardhome 2>/dev/null)" == "running" ]] \
    && ok "adguardhome container is running" || bad "adguardhome is not running"
[[ "$(docker inspect -f '{{.State.Status}}' tailscale 2>/dev/null)" == "running" ]] \
    && ok "tailscale container is running" || bad "tailscale is not running"

in_ts ss -lntu 2>/dev/null | grep -qE ':53\s' \
    && ok "AdGuard owns :53 inside the shared namespace" \
    || bad "nothing is listening on :53 in the shared namespace"
if in_ts curl -fsS -m 5 -o /dev/null "http://$TSIP/" 2>/dev/null; then
    ok "admin UI answers on http://$TSIP/"
else
    bad "admin UI not answering on http://$TSIP/"
fi

# both services on the shared Docker network
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' tailscale 2>/dev/null \
    | grep -q 'adguard' && ok "tailscale is attached to the 'adguard' network" \
                       || bad "tailscale is not on the 'adguard' network"
docker inspect -f '{{.HostConfig.NetworkMode}}' adguardhome 2>/dev/null \
    | grep -q 'container:' && ok "adguard shares the tailscale netns (network_mode=container:)" \
                           || bad "adguard is not sharing the tailscale netns"

# ---------------------------------------------------------------------- 4. DNS
sec "4. DNS queries through the Tailscale IP"
if ! command -v dig >/dev/null 2>&1; then
    skip "DNS query checks need host dig (dnsutils)"
else
    for proto in udp tcp; do
        if [[ "$proto" == tcp ]]; then opt="+tcp"; else opt=""; fi
        # Only accept a line that actually looks like an address - dig happily
        # prints its own error text to stdout, which would otherwise pass as an
        # "answer" and hide a dead resolver.
        R=$(in_ts dig $opt +short +time=5 +tries=2 @"$TSIP" example.com A 2>/dev/null \
            | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1)
        [[ -n "$R" ]] && ok "DNS/${proto^^} @${TSIP}:53 -> example.com = $R" \
                       || bad "DNS/${proto^^} @${TSIP}:53 returned no address"
    done
fi

# ------------------------------------------------------------------ 4b. exposed?
sec "4b. Nothing DNS-shaped is reachable from outside"
# No DNS listener on the host at all
if ss -lntu 2>/dev/null | grep -qE ':(53)\s'; then
    bad "something on the HOST is listening on port 53"
else
    ok "host listens on no DNS port (AdGuard is container-only)"
fi
# Nothing is published except the WireGuard port
PUB=$(docker inspect -f '{{json .HostConfig.PortBindings}}' tailscale 2>/dev/null)
grep -q '53' <<<"$PUB" && bad "a DNS port is published to the host" \
                       || ok "no DNS port published by Docker"
# External reachability test from a throwaway netns standing in for the internet
if command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && ip netns add agh_ext 2>/dev/null; then
    ip link add aghveth-e type veth peer name aghveth-h 2>/dev/null
    ip link set aghveth-e netns agh_ext
    ip addr add 192.168.99.1/24 dev aghveth-h 2>/dev/null
    ip link set aghveth-h up
    ip netns exec agh_ext ip addr add 192.168.99.2/24 dev aghveth-e 2>/dev/null
    ip netns exec agh_ext ip link set aghveth-e up
    ip netns exec agh_ext ip link set lo up
    PUBIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    ip netns exec agh_ext ip route add "${PUBIP%.*}.0/24" via 192.168.99.1 2>/dev/null
    OUT=$(ip netns exec agh_ext timeout 12 python3 -c "
import socket
ip='${PUBIP}'
for proto,label in ((socket.SOCK_DGRAM,'UDP'),(socket.SOCK_STREAM,'TCP')):
    s=socket.socket(socket.AF_INET,proto); s.settimeout(3)
    try:
        if proto==socket.SOCK_DGRAM:
            s.sendto(b'\x00'*12,(ip,53))
            try: s.recvfrom(512); print(label,'EXPOSED')
            except Exception: print(label,'BLOCKED')
        else:
            s.connect((ip,53)); print(label,'EXPOSED')
    except Exception: print(label,'BLOCKED')
    finally: s.close()
" 2>/dev/null)
    grep -q EXPOSED <<<"$OUT" && bad "DNS answered on the public IP $PUBIP" \
                              || ok "DNS on public IP $PUBIP is unreachable ($(tr '\n' ' ' <<<"$OUT"))"
    ip netns del agh_ext 2>/dev/null
    ip link del aghveth-h 2>/dev/null
else
    echo "  (could not create a netns - skipping the external exposure test)"
fi

# ----------------------------------------------------------------- 5. restart
sec "5. Configuration survives restarts"
for v in adguard-tailscale_tailscale-state adguard-tailscale_adguard-conf adguard-tailscale_adguard-work; do
    docker volume inspect "$v" >/dev/null 2>&1 && ok "volume $v exists" || bad "volume $v missing"
done
[[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' tailscale)" == "unless-stopped" ]] \
    && ok "tailscale restart policy = unless-stopped" || bad "tailscale restart policy wrong"
[[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' adguardhome)" == "unless-stopped" ]] \
    && ok "adguardhome restart policy = unless-stopped" || bad "adguardhome restart policy wrong"
if command -v systemctl >/dev/null 2>&1; then
    [[ "$(systemctl is-enabled docker 2>/dev/null)" == "enabled" ]] \
        && ok "docker.service is enabled at boot" || bad "docker.service not enabled at boot"
else
    skip "docker.service boot check needs systemd"
fi
docker run --rm -v adguard-tailscale_adguard-conf:/c alpine sh -c 'test -s /c/AdGuardHome.yaml' >/dev/null 2>&1 \
    && ok "AdGuardHome.yaml persisted in the volume" || bad "AdGuardHome.yaml missing"
docker run --rm -v adguard-tailscale_tailscale-state:/s alpine sh -c 'test -s /s/tailscaled.state' >/dev/null 2>&1 \
    && ok "tailscaled.state persisted (no re-auth on boot)" || bad "tailscaled.state missing"

sec "Firewall posture"
ufw status 2>/dev/null | grep -q 'Status: active' && ok "ufw is active" || bad "ufw is not active"
ufw status 2>/dev/null | grep -qE '^53/(udp|tcp) +DENY' && ok "DNS explicitly denied on the host" \
                                                        || bad "no explicit host DNS deny"
WG_PORT=$(grep -E '^TS_WG_PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2-); WG_PORT=${WG_PORT:-41641}
ufw status 2>/dev/null | grep -q "${WG_PORT}/udp" && ok "WireGuard port ${WG_PORT}/udp allowed" || bad "WireGuard port not allowed"
iptables -S DOCKER-USER 2>/dev/null | grep -q 'adguard-tailscale:dns-guard' \
    && ok "DOCKER-USER drops any published DNS port" || bad "DOCKER-USER guard missing"

printf '\n\033[1mSummary: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

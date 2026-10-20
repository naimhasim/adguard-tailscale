#!/usr/bin/env bash
# =============================================================================
#  firewall.sh - host firewall for the containerised AdGuard/Tailscale stack.
#
#  NON-DESTRUCTIVE. This script only ADDS rules:
#    * it never runs `ufw reset`
#    * it never changes your default policies or logging level
#    * it never removes a rule it did not itself add
#  Your existing ufw rules (other services, docker rules, custom ports) are
#  left exactly as they are.
#
#  What it adds (idempotent - ufw skips rules that already exist):
#    * let in the WireGuard tunnel so peers can connect directly
#    * let in SSH for administration
#    * explicitly deny port 53 on the host (AdGuard serves :53 inside the
#      container namespace, never on the host)
#    * a tagged DOCKER-USER rule so Docker can never publish :53 from outside
#
#  Port clashes. If the host already runs Tailscale (or anything else) on the
#  WireGuard UDP port, that port cannot be published by this project's
#  container. The script then stops and asks you to set a free TS_WG_PORT in
#  .env. It never edits .env for you.
#
#  Run as root.
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
cd "$(dirname "$0")/.." || exit 1

command -v ufw >/dev/null 2>&1 || { echo "ufw not installed - nothing to do" >&2; exit 0; }

# --- config: real environment overrides .env, else default --------------------
ENV_FILE=.env
env_get() {
    local name=$1 default=$2 from_env from_file
    from_env=${!name-}
    if [[ -n ${from_env:-} ]]; then printf '%s' "$from_env"; return; fi
    from_file=$(grep -E "^${name}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s' "${from_file:-$default}"
}

DNS_PORT=$(env_get ADGUARD_DNS_PORT 53)
TS_WG_PORT=$(env_get TS_WG_PORT 41641)
SSH_PORT=$(env_get SSH_PORT 22)

# --- port helpers -------------------------------------------------------------
used_udp() { ss -lunH 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u; }
port_in_use() { used_udp | grep -qx "$1"; }

# --- detect a host Tailscale --------------------------------------------------
if ip -o link show 2>/dev/null | grep -qw tailscale0 || pgrep -x tailscaled >/dev/null 2>&1; then
    echo "==> host already runs Tailscale (tailscale0 / tailscaled present)"
    echo "    this stack is a SEPARATE node; make sure TS_HOSTNAME differs."
    if port_in_use "$TS_WG_PORT"; then
        for p in $(seq 41642 42000); do
            if ! port_in_use "$p"; then
                echo "    note: ${TS_WG_PORT}/udp is taken by the host; a free port such as ${p} would work."
                break
            fi
        done
    fi
fi

# --- WireGuard port: must be free on the host --------------------------------
# docker compose publishes ${TS_WG_PORT}/udp (default 41641). A host Tailscale
# daemon owns 41641/udp by default, so a clash is the common case there.
if port_in_use "$TS_WG_PORT"; then
    SUGGEST=""
    for p in $(seq 41642 42000); do
        if ! port_in_use "$p"; then SUGGEST=$p; break; fi
    done
    echo "ERROR: host port ${TS_WG_PORT}/udp is already in use" >&2
    echo "       (a host Tailscale daemon owns 41641/udp by default)." >&2
    if [[ -n "$SUGGEST" ]]; then
        echo "       Suggested free port: ${SUGGEST}" >&2
        echo "       Set it in .env and re-run:" >&2
        echo "           TS_WG_PORT=${SUGGEST}" >&2
    else
        echo "       No free UDP port found in 41642-42000 - choose one yourself." >&2
        echo "       Set it in .env and re-run, e.g.  TS_WG_PORT=<free-port>" >&2
    fi
    exit 1
fi

# --- additive ufw rules -------------------------------------------------------
echo "==> Adding rules (existing rules are left untouched)"
ufw allow in on lo >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH admin' >/dev/null
ufw allow "${TS_WG_PORT}/udp" comment 'Tailscale WireGuard (direct)' >/dev/null
for proto in udp tcp; do
    ufw deny "${DNS_PORT}/${proto}" comment 'No DNS on the host' >/dev/null
done

# Never change the host's firewall posture: only enable if it is off, and say so.
if ufw status 2>/dev/null | grep -q 'Status: active'; then
    echo "==> ufw already active - defaults and logging left as they are"
else
    echo "==> ufw is INACTIVE - rules recorded but not enforced." >&2
    echo "    enable it yourself if that is what you want:  ufw --force enable" >&2
fi

# -----------------------------------------------------------------------------
# Defence in depth. Docker inserts its own nat/DNAT rules that bypass ufw's
# INPUT chain, so ufw cannot see published ports. AdGuard publishes nothing, but
# if a future edit added `53:53` we refuse it from outside here.
#
# Scoped to the PUBLIC interface on purpose: a blanket `--dport 53 -j DROP` also
# kills the container's egress to upstream resolvers (9.9.9.9:53, 1.1.1.1:53)
# and silently breaks AdGuard. Rules are tagged so we only ever remove our own.
# -----------------------------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
    iptables -N DOCKER-USER 2>/dev/null || true
    TAG='adguard-tailscale:dns-guard'

    while read -r spec; do
        [[ -z "$spec" ]] && continue
        # shellcheck disable=SC2086
        iptables -D DOCKER-USER $spec 2>/dev/null || true
    done < <(iptables -S DOCKER-USER 2>/dev/null \
             | sed -n 's/^-A DOCKER-USER //p' | grep -F "$TAG")

    PUBIF=$(ip -4 route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    if [[ -n "${PUBIF:-}" ]]; then
        for proto in udp tcp; do
            iptables -A DOCKER-USER -i "$PUBIF" -p "$proto" --dport "${DNS_PORT}" \
                     -m comment --comment "$TAG" -j DROP
        done
        echo "==> DOCKER-USER: dropping inbound ${DNS_PORT} on ${PUBIF} (tagged ${TAG})"
    else
        echo "    ! could not detect the public interface - skipped" >&2
    fi
fi

echo
echo "==> Done. Current ruleset:"
ufw status

#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh - one-shot, unattended bring-up.
#
#  Assumes .env has TS_AUTHKEY set (that is the whole point: no browser step).
#  Idempotent - re-running it on a healthy stack just re-verifies.
#
#  No host Python required: the helper scripts run in a throwaway container
#  (PY_IMAGE), so nothing has to be installed on the host. Every step runs even
#  if an earlier one failed; the script exits non-zero if any step did.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

PY_IMAGE="${PY_IMAGE:-python:3-alpine}"
FAIL=0
mark() { FAIL=1; echo "  ! step failed (continuing)" >&2; }

# --- preflight ---------------------------------------------------------------
[[ -f .env ]] || { echo "missing .env (cp .env.example .env)" >&2; exit 1; }
chmod 600 .env

if grep -qE '^TS_AUTHKEY=$' .env; then
    echo "WARNING: TS_AUTHKEY is empty in .env - Tailscale will fall back to the" >&2
    echo "         interactive login URL flow instead of an unattended join." >&2
fi

if ss -lntu 2>/dev/null | grep -qE ':53\s'; then
    echo "NOTE: something on the host is listening on :53 (systemd-resolved stub?)." >&2
    echo "      AdGuard is container-only so this does not block the stack." >&2
fi

# --- firewall (additive; aborts on a port clash, that must be fixed first) ----
echo "==> applying host firewall (additive)"
./scripts/firewall.sh

# --- stack -------------------------------------------------------------------
echo "==> starting the stack"
docker compose up -d

echo "==> waiting for Tailscale to reach Running"
for _ in $(seq 1 60); do
    if docker exec tailscale tailscale status --json 2>/dev/null \
        | grep -q '"BackendState": *"Running"'; then
        break
    fi
    sleep 2
done
TSIP=$(docker exec tailscale tailscale ip -4 2>/dev/null | tr -d '\r' | head -1)
echo "    tailnet IP: ${TSIP:-<not assigned>}"

# --- AdGuard -----------------------------------------------------------------
# Run the helper inside the tailscale netns via a throwaway container - the
# script's own wait_for() handles the wizard coming up, so no host curl either.
echo "==> configuring AdGuard Home (helper runs in ${PY_IMAGE})"
docker run --rm --network "container:tailscale" \
    -v "$PWD:/app" -w /app \
    "$PY_IMAGE" python3 scripts/setup-adguard.py --host 127.0.0.1 || mark

# --- your own config overrides -----------------------------------------------
# A fully-commented template is fine - it just reports "nothing to do".
if [[ -f adguard/overrides.yaml ]]; then
    echo "==> applying adguard/overrides.yaml"
    docker compose stop adguard
    docker run --rm \
        -v "adguard-tailscale_adguard-conf:/conf" \
        -v "$PWD:/app" -w /app \
        "$PY_IMAGE" sh -c 'apk add --no-cache py3-yaml >/dev/null 2>&1 && python3 scripts/apply-overrides.py --config-dir /conf --no-restart' || mark
    docker compose start adguard
fi

# --- verify ------------------------------------------------------------------
echo
./scripts/verify.sh || mark

exit "$FAIL"

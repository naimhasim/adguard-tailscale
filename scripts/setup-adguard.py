#!/usr/bin/env python3
"""
setup-adguard.py - seed AdGuard Home non-interactively.

AdGuard Home ships without a config file and serves a setup wizard on :3000.
This script drives that wizard through its official HTTP API so the whole
stack can be provisioned unattended, then applies DNS settings (upstreams,
bootstrap resolvers, rate limiting) and disables the open-resolver behaviour.

Reads values from the .env file next to the compose file.

Because AdGuard lives in the tailscale container's network namespace, the host
cannot reach it on 127.0.0.1. Run this script *inside* that namespace, either
via the bootstrap wrapper or directly:

    P=$(docker inspect -f '{{.State.Pid}}' tailscale)
    nsenter -t "$P" -n -- python3 scripts/setup-adguard.py --host 127.0.0.1

(or point --host at the tailscale IP from any tailnet peer)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENV_FILE = HERE.parent / ".env"


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    env.update({k: v for k, v in os.environ.items() if k.startswith(("ADGUARD_", "TS_"))})
    return env


def http(method: str, url: str, payload=None, cookie: str | None = None, timeout=10):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if cookie:
        req.add_header("Cookie", cookie)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode(errors="replace")
        return r.status, body, r.headers.get_all("Set-Cookie") or []


def wait_for(url: str, label: str, tries: int = 90, delay: float = 1.0) -> bool:
    for _ in range(tries):
        try:
            urllib.request.urlopen(url, timeout=3)
            return True
        except urllib.error.HTTPError:
            return True  # responding, just not 200
        except Exception:
            time.sleep(delay)
    print(f"  ! timed out waiting for {label}", file=sys.stderr)
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1",
                    help="address AdGuard is reachable on from where this runs")
    ap.add_argument("--wizard-port", default="3000", help="setup wizard port")
    args = ap.parse_args()

    env = load_env()

    dns_port = int(env.get("ADGUARD_DNS_PORT", "53"))
    web_port = int(env.get("ADGUARD_WEB_PORT", "80"))
    user = env.get("ADGUARD_ADMIN_USER", "admin")
    password = env.get("ADGUARD_ADMIN_PASSWORD", "")
    upstreams = [u for u in (env.get("ADGUARD_UPSTREAM_1"), env.get("ADGUARD_UPSTREAM_2")) if u]
    bootstrap = ["9.9.9.9", "1.1.1.1"]

    if not password:
        print("ADGUARD_ADMIN_PASSWORD is empty in .env - refusing to create an", file=sys.stderr)
        print("AdGuard instance without an admin password.", file=sys.stderr)
        return 2

    wizard = f"http://{args.host}:{args.wizard_port}"
    final = f"http://{args.host}:{web_port}"

    # ---------------------------------------------------------------- wizard ---
    print(f"1/4  waiting for the AdGuard setup wizard on {wizard}")
    if not wait_for(f"{wizard}/", "setup wizard"):
        return 1

    # Already installed? Then skip straight to the settings step.
    already = False
    try:
        status, body, _ = http("GET", f"{final}/control/status", timeout=5)
        already = status == 200 and '"running"' in body
    except Exception:
        pass

    if not already:
        print(f"2/4  installing: DNS :{dns_port}, web UI :{web_port}, user '{user}'")
        payload = {
            "web": {"ip": "0.0.0.0", "port": web_port, "status": ""},
            "dns": {"ip": "0.0.0.0", "port": dns_port, "status": ""},
            "username": user,
            "password": password,
        }
        try:
            status, body, _ = http("POST", f"{wizard}/control/install/configure", payload, timeout=30)
            print(f"     -> HTTP {status} {body[:200]}")
            if status != 200:
                return 1
        except urllib.error.HTTPError as e:
            print(f"     -> HTTP {e.code} {e.read().decode(errors='replace')[:400]}", file=sys.stderr)
            return 1
        print(f"3/4  waiting for AdGuard to come back up on {final}")
        if not wait_for(f"{final}/", "AdGuard web UI"):
            return 1
    else:
        print("2/4  AdGuard already installed - skipping the wizard")
        print("3/4  AdGuard web UI already answering")

    # --------------------------------------------------------------- settings ---
    print("4/4  applying DNS settings (upstreams, bootstrap, rate limit)")
    cookie = None
    for _ in range(30):
        try:
            status, body, cookies = http(
                "POST", f"{final}/control/login", {"name": user, "password": password}, timeout=10
            )
            if status == 200:
                for c in cookies:
                    if c.startswith("agh_session="):
                        cookie = c.split(";", 1)[0]
                break
        except Exception:
            pass
        time.sleep(1)

    if not cookie:
        print("  ! could not log in to the AdGuard API", file=sys.stderr)
        return 1

    current = {}
    try:
        _, body, _ = http("GET", f"{final}/control/dns_info", cookie=cookie, timeout=10)
        current = json.loads(body)
    except Exception:
        pass

    dns_cfg = {
        "upstream_dns": upstreams or ["https://dns.quad9.net/dns-query"],
        "upstream_dns_file": "",
        "bootstrap_dns": bootstrap,
        # Do not answer for private ranges unless explicitly allowed -> keeps
        # AdGuard from being abused as a rebinding helper.
        "resolve_clients": True,
        # Modest rate limit; tailnet traffic is tiny but this stops any runaway.
        "ratelimit": 0,
        "ratelimit_subnet_len_ipv4": 24,
        "ratelimit_subnet_len_ipv6": 56,
        "ratelimit_whitelist": [],
        "refuse_any": True,
        "edns_cs_enabled": False,
        "dnssec_enabled": False,
        "cache_size": 4194304,
        "cache_ttl_min": 60,
        "cache_ttl_max": 86400,
        "blocking_mode": current.get("blocking_mode", "default"),
        "blocked_response_ttl": current.get("blocked_response_ttl", 10),
        "blocking_ipv4": current.get("blocking_ipv4", ""),
        "blocking_ipv6": current.get("blocking_ipv6", ""),
        "protected_enabled": False,
        "blocked_services": current.get("blocked_services", []),
        "local_ptr_upstreams": [],
        "use_private_ptr_resolvers": False,
    }

    try:
        status, body, _ = http("POST", f"{final}/control/dns_config", dns_cfg, cookie=cookie, timeout=15)
        print(f"     -> HTTP {status} {body[:200]}")
    except urllib.error.HTTPError as e:
        print(f"     -> HTTP {e.code} {e.read().decode(errors='replace')[:300]}", file=sys.stderr)
        return 1

    # Log out; the session cookie is not needed again.
    try:
        http("POST", f"{final}/control/logout", {}, cookie=cookie, timeout=5)
    except Exception:
        pass

    print("\nAdGuard Home is configured.")
    print(f"  DNS  : <tailscale-ip>:{dns_port}")
    print(f"  Admin: http://<tailscale-ip>:{web_port}/   (user: {user})")
    return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

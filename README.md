# AdGuard Home + Tailscale on a single VPS

A DNS server that lives **only on your tailnet**, with Tailscale fully confined
to a Docker network. The VPS host keeps its ordinary network stack — no
`tailscale0`, no `100.x` address, no DNS listener.

```
  host  <host-ip>                <- no tailscale0, no 100.x, no :53
    │
    │  docker bridge "adguard"  <bridge-subnet>
    ▼
  ┌──────────────────────────────────────────────────┐
  │  tailscale container netns                        │
  │    eth0        <bridge-ip>                        │
  │    tailscale0  100.x.y.z      <- the tailnet IP   │
  │      │                                            │
  │      └── AdGuard Home (shares this netns)         │
  │             :53/udp  :53/tcp  :80/tcp             │
  └──────────────────────────────────────────────────┘

  published to the host: 41641/udp only  (the WireGuard tunnel)
```

---

## Layout

```
adguard-tailscale/
├── docker-compose.yml      # two services, one shared network, three volumes
├── .env                    # secrets/settings, chmod 600, git-ignored
├── .env.example            # template
├── .gitignore
├── README.md
└── scripts/
    ├── bootstrap.sh        # unattended bring-up (uses TS_AUTHKEY)
    ├── firewall.sh         # host ufw policy + DOCKER-USER guard
    ├── setup-adguard.py    # seeds AdGuard's config through its install API
    ├── apply-overrides.py  # merges adguard/overrides.yaml into AdGuardHome.yaml
    └── verify.sh           # 30 health checks

adguard/
└── overrides.yaml          # YOUR partial AdGuardHome.yaml (upstream_dns, etc.)
```

## Overriding AdGuard's config (`adguard/overrides.yaml`)

AdGuard Home owns `AdGuardHome.yaml` and rewrites it whenever you change a
setting in the UI, so editing that file by hand is a losing battle. Instead put
only the keys you care about into `adguard/overrides.yaml` and merge them in:

```bash
sudo ./scripts/apply-overrides.py --dry-run    # preview
sudo ./scripts/apply-overrides.py               # apply + restart AdGuard
```

Merge semantics — worth knowing before you rely on it:

| YAML shape | Behaviour |
|---|---|
| mapping | merged recursively, so you can override a single leaf |
| scalar | replaced |
| **list** | **replaced wholesale — never appended** |
| `schema_version` | never taken from the override file |

That list rule matters most for the thing you actually want to set:

```yaml
dns:
  upstream_dns:
    - https://dns.quad9.net/dns-query
  bootstrap_dns:
    - 9.9.9.9
    - 1.1.1.1
```

If you list one upstream you get one upstream — the previous entries are gone,
not appended to.

The script stops AdGuard first (so it cannot rewrite the file underneath the
merge), saves a timestamped `AdGuardHome.yaml.bak-*` next to it (last 5 kept),
writes atomically at mode `0600`, then starts AdGuard again.

`bootstrap.sh` runs it automatically at the end of a fresh install, so a
committed `overrides.yaml` is part of your reproducible setup.

## Why it is built this way

**Tailscale never touches the host.**
`tailscale` runs on a user-defined bridge network (`adguard`) and creates
`tailscale0` inside its own namespace. The host has no route to `100.x.y.z` and
no tailscale interface — verified by `verify.sh`.

**AdGuard joins that namespace.**
`network_mode: "service:tailscale"` puts AdGuard inside the same namespace, so
its `:53` listener is served directly on the Tailscale IP. It also means AdGuard
inherits the `adguard` Docker network through the tailscale container (a
container cannot declare both `network_mode` and `networks`).

**Kernel networking.**
`TS_USERSPACE=false` + `/dev/net/tun` + `NET_ADMIN`/`NET_RAW` gives a real
`tailscale0` interface that AdGuard can bind to. Userspace mode would keep the
`100.x` address inside a userspace stack where AdGuard could not reach it.

**The WireGuard port is pinned on purpose.**
`TS_TAILSCALED_EXTRA_ARGS: --port=41641` (a *daemon* flag) is what makes
`ports: 41641:41641/udp` deterministic. Left alone, tailscaled picks a random
port that a static mapping cannot follow — this is why it must not go in
`TS_EXTRA_ARGS`, which is passed to `tailscale up` (which has no `--port` flag).

**Only one port is published, and it is not DNS.**
`41641/udp` lets peers reach the tunnel directly instead of falling back to a
DERP relay. Port 53 is never published, so AdGuard is structurally incapable of
being a public resolver — there is nothing to firewall off.

**Auth key, not a browser.**
`TS_AUTHKEY` drives an unattended first boot. Afterwards the node identity lives
in the `tailscale-state` volume and `TS_AUTH_ONCE=true` means it is never
consulted again.

**Host DNS is deliberately independent.**
`/etc/resolv.conf` points at `9.9.9.9`/`1.1.1.1`. A broken AdGuard can never
break the VPS's ability to resolve names and pull images.

---

## First-time setup

```bash
cd adguard-tailscale

# 1. secrets  (TS_AUTHKEY is the only thing you must fill in)
cp .env.example .env && chmod 600 .env
$EDITOR .env

# 2. everything else, unattended
sudo ./scripts/bootstrap.sh
```

`bootstrap.sh runs the helper Python in a throwaway container, so the host needs no python3/PyYAML; it also runs every step even if one fails and exits non-zero if any did.`

`bootstrap.sh` applies the firewall, brings the stack up, waits for Tailscale,
seeds AdGuard through its install API (inside the container namespace), and runs
the verifier.

### Getting an auth key

`login.tailscale.com/admin/settings/keys` → *Generate auth key*:

- **Reusable**: yes (so the same key can rebuild this node)
- **Ephemeral**: no
- **Tags**: optional, e.g. `tag:dns`
- **Expiry**: whatever suits you — it is only read on first boot

---

## Making the tailnet actually use it

Tailscale admin console → **DNS**:

1. **Nameservers** → *Add nameserver* → **Custom** → `100.x.y.z`
   (or the MagicDNS name `adguard-dns-1`).
2. Enable **Override local DNS** to make it exclusive.
3. Leave MagicDNS on if you still want `*.ts.net` names — AdGuard forwards them
   upstream like any other name.

Verify from another device on the tailnet (this is the one test the VPS itself
cannot perform, because it is intentionally not on the tailnet):

```bash
dig @100.x.y.z example.com        # UDP
dig +tcp @100.x.y.z example.com   # TCP
```

## Reaching other private networks (subnet routes)

`TS_EXTRA_ARGS` includes `--accept-routes=true`. Without it the container
ignores every subnet route your tailnet advertises and sends private traffic out
the Docker default gateway instead — where it dies.

This is easy to misread as "the network is down". A traceroute from the
container to a subnet-router-backed address looks like:

```
 1  <bridge-gw>    # docker bridge
 2  10.0.2.1       # the VPS default gateway  <- wrong way
 3  * * *
```

With routes accepted, the same traceroute goes through the subnet router:

```
 1  100.x.y.z        # a tailnet node advertising your private subnet
 2  <private-gateway>
 ...
 7  <private-host>
```

Two things to keep in mind:

- **The route that matches may be much broader than the address you tested.**
  A subnet router advertises a whole CIDR (e.g. `10.0.0.0/8`), not a single
  host, so accepting a route can send *all* traffic for that range through that
  node. Check what is actually advertised with `tailscale status --json` before
  you rely on it.
- **Check it from the container, not the host.** The host is not on the tailnet,
  so `ip route` there tells you nothing about what the container can reach:

  ```bash
  docker exec adguardhome ip route get <private-ip>
  # -> <private-ip> dev tailscale0  src 100.x.y.z
  ```

## Admin UI

```
http://100.x.y.z/          (or http://<hostname>.<tailnet>.ts.net/)
user: admin
```

Reachable only over Tailscale. Nothing is published for it, so there is no
public listener to firewall.

## Firewall policy (host)

`scripts/firewall.sh` is **additive-only**: it never runs `ufw reset`, never
changes your default policies or logging level, and never removes a rule it did
not add. It only appends the rules below, so any existing host rules are kept.

```
ALLOW IN   lo
ALLOW IN   22/tcp        # SSH admin
ALLOW IN   <TS_WG_PORT>/udp   # WireGuard tunnel (encrypted, not DNS)
DENY  IN   53/udp        # explicit: nothing DNS-shaped on the host
DENY  IN   53/tcp

DOCKER-USER (forwarded traffic, which ufw cannot see):
DROP  -i <public-if> -p udp/tcp --dport 53   # tagged adguard-tailscale:dns-guard
```

If the host already runs Tailscale it usually owns `41641/udp` already. The
script then stops and asks you to set a free `TS_WG_PORT` in `.env` (it never
edits `.env` for you). Set it, then re-run.

The `DOCKER-USER` rule is scoped to the **public interface** on purpose. A
blanket `--dport 53 -j DROP` also kills the container's own egress to upstream
resolvers, which silently prevents AdGuard from resolving its DoH upstreams and
binding `:53` — a failure mode that looks like "AdGuard is up but DNS is dead".

## Operations

```bash
docker compose ps
docker compose logs -f tailscale
docker compose logs -f adguard
./scripts/verify.sh                  # 30 checks
docker exec tailscale tailscale status

# AdGuard lives in another namespace, so reach it with nsenter:
P=$(docker inspect -f '{{.State.Pid}}' tailscale)
nsenter -t "$P" -n -- dig @100.x.y.z example.com
```

**Upgrading images:** `docker compose pull && docker compose up -d` — volumes
are untouched.

**Rotating the Tailscale node:** `docker compose down`, back up the volume, then
`docker volume rm adguard-tailscale_tailscale-state`, set a fresh `TS_AUTHKEY`,
`docker compose up -d`. The node gets a new `100.x` address, so update the
tailnet nameserver. Note that a **reusable** key can be replayed; a single-use
key cannot, so keep that in mind if you plan to rebuild often.

## Exit node

This node advertises itself as an exit node (`--advertise-exit-node` in
`TS_EXTRA_ARGS`). To actually use it:

1. It forwards and NATs traffic itself: `docker-compose.yml` sets
   `net.ipv4.ip_forward` / `net.ipv6.conf.all.forwarding` and `--netfilter-mode=on`.
2. Approve it once in the Tailscale admin console: **Machines → this node →
   Edit route settings → Use as exit node**.
3. On a client: `tailscale set --exit-node=adguard-trial` (or pick it in the
   Tailscale app).

Remove `--advertise-exit-node` from `TS_EXTRA_ARGS` and recreate the container to
turn it off again.

## Not done on purpose

- **Advertises no subnet routes.** It *accepts* them (`--accept-routes=true`)
  but does not offer any of its own.
- **No published DNS port.** Only `41641/udp` is published.
- **No Tailscale SSH.** `--ssh=false`.
- **Nothing Tailscale-shaped on the host.** No `tailscale0`, no `100.x`.

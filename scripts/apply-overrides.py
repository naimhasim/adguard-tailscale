#!/usr/bin/env python3
"""
apply-overrides.py - merge adguard/overrides.yaml into the live AdGuardHome.yaml.

AdGuard Home owns its config file and rewrites it whenever a setting changes in
the UI, so the safe way to impose your own values is to edit the file while
AdGuard is stopped, then start it again. That is what this script does:

    1. stop the adguard container
    2. back up the current AdGuardHome.yaml (timestamped, next to it)
    3. deep-merge overrides.yaml into it
    4. write it back atomically, keeping mode 0600
    5. start the container again

Merge semantics
---------------
    mapping -> merged recursively
    scalar  -> replaced
    list    -> REPLACED wholesale (never appended)
    schema_version is never taken from the override file

Usage
-----
    sudo ./scripts/apply-overrides.py                  # apply adguard/overrides.yaml
    sudo ./scripts/apply-overrides.py --dry-run        # show what would change
    sudo ./scripts/apply-overrides.py --file other.yaml
    sudo ./scripts/apply-overrides.py --no-restart
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: apt-get install -y python3-yaml")

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
VOLUME = "adguard-tailscale_adguard-conf"
CONFIG_NAME = "AdGuardHome.yaml"

# Keys we refuse to take from the override file.
PROTECTED = {"schema_version"}

# How many timestamped backups to keep alongside AdGuardHome.yaml.
KEEP_BACKUPS = 5


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def run(cmd: list[str], check: bool = True, capture: bool = False) -> str:
    res = subprocess.run(
        cmd, cwd=PROJECT, check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    if check and res.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{(res.stderr or '').strip()}")
    return (res.stdout or "").strip()


def config_path() -> Path:
    """Resolve the real file inside the Docker volume."""
    mp = run(["docker", "volume", "inspect", "-f", "{{.Mountpoint}}", VOLUME], capture=True)
    if not mp:
        sys.exit(f"could not locate volume {VOLUME}")
    p = Path(mp) / CONFIG_NAME
    if not p.exists():
        sys.exit(
            f"{p} does not exist.\n"
            "AdGuard has not been installed yet - run ./scripts/bootstrap.sh first."
        )
    return p


def deep_merge(base: dict, over: dict, path: str = "") -> list[str]:
    """Merge `over` into `base` in place. Returns the list of changed paths."""
    changed: list[str] = []
    for key, val in over.items():
        here = f"{path}.{key}" if path else str(key)
        if here.split(".")[0] in PROTECTED:
            changed.append(f"{here} (ignored - protected)")
            continue
        if isinstance(val, dict) and isinstance(base.get(key), dict):
            changed += deep_merge(base[key], val, here)
        else:
            if base.get(key) != val:
                base[key] = copy.deepcopy(val)
                changed.append(here)
    return changed


def summarise(val, limit: int = 90) -> str:
    s = json.dumps(val, ensure_ascii=False) if not isinstance(val, str) else val
    return s if len(s) <= limit else s[: limit - 3] + "..."


def dig_path(data: dict, dotted: str):
    cur = data
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=str(PROJECT / "adguard" / "overrides.yaml"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-restart", action="store_true")
    ap.add_argument("--config-dir", default=None,
                    help="directory holding AdGuardHome.yaml (default: resolve the docker volume)")
    args = ap.parse_args()

    ov_path = Path(args.file)
    if not ov_path.is_absolute():
        ov_path = (Path.cwd() / ov_path).resolve()
    if not ov_path.exists():
        sys.exit(f"override file not found: {ov_path}")

    try:
        overrides = yaml.safe_load(ov_path.read_text()) or {}
    except yaml.YAMLError as e:
        sys.exit(f"invalid YAML in {ov_path}:\n{e}")
    if not isinstance(overrides, dict):
        sys.exit("the override file must contain a YAML mapping at the top level")

    if args.config_dir:
        cfg_file = Path(args.config_dir) / CONFIG_NAME
        if not cfg_file.exists():
            sys.exit(f"{cfg_file} does not exist")
    else:
        cfg_file = config_path()
    try:
        current = yaml.safe_load(cfg_file.read_text()) or {}
    except yaml.YAMLError as e:
        sys.exit(f"existing {cfg_file} is not valid YAML:\n{e}")
    if not isinstance(current, dict):
        sys.exit(f"unexpected structure in {cfg_file}")

    merged = copy.deepcopy(current)
    changed = deep_merge(merged, overrides)

    print(f"override file : {ov_path}")
    print(f"target config : {cfg_file}")
    print()

    if not changed:
        print("Nothing to do - the live config already matches the overrides.")
        return 0

    print(f"{len(changed)} change(s):")
    for path in changed:
        if "(ignored" in path:
            print(f"  ! {path}")
        else:
            print(f"  ~ {path} = {summarise(dig_path(merged, path))}")
    print()

    if args.dry_run:
        print("--dry-run: nothing written, container untouched.")
        return 0

    # --- stop AdGuard so it cannot rewrite the file under us -----------------
    if not args.no_restart:
        print("stopping adguard ...")
        run(["docker", "compose", "stop", "adguard"])

    # --- back up -------------------------------------------------------------
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = cfg_file.with_name(f"{CONFIG_NAME}.bak-{stamp}")
    shutil.copy2(cfg_file, backup)
    print(f"backup        : {backup.name}")

    # keep only the most recent backups so the volume does not grow forever
    old = sorted(cfg_file.parent.glob(f"{CONFIG_NAME}.bak-*"))
    for stale in old[:-KEEP_BACKUPS]:
        try:
            stale.unlink()
        except OSError:
            pass

    # --- write atomically, preserving 0600 ----------------------------------
    st = cfg_file.stat()
    fd, tmp = tempfile.mkstemp(dir=str(cfg_file.parent), prefix=".AdGuardHome.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            yaml.safe_dump(merged, fh, sort_keys=False, default_flow_style=False, width=4096)
        os.chmod(tmp, st.st_mode & 0o777)
        os.replace(tmp, cfg_file)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("config written")

    # --- restart -------------------------------------------------------------
    if not args.no_restart:
        print("starting adguard ...")
        run(["docker", "compose", "start", "adguard"])
        print("done.")
    else:
        print("done (container left stopped - start it yourself).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

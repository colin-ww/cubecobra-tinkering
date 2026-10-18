"""
Snapshot my CubeCobra cubes to Parquet.

Reads config/cubes.toml, pulls each cube from CubeCobra's cubejson API (in
parallel: it's network-bound, so a few threads are enough) and writes two
tidy tables to processed/:
  - my_cubes.parquet        one row per cube
  - my_cubes_cards.parquet  one row per card per board (mainboard / maybeboard)

`card_key` identifies a card across printings (oracle id, or the lower-cased
name for custom cards), so the README's report ideas (overlap, dupes) are a
group-by on it.

Private cubes can't be fetched: the API has no login.
"""

import argparse
import json
import time
import tomllib
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

API = "https://cubecobra.com/cube/api/cubejson/{}"
HEADERS = {"User-Agent": "cubecobra-tinkering (github.com/colin-ww/cubecobra-tinkering)"}
BOARDS = ("mainboard", "maybeboard")  # the API also returns "basics"; not part of the cube
RETRY_CODES = {429, 500, 502, 503, 504}


def load_config(path):
    with open(path, "rb") as f:
        cubes = tomllib.load(f).get("cube", [])
    if not cubes:
        raise SystemExit(f"no [[cube]] entries in {path}")
    return cubes


def fetch_cube(cube_id, retries=4):
    """GET one cube as parsed JSON, backing off on rate limits (429) and 5xx."""
    req = urllib.request.Request(API.format(cube_id), headers=HEADERS)
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise ValueError(f"cube {cube_id!r} not found (typo, or private?)") from e
            if e.code not in RETRY_CODES or attempt == retries - 1:
                raise
            retry_after = e.headers.get("Retry-After", "")
            wait = int(retry_after) if retry_after.isdigit() else 2**attempt
        except urllib.error.URLError:
            if attempt == retries - 1:
                raise
            wait = 2**attempt
        time.sleep(wait)


def card_row(cube_id, board, c):
    d = c.get("details") or {}
    name = d.get("name") or c["name"]
    oracle_id = d.get("oracle_id")
    return {
        "cube_id": cube_id,
        "board": board,
        # custom cards have no (real) oracle id, so fall back to the name
        "card_key": oracle_id if oracle_id and oracle_id != "custom-card" else name.lower(),
        "name": name,
        "oracle_id": oracle_id,
        "scryfall_id": c.get("cardID"),
        "set": d.get("set"),
        "collector_number": d.get("collector_number"),
        "type_line": c.get("type_line") or d.get("type"),
        "cmc": d.get("cmc"),
        "colors": c.get("colors") or d.get("colors") or [],
        "status": c.get("status"),
        "finish": c.get("finish"),
        "tags": c.get("tags") or [],
        "notes": c.get("notes") or "",
        "added": c.get("addedTmsp"),
    }


def card_rows(cube):
    return [card_row(cube["id"], board, c) for board in BOARDS for c in cube["cards"].get(board, [])]


def cube_row(cube, cfg):
    return {
        "cube_id": cube["id"],
        "short_id": cube.get("shortId"),
        "label": cfg.get("name") or cube["name"],
        "cube_name": cube["name"],
        "owner": (cube.get("owner") or {}).get("username"),
        "uniques": bool(cfg.get("uniques", False)),
        "card_count": cube.get("cardCount"),
        "n_main": len(cube["cards"].get("mainboard", [])),
        "n_maybe": len(cube["cards"].get("maybeboard", [])),
        "date_last_updated": cube.get("dateLastUpdated"),
    }


def main(config, out):
    cfg = load_config(config)
    with ThreadPoolExecutor(max_workers=4) as pool:
        cubes = list(pool.map(fetch_cube, (c["id"] for c in cfg)))
    snapshot = datetime.now(timezone.utc)

    cubes_df = pd.DataFrame([cube_row(cu, c) for cu, c in zip(cubes, cfg)]).assign(
        date_last_updated=lambda d: pd.to_datetime(d["date_last_updated"], unit="ms", utc=True),
        snapshot_utc=snapshot,
    )
    cards_df = pd.DataFrame([r for cu in cubes for r in card_rows(cu)]).assign(
        added=lambda d: pd.to_datetime(d["added"], utc=True, errors="coerce"),
        snapshot_utc=snapshot,
    )

    out.mkdir(parents=True, exist_ok=True)
    cubes_df.to_parquet(out / "my_cubes.parquet", index=False)
    cards_df.to_parquet(out / "my_cubes_cards.parquet", index=False)

    # same kind of check as convert_to_parquet.py: our mainboard rows vs the cube's own cardCount
    for r in cubes_df.itertuples():
        status = "OK" if r.n_main == r.card_count else "MISMATCH"
        print(f"{r.label[:36]:36s} main={r.n_main:>4d} maybe={r.n_maybe:>4d} [{status}]")
    print(f"-> {out}/ : {len(cubes_df)} cubes, {len(cards_df)} card rows")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--config", type=Path, default=Path("config/cubes.toml"))
    ap.add_argument("--out", type=Path, default=Path("processed"))
    args = ap.parse_args()
    main(args.config, args.out)

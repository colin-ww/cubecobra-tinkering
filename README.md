# cubecobra-tinkering

Python tinkering with CubeCobra data. Two pipelines, same idea (fetch -> tidy -> Parquet):

| | what | script | workflow |
|---|---|---|---|
| global | CubeCobra's public JSON export -> Parquet (manual for now, quarterly cron prepared) | `scripts/convert_to_parquet.py` | `cubecobra-sync.yml` |
| mine | my own cubes -> `my_cubes` + `my_cubes_cards` Parquet | `scripts/fetch_cubes.py` | `my-cubes.yml` |

## My cubes
- Cubes to snapshot live in `config/cubes.toml` (two public example cubes for now, replace them with yours).
- Public and unlisted cubes only: the API has no login for private ones.
- Cards are keyed by `card_key` (oracle id, or lower-cased name for custom cards), one row per card per board (mainboard / maybeboard).
- The fetches run in parallel (threads: it's all waiting on the network).
- `my-cubes.yml` runs on demand and on PRs that touch the fetcher. The weekly cron (Mon + Wed 16:00, Sat 08:00 MT, converted to UTC) is in the file, commented out until the manual runs look right.

## Run locally
```sh
python -m venv .venv && source .venv/bin/activate     # or: uv venv
pip install -r requirements-dev.txt
pytest -q                                              # offline tests
python scripts/fetch_cubes.py                          # -> processed/*.parquet
```

---

## Notes / report ideas (original README)

### overlap between (my) cubes
- Just this? Card name in a cube but not in "uniques"
- Weekly reports: Mon 4p, Wed 4p, Sat 8a - MT Edmonton Canada

### check dupes
- Same weekly sched as above
- all: in both mb/main, or >1 copy mb
- uniques addt rule: across all >1 copy

# Implementation ideas

Detail behind [roadmap.md](roadmap.md). All proposals unless marked *measured* or *verified*.
Decision numbers (D1, D2, ...) refer to the roadmap's "Decisions to make".

## 1. Repo layout
```
config/cubes.toml        which cubes to snapshot
scripts/                 thin CLIs, one per job
  convert_to_parquet.py  global export -> Parquet
  fetch_cubes.py         my cubes -> Parquet
  report_*.py            next: dupes, overlap
tests/                   offline; real-response fixtures in tests/fixtures/
docs/
.github/workflows/       one workflow per job, plus CI
```
Stay flat. When a third script needs shared code (API client, `card_key`), extract `src/cubetools/`
and `pip install -e .`. Not before.

## 2. Order of work (one PR each)
| # | PR | done when |
|---|---|---|
| M0 | merge #4 and #5; sync workflow installs `requirements.txt` | Dependabot pip job green |
| M1 | reports as pure functions over `my_cubes_cards` + Markdown renderer | each README rule has a test on a hand-made example |
| M2 | delivery (D4): job summary, issue with @mention, maybe ntfy; only when there are findings | a deliberately dirty cube produces a notification |
| M3 | schedule on, `concurrency` group | one scheduled run observed |
| M4 | week-over-week diff via `?date=` (D5) | "added/removed since last week" section |
| M5 | global track: change detection, typed index columns, convert `cards/indexToOracle.json`, a decode helper (cube card -> oracle id -> name) | one real question answered from it |
| M6 | polish: uv, ruff, pandera | when it hurts |

## 3. Formats
- **Tables: Parquet.** Use zstd. *Measured* on the real files vs the snappy default: `carddict` -39%,
  `cubes` -18%, `metadatadict` -7% (level 3, 1 to 8 s to write). Sorting each cube's card list shaves
  ~5% more off `cubes`.
- **int32 vs int64 changes nothing on disk** (*measured*: identical size, Parquet encodes by value).
  Memory is where types matter: pandas holds the 68M card slots as Python ints, which is probably most of
  its 4.7 GB peak (not tested).
- Timestamps in UTC. Low-cardinality text (`board`, `status`, `finish`) as categorical in memory.
  List columns (`tags`, `colors`) are fine in Parquet; just never mix element types in one
  (that was the #4 crash).
- **Config: TOML** (stdlib `tomllib`, comments allowed). Not YAML, not JSON.
- **Fixtures: small trimmed JSON** copied from a real response. **Reports: Markdown** (renders in job
  summaries, issues and Pages).
- If snapshots are ever stored: Hive folders `snapshot_date=2026-10-19/`, queried with DuckDB.

## 4. Libraries
| need | now | maybe later | why |
|---|---|---|---|
| HTTP | `urllib` | `httpx` | 100 req/min is tiny; httpx only for async or HTTP/2 |
| frames | pandas 3 | Polars, Ibis | Polars/Ibis read closer to dplyr; Ibis also speaks Oracle and MSSQL |
| SQL on files | | DuckDB | `SELECT ... FROM 'x.parquet'`; reads JSON and remote Parquet. *Measured* on `cubes.json` (sandbox timings, the ratio is what counts): 25 s vs 88 s for pandas, peak RAM 3.7 vs 4.7 GB. Its auto-typing chose `DOUBLE[]` for the card indices and `JSON[]` for `following` (the ObjectID again), so it needs explicit `columns=` |
| validation | row-count parity | pandera | schema asserts, the `pointblank` of Python |
| reports | Markdown strings | great_tables, plotnine, Quarto | gt, ggplot2 and Quarto equivalents |
| tests | pytest | | |
| lint/format | | ruff | lintr + styler |
| env | pip + venv | uv | fast, lockfile |

## 5. Report sketches
Written for the README's rules taken literally (D1-D3), with "uniques" = the cube flagged
`uniques = true` in `config/cubes.toml`. *Verified* on a hand-made 3-cube example with DuckDB 1.5.6.
```sql
-- dupes: same card on main and maybe of one cube, or >1 copy on the maybeboard
SELECT cube_id, card_key, any_value(name) AS name,
       count(*) FILTER (WHERE board = 'mainboard')  AS n_main,
       count(*) FILTER (WHERE board = 'maybeboard') AS n_maybe
FROM 'processed/my_cubes_cards.parquet'
GROUP BY cube_id, card_key
HAVING (n_main > 0 AND n_maybe > 0) OR n_maybe > 1;

-- overlap: on a mainboard of a normal cube but not on the uniques mainboard
WITH cards AS (
  SELECT c.*, m.label, m.uniques
  FROM 'processed/my_cubes_cards.parquet' c
  JOIN 'processed/my_cubes.parquet' m USING (cube_id)
  WHERE c.board = 'mainboard'
)
SELECT card_key, any_value(name) AS name, list(DISTINCT label ORDER BY label) AS in_cubes
FROM cards
WHERE NOT uniques AND card_key NOT IN (SELECT card_key FROM cards WHERE uniques)
GROUP BY card_key;
```
The "uniques, across all >1 copy" rule is the same `GROUP BY card_key HAVING count(*) > 1`, just
over all cubes and boards instead of one. Which of the two it is depends on D1.

## 6. Workflow notes
- **Time zone:** the cron lines in `my-cubes.yml` are 22:00 UTC (Mon/Wed) and 14:00 UTC (Sat) = 16:00
  and 08:00 at UTC-6. tzdata 2026c has Alberta staying on UTC-6 from 2026-11-01, so they stay right
  all year. If clocks did keep changing, schedule both UTC hours and gate on
  `TZ=America/Edmonton date +%u%H` printing `116`, `316` or `608` (weekday + hour).
- `concurrency: {group: my-cubes}` so a slow run can't overlap the next.
- `permissions: {contents: read}`, plus `issues: write` only on the job that posts.
- **Change detection for the global export:** `curl -sI` the file, compare `ETag` or `Last-Modified`
  with the last processed one (kept in `actions/cache`), skip when equal. Upstream rebuilds ~every 90 days.
- Already done in #5: `pipefail`, `if-no-files-found: error`. Keep it that way: the quiet failure is
  the dangerous one.
- The 60-day auto-disable of scheduled workflows: check the Actions tab after ~50 days of quiet.

## 7. Data-quality checks
- Have: source rows == Parquet rows; mainboard rows == the cube's own `cardCount`.
- Add: no null `card_key` or `name`; `board` in the known set; count of `-1` card slots in the global
  track (0.08% today) so a jump is noticed; pandera schemas on both personal tables.
- **Canary:** record a real `cubejson` response as a fixture, and run a weekly workflow that fetches one
  small cube and asserts the same keys. If the API shape changes you hear about it first.

## 8. Where to borrow from
Your fork `colin-ww/fork--cubecobra` (I read `4114b92`, 2026-09-26; upstream is `dekkerglen/CubeCobra`):
- `packages/jobs/src/export_cubes.ts`: how `cubes.json` is built (public only, mainboard only, `|| -1`).
- `packages/server/src/router/routes/cube/api/cubeJSON.ts`: rate limit (100/min) and `?date=`.
- `packages/cardUpdateMonitorLambda/src/exportTasks.ts`: the 90-day export rule.
- `packages/server/src/serverutils/cubefn.ts`, `isCubeViewable`: public and unlisted are readable, private is not.
- `packages/docs/maintenance/analytics.md`: overview of the exports.

Other sources, only if needed: Scryfall bulk data and MTGJSON for card text or prices without CubeCobra.
Your own repos: `mtg-search` (I haven't looked at it; possible overlap on card identity), and
`cubecobra-card-rank` / `cubecobra-top-cubes`, which are empty shells.

## 9. Tidyverse -> Python cheat sheet
All *verified* on pandas 3.0.6 and Polars 2.0.0. `|>` is method chaining, or `.pipe(f)` for your own functions.

| dplyr | pandas | Polars |
|---|---|---|
| `filter(x > 1)` | `df.query("x > 1")` | `df.filter(pl.col("x") > 1)` |
| `mutate(y = x * 2)` | `df.assign(y=lambda d: d.x * 2)` | `df.with_columns(y=pl.col("x") * 2)` |
| `group_by(a) \|> summarise(n = n())` | `df.groupby("a").size().reset_index(name="n")` | `df.group_by("a").agg(n=pl.len())` |
| `left_join(b, by = "k")` | `df.merge(b, on="k", how="left")` | `df.join(b, on="k", how="left")` |
| `arrange(desc(x))` | `df.sort_values("x", ascending=False)` | `df.sort("x", descending=True)` |
| `distinct(a, b)` | `df.drop_duplicates(["a", "b"])` | `df.unique(["a", "b"])` |

## 10. Links
Returned HTTP 200 from the cloud sandbox this was written in, on 2026-10-18:
- DuckDB: [JSON](https://duckdb.org/docs/stable/data/json/overview.html),
  [Parquet](https://duckdb.org/docs/stable/data/parquet/overview.html),
  [httpfs (remote files)](https://duckdb.org/docs/stable/core_extensions/httpfs/overview.html)
- [Ibis](https://ibis-project.org/), [Polars](https://docs.pola.rs/),
  [plotnine](https://plotnine.org/), [great_tables](https://posit-dev.github.io/great-tables/)
- [Quarto on GitHub Pages](https://quarto.org/docs/publishing/github-pages.html)
- GitHub Actions: [events incl. schedule](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
  [job summaries](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary)
- [ntfy publish API](https://docs.ntfy.sh/publish/) (push to your phone), [uv](https://docs.astral.sh/uv/),
  [ruff](https://docs.astral.sh/ruff/), [MTGJSON](https://mtgjson.com/), [CubeCobra](https://cubecobra.com/)

GitHub and Scryfall web pages returned 403 from that sandbox's proxy, so these are from memory, not
checked: <https://github.com/dekkerglen/CubeCobra>, <https://scryfall.com/docs/api/bulk-data>,
<https://github.com/mtgjson/mtgjson>.

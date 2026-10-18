# Implementation ideas

Detail behind [roadmap.md](roadmap.md). All proposals unless marked *measured* or *verified*.
Decision numbers (D1, D2, ...) refer to the roadmap's "Decisions to make".

## 1. Repo layout
```
DESCRIPTION              R dependencies (not a package; pak and setup-r-dependencies read it)
config/cubes.yml         which cubes to snapshot (to build; YAML allows comments, CSV doesn't)
scripts/                 one script per job, run with Rscript
  convert_to_parquet.R   global export -> Parquet
  compare_parquet.R      parity check, temporary (deleted with the Python side)
  download_raw.sh
  fetch_cubes.R          next: my cubes -> Parquet
  report_*.R             next: dupes, overlap
tests/testthat/          offline; real-response fixtures in tests/testthat/fixtures/
docs/
.github/workflows/       one workflow per job
```
Stay as scripts. When a third script needs shared code (API client, `card_key`), move the functions to
`R/` and promote the repo to a package (`DESCRIPTION` is already there). Not before.

## 2. Order of work (one PR each)
| # | PR | done when |
|---|---|---|
| M0 | merge #4 and #7; parallel runs green; delete the Python side | `compare` green 3 times, once after the next export |
| M1 | fetch my cubes (httr2) into `my_cubes` and `my_cubes_cards` | live run on 2 public cubes; mainboard rows == the cube's `cardCount` |
| M2 | reports as pure functions + a Markdown renderer | each README rule has a test on a hand-made example |
| M3 | delivery (D4): job summary, issue with @mention, maybe ntfy; only when there are findings | a deliberately dirty cube produces a notification |
| M4 | schedule on, `concurrency` group | one scheduled run observed |
| M5 | week-over-week diff via `?date=` (D5) | "added/removed since last week" section |
| M6 | global track: change detection, typed index columns, convert `cards/indexToOracle.json`, a decode helper (cube card -> oracle id -> name) | one real question answered from it |
| M7 | polish: `.lintr`, renv, pointblank | when it hurts |

## 3. Formats
- **Tables: Parquet** via `arrow::write_parquet()`. The default is snappy; zstd is smaller. *Measured*
  on the R output: `carddict` -38%, `cubes` -13%, `metadatadict` -7% (0.7 to 7 s to write). With
  pyarrow, sorting each cube's card list shaved another ~5% off `cubes`.
- **Integer width changes nothing on disk** (*measured* with pyarrow: int32 and int64 give the same
  size, Parquet encodes by value). R's int32 is fine.
- Timestamps in UTC (`POSIXct` with `tz = "UTC"`). List columns (`tags`, `colors`) are fine in Parquet;
  never mix element types in one (that was the #4 crash, and arrow in R refuses it too).
- **Config: YAML** (`yaml::read_yaml()`, comments allowed), or CSV if it stays three columns.
- **Fixtures: small trimmed JSON** copied from a real response. **Reports: Markdown** (renders in job
  summaries, issues and Pages).
- If snapshots are ever stored: Hive folders `snapshot_date=2026-10-19/`, read with `open_dataset()`.

## 4. Packages
| need | now | maybe later | why |
|---|---|---|---|
| JSON | RcppSimdJson | yyjsonr | *Measured* on `cubes.json`: jsonlite 190 s / 10.8 GB, RcppSimdJson 7.5 s / 2.6 GB, yyjsonr 7.0 s / 2.0 GB. yyjsonr's defaults bite: a dict of dicts comes back as a data frame with the ids as columns (`obj_of_arrs_to_df = FALSE` fixes it) and big ints as strings (`int64 = "bit64"`) |
| HTTP | | httr2 | `req_throttle()`, `req_retry()` and `req_perform_parallel()` are built in (*verified* present in 1.3.0) |
| frames and Parquet | dplyr + arrow | duckdb, dbplyr | `open_dataset()` filters lazily; DuckDB for joins that don't fit in RAM, or typed JSON ingestion (D7) |
| iteration, types | purrr, vctrs | | `list_c()`, `vec_cast()` and `vec_ptype()` carry `as_col()` |
| validation | `stopifnot()`, the parity checker | pointblank, validate | schema and row-level assertions |
| reports | Markdown strings | gt, ggplot2, Quarto | |
| tests | testthat | | |
| style | styler (applied to the scripts) | lintr with a `.lintr` | lintr's defaults flag dplyr's bare column names as undefined variables, so configure it |
| dependencies | `DESCRIPTION` + pak | renv | see D8 |

## 5. Report sketches
Written for the README's rules taken literally (D1-D3), with "uniques" = a cube flagged `uniques` in
the config. *Verified* on a hand-made 3-cube example (arrow 25 + dplyr 1.2). The same two queries in
SQL also ran in DuckDB and gave the same rows.
```r
cubes <- read_parquet("processed/my_cubes.parquet")
cards <- read_parquet("processed/my_cubes_cards.parquet")

# dupes: same card on main and maybe of one cube, or >1 copy on the maybeboard
cards |>
  summarise(
    name = first(name),
    n_main = sum(board == "mainboard"),
    n_maybe = sum(board == "maybeboard"),
    .by = c(cube_id, card_key)
  ) |>
  filter((n_main > 0 & n_maybe > 0) | n_maybe > 1)

# overlap: on a mainboard of a normal cube but not on the uniques mainboard
mains <- cards |>
  filter(board == "mainboard") |>
  inner_join(select(cubes, cube_id, label, uniques), by = "cube_id")
mains |>
  filter(!uniques, !card_key %in% mains$card_key[mains$uniques]) |>
  summarise(name = first(name), in_cubes = list(sort(unique(label))), .by = card_key)
```
Lazily on the file, nothing is read until `collect()`:
`open_dataset("processed/my_cubes_cards.parquet") |> filter(board == "maybeboard") |> count(cube_id, card_key) |> filter(n > 1) |> collect()`.
The "uniques, across all >1 copy" rule is the same `count(card_key) |> filter(n > 1)` over all cubes
and boards instead of one. Which of the two it is depends on D1.

## 6. Workflow notes
- `cubecobra-sync-r.yml` (#7) uses `r-lib/actions/setup-r` and `setup-r-dependencies` (reads
  `DESCRIPTION`, installs Posit Package Manager binaries, caches the library). Inline R steps use
  `shell: Rscript {0}`. The Python workflow is reused as a job with `workflow_call` (one line in it).
- **Time zone:** cron is UTC. 22:00 UTC (Mon/Wed) and 14:00 UTC (Sat) are 16:00 and 08:00 at UTC-6.
  tzdata 2026c has Alberta staying on UTC-6 from 2026-11-01, so they stay right all year. If clocks did
  keep changing, schedule both UTC hours and gate on `TZ=America/Edmonton date +%u%H` printing `116`,
  `316` or `608` (weekday + hour).
- `concurrency: {group: my-cubes}` so a slow run can't overlap the next.
- `permissions: {contents: read}`, plus `issues: write` only on the job that posts.
- **Change detection for the global export:** `curl -sI` the file, compare `ETag` or `Last-Modified`
  with the last processed one (kept in `actions/cache`), skip when equal. Upstream rebuilds ~every 90 days.
- Fail loudly: `if-no-files-found: error` on uploads; `shell: bash` (= `-eo pipefail`) when a step pipes.
- The 60-day auto-disable of scheduled workflows: check the Actions tab after ~50 days of quiet.

## 7. Data-quality checks
- Have: source rows == Parquet rows (both converters print `[OK]`); the parity checker, which is a
  template for the next point.
- After Python is gone: commit the expected schema (column names and types per file) and fail if it
  changes. That is what the parity run gives you today for free.
- Add: no null `card_key` or `name`; `board` in the known set; count of `-1` card slots in the global
  track (0.08% today) so a jump is noticed.
- **Canary:** record a real `cubejson` response as a fixture, and run a weekly workflow that fetches one
  small cube and asserts the same fields. If the API shape changes you hear about it first.

## 8. Where to borrow from
Your fork `colin-ww/fork--cubecobra` (I read `4114b92`, 2026-09-26; upstream is `dekkerglen/CubeCobra`):
- `packages/jobs/src/export_cubes.ts`: how `cubes.json` is built (public only, mainboard only, `|| -1`).
- `packages/server/src/router/routes/cube/api/cubeJSON.ts`: rate limit (100/min) and `?date=`.
- `packages/cardUpdateMonitorLambda/src/exportTasks.ts`: the 90-day export rule.
- `packages/server/src/serverutils/cubefn.ts`, `isCubeViewable`: public and unlisted are readable, private is not.
- `packages/docs/maintenance/analytics.md`: overview of the exports.

Other sources, only if needed: Scryfall bulk data and MTGJSON for card text or prices without CubeCobra.
Workflow examples for R: the `examples/` folder of `r-lib/actions`. Your own repos: `mtg-search` (I
haven't looked at it; possible overlap on card identity), and `cubecobra-card-rank` /
`cubecobra-top-cubes`, which are empty shells.

## 9. R gotchas from the port (all hit for real)
- **arrow in R is strict about types.** Named-list cells can't be converted at all; an empty `list()`
  cell in a list of strings fails ("Expecting a character vector"); a data frame column becomes a
  struct, a list of data frames a `list<struct>`; `bit64::integer64` becomes int64 while a plain
  double stays a double. That is why `as_col()` exists.
- **RcppSimdJson options:** `max_simplify_lvl = "list"` keeps JSON arrays as lists (a one-element
  array is never mistaken for a scalar), `empty_array = list()` keeps `[]` distinct from `null`,
  `int64_policy = "integer64"` keeps big ints exact. `fload()` swallows unknown arguments: I passed
  the old name `int64_r_type` and nothing complained, nothing happened.
- **Closures per cell are slow.** The first `as_col()` used a purrr closure per value and was still
  running after 10 minutes. Whole-vector calls (`lengths()`, `list_c()`, `lapply()` over primitives)
  brought all seven files to 147 s.
- `if (sys.nframe() == 0) main()` lets a script be `source()`d by tests without running it.
- `jsonlite::fromJSON()` is fine for small files and unusable for the 450 MB one.

## 10. Links
Returned HTTP 200 from the cloud sandbox this was written in, on 2026-10-18:
- R: [arrow](https://arrow.apache.org/docs/r/), [dplyr](https://dplyr.tidyverse.org/),
  [purrr](https://purrr.tidyverse.org/), [vctrs](https://vctrs.r-lib.org/),
  [RcppSimdJson](https://dirk.eddelbuettel.com/code/rcpp.simdjson.html),
  [yyjsonr](https://coolbutuseless.github.io/package/yyjsonr/), [httr2](https://httr2.r-lib.org/)
- Tooling: [testthat](https://testthat.r-lib.org/), [lintr](https://lintr.r-lib.org/),
  [styler](https://styler.r-lib.org/), [renv](https://rstudio.github.io/renv/),
  [pak](https://pak.r-lib.org/), [pointblank](https://rstudio.github.io/pointblank/),
  [Posit Package Manager](https://packagemanager.posit.co/__docs__/user/)
- Reports: [gt](https://gt.rstudio.com/), [ggplot2](https://ggplot2.tidyverse.org/),
  [Quarto on GitHub Pages](https://quarto.org/docs/publishing/github-pages.html)
- DuckDB: [R client](https://duckdb.org/docs/stable/clients/r.html),
  [JSON](https://duckdb.org/docs/stable/data/json/overview.html)
- GitHub Actions: [events incl. schedule](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
  [reusing workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [ntfy publish API](https://docs.ntfy.sh/publish/) (push to your phone), [MTGJSON](https://mtgjson.com/),
  [CubeCobra](https://cubecobra.com/)

GitHub and Scryfall web pages returned 403 from that sandbox's proxy, so these are from memory, not
checked: <https://github.com/dekkerglen/CubeCobra>, <https://github.com/r-lib/actions>,
<https://scryfall.com/docs/api/bulk-data>, <https://github.com/mtgjson/mtgjson>.

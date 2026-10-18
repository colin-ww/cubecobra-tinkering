# Roadmap: where this is and where it could go

> **Chat summary: pending.** `llm-convo.json` is still the 2-byte placeholder `x`, so there is no
> transcript and no summary of that chat yet. Everything below comes from the repo, the real data and
> CubeCobra's source, not from the chat. Push the real file and I'll add `docs/llm-convo.md` (full
> transcript), a "what the chat decided" section here, and reconcile the two.

**TL;DR**
- Direction: **Python -> R.** The converter is ported (#7) and checked against the Python one. Python
  stays until the parallel run has been green a few times.
- Done (open PRs): converter fixed in Python (#4, the reference); R port + parallel parity run (#7).
- Missing: the two reports (overlap, dupes). Blocked on three answers from you: what "uniques" means,
  what counts as "the same card", which boards count (decisions 1-3 below).
- Also missing: the real `llm-convo.json`.

Detailed how-to (repo layout, order, packages, formats, links) lives in
[implementation-ideas.md](implementation-ideas.md). This page is the big picture.

## What this project is (my reading)
Two tracks that share tooling but not data:

| | question it answers | source | state |
|---|---|---|---|
| **Global** | what does the whole CubeCobra world look like? (popularity, tags, co-occurrence) | public S3 export, rebuilt every ~90 days | R converter in #7, no consumer yet |
| **Mine** | are my cubes tidy? (overlap with "uniques", dupes), weekly | `cubejson` API | **not built** (fetcher and reports) |

Not goals for now: recommenders or ML (CubeCobra ships its own), draft picks (2+ GB per 1000 files), a web UI.

## Map
```mermaid
flowchart TB
    S3[("S3 public export<br/>rebuilt every ~90 days")] -->|convert_to_parquet.R| G[("global Parquet<br/>cubes, cards, tags")]
    API["cubejson API<br/>100 req/min"] -->|"fetcher (to build)"| M[("my cubes Parquet<br/>one row per card per board")]
    M --> R{{"reports: overlap, dupes"}}
    G -.->|optional context| R
    R --> D["delivery: job summary, issue, push"]
```

## Python -> R: retiring the Python side
1. Merge #4 (the Python fix, the reference) and #7 (R port + parallel run).
2. Dispatch `cubecobra-sync-r.yml` a few times, one of them after CubeCobra's next export (due about
   now). `compare` must be green each time.
3. Then delete `convert_to_parquet.py`, `cubecobra-sync.yml`, the `py` and `compare` jobs,
   `compare_parquet.R` and the Python lines in `.gitignore`.
4. Then fix the two mislabelled key columns once, in R only: `metadatadict` -> `oracle_id`,
   `oracleTagDict` -> `card_index`.

"Identical" means identical **values**, not types: R keeps ints that pandas turned into doubles
(`mtgo_id`, `tcgplayer_id`, `firstPrintYear`) and uses `string`, not `large_string`. Say so if you want
identical types instead; it is a few casts.

**What the port showed** (full export):
- Same data: 7 of 7 files identical, checked by `compare_parquet.R` locally **and in the first green
  parallel run on GitHub** (and the checker catches six kinds of deliberate corruption).
- Speed of the conversion step: on a GitHub runner R takes 66 s, Python 22 s (R: `cubes` 9.5 s,
  `carddict` 34 s, `metadatadict` 20 s). In my slower sandbox: 147 s vs 76 s. R is slower on the
  nested files; for a quarterly job that doesn't matter. Peak RAM on `cubes.json` (sandbox): 2.7 GB
  (R) vs 4.7 GB (pandas).
- Output size is the same: the R artifact is 211,062,566 bytes, the Python one 211,225,989.
- The price of R is ~40 lines (`as_col()`) that pandas + pyarrow do implicitly: arrow in R refuses
  named lists, empty `list()` cells and mixed cells, so every column has to be typed first.
- `jsonlite` is unusable here (190 s and 10.8 GB on `cubes.json`); RcppSimdJson does it in 7.5 s and 2.6 GB.

## Facts that shape the design (checked, not assumed)
- **Export cadence = ~90 days.** CubeCobra's monitor re-runs the export when the last successful one is
  older than 90 days. Last one: 2026-07-20, so the next is due about now. The `cards/*` files are older
  (2026-05-20). A quarterly cron fits; polling weekly and skipping unchanged files fits better.
- **`cubes.json` = public cubes, mainboard only.** No maybeboard, no unlisted or private cubes. It
  cannot feed the dupes report (needs maybeboard), so the personal track must use the API.
- **Card numbers are positions, not ids.** Each card in `cubes.json` is an index into
  `export/indexToOracleMap.json` (-1 = unknown or custom: 0.08% of slots). The `cards/*` files use a
  different list (`cards/indexToOracle.json`) built two months earlier: 840 fewer entries, diverging at
  index 55. **Never mix the two index spaces.** (This is the "MISMATCH" line in the sync workflow.)
- **`cubejson` API:** 100 requests/min per IP, open CORS, private cubes are invisible, and
  `?date=<unix ms>` returns the cube as of that date (checked: 180 days back differs by 76 cards).
  So week-over-week diffs don't need snapshots we store ourselves.
- **Time zone:** GitHub cron is UTC only. The tz database in the sandbox this was written in (tzdata
  2026c) says Alberta stops changing clocks on 2026-11-01 and stays on UTC-6, so Mon/Wed 16:00 and Sat
  08:00 local are 22:00 and 14:00 UTC all year and no DST handling is needed. You live there, so tell
  me if that's wrong.
- **Upstream quirks we already hit:** one leaked Mongo ObjectID in `following` (fixed in #4 and #7); the
  export code does `index || -1`, which also turns index 0 into -1.
- **Cost:** global track 750 MB JSON -> 235 MB Parquet (201 MB zipped artifact). The Python workflow
  takes 77 s end to end on a runner.

## Decisions to make
The first three block the reports, the fourth blocks delivery; the rest can wait. My lean in *italics*.

1. **What is "uniques"?** Only you know. My three guesses:

   | reading | "in a cube but not in uniques" means | "uniques: across all >1 copy" means |
   |---|---|---|
   | A. master list of every card I own | cards I forgot to add to the master list | trivial: master list should be singleton |
   | B. cards I own exactly one copy of | cards that are *not* single-copy | a single-copy card sits in 2+ cubes: conflict |
   | C. cube of cards allowed nowhere else | normal cards, fine | a uniques card also in another cube: violation |

2. **Card identity.** Oracle id (any printing) vs exact printing vs name. *Oracle id for reports; keep
   the printing column for "owned" tracking.*
3. **Which boards count.** README implies: overlap = mainboards, dupes = mainboard vs maybeboard and
   copies in maybeboard. *Follow the README, make it a config switch.*
4. **Where reports go.** Job summary (zero setup) / issue with an @mention (the GitHub app pings your
   phone) / ntfy push / Quarto page on GitHub Pages / email. *Job summary + issue first, Pages later.*
5. **History.** Store weekly snapshots, or lean on `?date=` time travel. *Don't store anything yet.*
6. **Keep the global track?** It has no consumer. *Keep (cheap) but build nothing on it until a
   question needs it; add change detection so it doesn't redo identical data.*
7. **How to type JSON for arrow.** Keep `as_col()` (pure R, tested) or ingest with DuckDB SQL. DuckDB
   converted `cubes.json` ~3.5x faster than pandas in my test, but guesses types badly (`DOUBLE[]` for
   card ids, `JSON[]` for `following`) and needs explicit `columns=`. *Keep `as_col()`; look at DuckDB
   if more JSON shapes appear.*
8. **Dependencies.** `DESCRIPTION` (now, read by pak and `setup-r-dependencies`) vs `renv.lock`; and
   whether to pin a Posit Package Manager snapshot date. *DESCRIPTION + PPM latest until something
   breaks; renv when you move this to the Artifactory mirror.*
9. **Private cubes.** The API can't see them. *Make them unlisted: still fetchable by id, just not listed.*

## Suggested order
1. Retire Python as above (merge #4 and #7, a few green parallel runs, delete).
2. Answer decisions 1-4 (1-3 first).
3. One PR: fetch my cubes from the API into two tables, `my_cubes` and `my_cubes_cards` (one row per
   card per board, `card_key` = oracle id). `httr2` has throttling, retries and parallel requests built in.
4. One PR: the two reports as functions over those tables, with testthat tests on small fixtures.
5. One PR: delivery (decision 4) and switching the schedule on.
6. Optional: change detection for the global export; first real question on the global data.
7. Housekeeping when it hurts: `.lintr`, renv, Dependabot grouping.

## Gotchas to plan for
- Scheduled workflows are delayed under load, and **GitHub disables them after 60 days without repo
  activity** in public repos. Either keep committing, or add a keep-alive.
- 3 runs a week is noisy if nothing changed. *Report only when there is something to act on.*
- The API shape can change. Keep a recorded real response as a test fixture.
- Once Python is gone nothing compares R to a reference. A new arrow release can change typing
  behaviour: keep the testthat fixtures, and consider committing the expected schema (names + types)
  as a snapshot test.

## Pushback on the original idea (you asked for it)
- **The global Parquet pipeline is not a prerequisite for the weekly reports.** Separate tracks. Don't
  let the big one hold up the small one.
- **Parquet for ~100 KB of personal data is overkill**, CSV would do. Keep it anyway: types survive and
  it matches the global track.
- **"Parity with Python" is a choice, not the truth.** pandas turned some int columns into doubles
  because of missing values; R's version is arguably the better one. I compared values, not types.
- **Watch the size of `as_col()`.** It is cheap now. If more JSON shapes or deeper nesting show up,
  hand-typing in R may cost more than SQL ingestion in DuckDB.

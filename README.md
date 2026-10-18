# cubecobra-tinkering

CubeCobra's public JSON export -> Parquet, moving from Python to R.

| | script | workflow |
|---|---|---|
| Python (reference, stays until R is checked) | `scripts/convert_to_parquet.py` | `cubecobra-sync.yml` |
| R port | `scripts/convert_to_parquet.R` | `cubecobra-sync-r.yml` |

`cubecobra-sync-r.yml` runs both on the same export, in parallel, then `scripts/compare_parquet.R`
checks that they wrote the same data (job summary shows the result). Once that is green a few
times: delete the Python script, `cubecobra-sync.yml`, the `py` and `compare` jobs, and
`compare_parquet.R`.

Run the R version locally (`raw/` and `processed/` are git-ignored):
```sh
scripts/download_raw.sh                      # ~780 MB into raw/
Rscript scripts/convert_to_parquet.R         # -> processed/*.parquet
Rscript -e 'testthat::test_dir("tests/testthat")'
```
R dependencies are declared in `DESCRIPTION` (`pak::local_install_dev_deps()` installs them).

### overlap between (my) cubes
- Just this? Card name in a cube but not in "uniques"
- Weekly reports: Mon 4p, Wed 4p, Sat 8a - MT Edmonton Canada

### check dupes
- Same weekly sched as above
- all: in both mb/main, or >1 copy mb
- uniques addt rule: across all >1 copy

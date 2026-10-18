#!/usr/bin/env Rscript
# Parity check for the Python -> R port: do two directories of Parquet files hold the same data?
#
#   Rscript scripts/compare_parquet.R processed-py processed-r
#
# Per file: same rows, same columns in the same order, same values. Types may differ as long as the
# values survive a cast to the reference type (R's int32 vs pandas' int64, string vs large_string,
# int vs double where pandas had NaN): those are listed at the end, not failed.
# Exit status 1 if any file differs, so a workflow fails on it. Delete this with the Python script.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(purrr)
})

# Leaf types of a possibly nested type, in order: struct<a: int64, b: list<string>> -> int64, string
leaf_types <- function(type) {
  if (inherits(type, "StructType")) {
    type$fields() |>
      map(\(field) leaf_types(field$type)) |>
      list_c()
  } else if (inherits(type, c("ListType", "LargeListType"))) {
    leaf_types(type$value_type)
  } else {
    type$ToString()
  }
}

# One column: do the values match once cast to the reference type? Plus which leaf types changed.
compare_col <- function(ref, new) {
  same_type <- ref$type == new$type
  cast <- if (same_type) new else tryCatch(new$cast(ref$type), error = \(e) NULL)
  changed <- if (same_type) {
    tibble(from = character(), to = character())
  } else {
    tibble(from = leaf_types(ref$type), to = leaf_types(new$type)) |>
      filter(from != to) |>
      distinct()
  }
  list(equal = !is.null(cast) && ref$Equals(cast), changed = changed)
}

compare_file <- function(name, dir_ref, dir_new) {
  ref <- file.path(dir_ref, name) |> read_parquet(as_data_frame = FALSE)
  new <- file.path(dir_new, name) |> read_parquet(as_data_frame = FALSE)
  cols <- intersect(names(ref), names(new)) |>
    set_names() |>
    map(\(col) compare_col(ref[[col]], new[[col]]))
  bad <- cols |>
    discard(\(col) col$equal) |>
    names()
  list(
    summary = tibble(
      file = name,
      rows_ref = ref$num_rows,
      rows_new = new$num_rows,
      columns = case_when(
        identical(names(ref), names(new)) ~ "same",
        setequal(names(ref), names(new)) ~ "**order differs**",
        .default = sprintf(
          "**differ** (only reference: %s; only new: %s)",
          paste(setdiff(names(ref), names(new)), collapse = ", "),
          paste(setdiff(names(new), names(ref)), collapse = ", ")
        )
      ),
      values = if (length(bad) == 0) "equal" else paste("**differ:**", paste(bad, collapse = ", "))
    ),
    types = cols |> map("changed") |> list_rbind(names_to = "column") |> mutate(file = name)
  )
}

main <- function(dir_ref, dir_new) {
  files <- c(dir_ref, dir_new) |>
    map(\(d) list.files(d, pattern = "\\.parquet$")) |>
    reduce(union) |>
    sort()
  both <- files |> keep(\(f) file.exists(file.path(dir_ref, f)) && file.exists(file.path(dir_new, f)))
  results <- both |> map(compare_file, dir_ref, dir_new)

  summary <- results |>
    map("summary") |>
    list_rbind() |>
    mutate(ok = rows_ref == rows_new & columns == "same" & values == "equal")
  type_changes <- results |>
    map("types") |>
    list_rbind() |>
    distinct(file, column, from, to) |>
    summarise(
      n = n(), examples = paste(head(sprintf("%s.%s", sub("\\.parquet$", "", file), column), 3), collapse = ", "),
      .by = c(from, to)
    ) |>
    arrange(desc(n))
  missing <- setdiff(files, both)

  lines <- c(
    sprintf("Parity: `%s` (reference) vs `%s`", dir_ref, dir_new),
    "",
    "| file | rows | columns | values |",
    "|---|---|---|---|",
    summary |> pmap_chr(\(file, rows_ref, rows_new, columns, values, ok) {
      sprintf(
        "| %s %s | %s | %s | %s |", if (ok) "OK" else "**DIFF**", file,
        if (rows_ref == rows_new) rows_ref else sprintf("**%s vs %s**", rows_ref, rows_new), columns, values
      )
    }),
    sprintf("| **DIFF** %s | | | missing in one directory |", missing),
    "",
    sprintf("%d of %d files identical in content.", sum(summary$ok), length(files)),
    if (nrow(type_changes) > 0) {
      c(
        "", "Type differences that keep the values (reference -> new):",
        type_changes |> pmap_chr(\(from, to, n, examples) sprintf("- %s -> %s: %d columns (%s%s)", from, to, n, examples, if (n > 3) ", ..." else ""))
      )
    }
  )
  writeLines(lines)
  summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY")
  if (nzchar(summary_file)) write(lines, summary_file, append = TRUE)
  quit(status = if (all(summary$ok) && length(missing) == 0) 0 else 1)
}

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 2) stop("usage: compare_parquet.R <reference dir> <new dir>")
  main(args[1], args[2])
}

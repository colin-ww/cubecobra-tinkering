#!/usr/bin/env Rscript
# Convert CubeCobra's public JSON export to Parquet.
# R port of convert_to_parquet.py: same inputs, same outputs, same column names.
#
# Three JSON shapes show up in this dataset:
#   - array-of-objects   (cubes.json)                -> straight to a data frame
#   - object keyed by id (carddict, metadatadict,
#     indexToOracleMap, oracleToId, oracleTagDict...) -> needs reshaping: one row per key
#   - array-of-scalars   (oracleTagNames)            -> keyed by position
#
# RcppSimdJson parses (jsonlite needs ~190 s and 11 GB for cubes.json, simdjson ~8 s and 3 GB).
# pandas + pyarrow typed the nested columns for us; here `as_col()` types them from the
# parsed JSON: object -> data frame (arrow struct), array -> list column, scalar -> plain vector.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(purrr)
  library(vctrs)
})

RAW <- "raw"
OUT <- "processed"

# A few legacy ids leak into the export as
#   {"_bsontype": "ObjectID", "id": {"type": "Buffer", "data": [<12 bytes>]}, ...}
# instead of the usual 24-char hex string (e.g. one entry of one cube's `following`).
# Left alone, that object inside a list of strings can't be typed.
oid_to_hex <- function(x) {
  if (is.list(x) && identical(x[["_bsontype"]], "ObjectID")) {
    x$id$data |>
      unlist() |>
      as.raw() |>
      as.character() |>
      paste(collapse = "")
  } else {
    x
  }
}

# Parsed JSON values, one per row (NULL = null or missing) -> a column arrow can type.
# Like the Python version, the first non-empty value decides the shape.
as_col <- function(cells) {
  big <- which(lengths(cells) > 1) # only these can hold an ObjectID
  cells[big] <- lapply(cells[big], oid_to_hex)
  has_value <- lengths(cells) > 0
  if (!any(has_value)) {
    return(rep(NA, length(cells)))
  }
  first <- cells[has_value][[1]]
  if (!is.list(first)) { # scalar
    cells[!has_value] <- list(NA)
    list_c(cells)
  } else if (is.null(names(first))) { # array -> list column
    as_arrays(cells)
  } else { # object -> data frame (arrow struct), one column per field
    cells |>
      lapply(names) |>
      list_c() |>
      unique() |>
      set_names() |>
      map(\(field) as_col(lapply(cells, `[[`, field))) |>
      new_data_frame(n = length(cells))
  }
}

# List column of arrays: every cell becomes a vector (or a data frame, for arrays of
# objects) of one common type. NULL stays NULL (null); an empty array keeps its type.
as_arrays <- function(cells) {
  is_list <- vapply(cells, is.list, NA)
  cells[is_list] <- lapply(cells[is_list], as_col)
  ptype <- cells[lengths(cells) > 0] |>
    list_c() |>
    vec_ptype()
  lapply(cells, \(x) if (is.null(x)) NULL else if (vec_size(x) == 0) ptype else vec_cast(x, ptype))
}

# Parse one export file. Array-of-objects: arrays of numbers come back as vectors, which
# is what we want and is far lighter than boxing 68M card ids. Keyed objects: keep the JSON
# structure as lists, so a one-element array is never mistaken for a scalar.
load_json <- function(name, is_array) {
  file.path(RAW, name) |>
    RcppSimdJson::fload(
      max_simplify_lvl = if (is_array) "data_frame" else "list",
      empty_array = list(),
      int64_policy = "integer64"
    )
}

map_to_df <- function(data, key_name = "key") {
  # {key: value} -> one row per key. A plain array is keyed by position, like Python's enumerate().
  keys <- names(data) %||% (seq_along(data) - 1L)
  values <- as_col(unname(data))
  # Handles three shapes of `value`:
  #   - object (e.g. carddict: {oracle_id: {name: ..., cmc: ...}}) -> its fields become columns
  #   - array  (e.g. oracleTagDict: {oracle_id: [tag1, tag2]})     -> list column `value`
  #   - scalar (e.g. indexToOracleMap: {"0": "uuid-string"})        -> column `value`
  tibble::tibble(!!key_name := keys) |>
    bind_cols(if (is.data.frame(values)) values else tibble::tibble(value = values))
}

convert <- function(name, out_name, key_name = "key", is_array = FALSE) {
  started <- Sys.time()
  data <- load_json(name, is_array)

  df <- if (is_array) {
    data |>
      tibble::as_tibble() |>
      mutate(across(where(is.list), as_arrays))
  } else {
    map_to_df(data, key_name)
  }
  n_source <- if (is_array) nrow(data) else length(data)

  write_parquet(df, file.path(OUT, out_name))

  n_rows <- nrow(df)
  status <- if (n_rows == n_source) "OK" else "MISMATCH"
  cat(sprintf(
    "%-30s -> %-25s source_keys=%7d parquet_rows=%7d [%s]\n",
    name, out_name, n_source, n_rows, status
  ))
  message(sprintf("  %.1f s", as.numeric(Sys.time() - started, units = "secs")))
}

if (sys.nframe() == 0) { # run as a script, not when source()d (e.g. by tests)
  dir.create(OUT, showWarnings = FALSE)
  # Key names are the Python script's, on purpose (parity check). Two are off: metadatadict's keys
  # are oracle ids and oracleTagDict's are card indices. Fix them in both scripts or after Python is gone.
  tibble::tribble(
    ~name,                       ~out_name,                        ~key_name,   ~is_array,
    "cubes.json",                "cubes.parquet",                  "key",       TRUE,
    "export_indexToOracle.json", "export_index_to_oracle.parquet", "index",     FALSE,
    "carddict.json",             "carddict.parquet",               "id",        FALSE,
    "metadatadict.json",         "metadatadict.parquet",           "id",        FALSE,
    "oracleToId.json",           "oracle_to_id.parquet",           "oracle_id", FALSE,
    "oracleTagDict.json",        "oracle_tag_dict.parquet",        "oracle_id", FALSE,
    "oracleTagNames.json",       "oracle_tag_names.parquet",       "tag_id",    FALSE
  ) |>
    pwalk(convert)
}

env <- new.env(parent = globalenv())
sys.source(test_path("../../scripts/convert_to_parquet.R"), envir = env)

# The ObjectID that leaked into cube 5d83674db656d33b0d4bcc29's `following` (the crash fixed in #4)
oid <- list(
  `_bsontype` = "ObjectID",
  id = list(type = "Buffer", data = as.list(c(100L, 11L, 153L, 205L, 140L, 253L, 227L, 105L, 208L, 176L, 130L, 71L))),
  generationTime = 1678481869L
)
oid_hex <- "640b99cd8cfde369d0b08247"

test_that("a leaked ObjectID becomes its 24-char hex string, anything else is left alone", {
  expect_identical(env$oid_to_hex(oid), oid_hex)
  expect_identical(env$oid_to_hex("abc"), "abc")
  expect_identical(env$oid_to_hex(list(a = 1L)), list(a = 1L))
})

test_that("as_col: scalars, with NULL as NA and numbers promoted", {
  expect_identical(env$as_col(list("a", NULL, "c")), c("a", NA, "c"))
  expect_identical(env$as_col(list(1L, 2.5, NULL)), c(1, 2.5, NA))
})

test_that("as_col: arrays become a list column; null stays null, [] keeps its type", {
  expect_identical(
    env$as_col(list(list("a", "b"), NULL, list())),
    list(c("a", "b"), NULL, character())
  )
})

test_that("as_col: objects become one column per field, missing fields are NA", {
  out <- env$as_col(list(list(a = 1L, b = "x"), list(a = 2L), NULL))
  expect_s3_class(out, "data.frame")
  expect_identical(names(out), c("a", "b"))
  expect_identical(out$a, c(1L, 2L, NA))
  expect_identical(out$b, c("x", NA, NA))
})

test_that("as_col: a leaked ObjectID in a list of ids no longer breaks the typing", {
  expect_identical(
    env$as_col(list(list("u1", oid, "u2"))),
    list(c("u1", oid_hex, "u2"))
  )
})

test_that("map_to_df: all four shapes of the export", {
  # object of objects -> fields become columns
  objs <- env$map_to_df(list(a = list(x = 1L, y = "p"), b = list(x = 2L, y = "q")), "id")
  expect_identical(names(objs), c("id", "x", "y"))
  expect_identical(objs$id, c("a", "b"))
  # object of arrays -> list column `value`
  arrs <- env$map_to_df(list(a = list(1L, 2L), b = list(3L)), "k")
  expect_identical(arrs$value, list(1:2, 3L))
  # object of scalars -> column `value`
  scal <- env$map_to_df(list(`0` = "u0", `1` = "u1"), "index")
  expect_identical(scal$value, c("u0", "u1"))
  # plain array of scalars -> keyed by position, 0-based like Python's enumerate()
  pos <- env$map_to_df(list("t0", "t1", "t2"), "tag_id")
  expect_identical(pos$tag_id, 0:2)
  expect_identical(pos$value, c("t0", "t1", "t2"))
})

test_that("convert() writes typed Parquet (end to end, with the ObjectID cube)", {
  raw <- withr::local_tempdir()
  env$RAW <- raw
  env$OUT <- withr::local_tempdir()
  writeLines(
    '[{"cards":[1,2],"id":"a","following":["u1",{"_bsontype":"ObjectID","id":{"type":"Buffer","data":[100,11,153,205,140,253,227,105,208,176,130,71]},"generationTime":1678481869},"u2"],"card_count":2,"date_last_updated":1791921027281},
      {"cards":[],"id":"b","following":[],"card_count":0,"date_last_updated":5}]',
    file.path(raw, "cubes.json")
  )
  writeLines('{"c1":{"name":"X","prices":{"usd":1.5},"colors":["W"]},"c2":{"name":"Y","prices":{"usd":2,"eur":3},"colors":[]}}', file.path(raw, "carddict.json"))
  writeLines('["tag-a","tag-b"]', file.path(raw, "tags.json"))

  out <- capture.output(suppressMessages({
    env$convert("cubes.json", "cubes.parquet", is_array = TRUE)
    env$convert("carddict.json", "carddict.parquet", key_name = "id")
    env$convert("tags.json", "tags.parquet", key_name = "tag_id")
  }))
  expect_length(grep("\\[OK\\]", out), 3)

  cubes <- arrow::read_parquet(file.path(env$OUT, "cubes.parquet"), as_data_frame = FALSE)
  expect_identical(cubes$schema$GetFieldByName("following")$type$ToString(), "list<element: string>")
  expect_identical(cubes$schema$GetFieldByName("date_last_updated")$type$ToString(), "int64")
  cubes <- as.data.frame(cubes)
  expect_identical(cubes$following[[1]], c("u1", oid_hex, "u2"))
  expect_identical(cubes$following[[2]], character())
  expect_identical(cubes$cards[[2]], integer())

  cards <- arrow::read_parquet(file.path(env$OUT, "carddict.parquet"), as_data_frame = FALSE)
  expect_identical(cards$schema$GetFieldByName("prices")$type$ToString(), "struct<usd: double, eur: int32>")
  cards <- as.data.frame(cards)
  expect_equal(as.list(cards$colors), list("W", character()), ignore_attr = TRUE)
  expect_identical(cards$prices$eur, c(NA, 3L))

  tags <- arrow::read_parquet(file.path(env$OUT, "tags.parquet"))
  expect_identical(tags$tag_id, 0:1)
})

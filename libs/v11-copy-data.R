# v11-copy-data.R -- copy the v11 evidence the release chapter reads into data/v11/
#
#   Rscript libs/v11-copy-data.R [path/to/workflows]     (default ../workflows)
#
# releases/_v11-body.qmd reads its Program-Area figures from v11's PUBLISHED tables
# (libs/versioned.R). Three things it shows are not published tables, so they are
# copied here from the workflows checkout that built v11, the way data/v7c/ was:
#
#   attribution_programarea.parquet  <- data/v11/attribution/*.parquet (snapshot_scores.qmd):
#                                       one zone-score snapshot per method variant, Program-Area
#                                       rows only, composites and components only. A snapshot
#                                       taken before a flag existed lacks its column; it is filled
#                                       with that flag's control value, as compare_versions.qmd does.
#   occ_pairs.parquet                <- data/v11/zone_weights_occ.csv (explore_occurrence_rule.qmd):
#                                       every species x ecoregion pair the occurrence rule gates
#                                       (w = 0, w_reason 'dropped') or weights (0 < w < 1).
#   density_cal_factors_suit.csv     <- data/v11/density_cal_factors_suit.csv (merge_models.qmd,
#                                       FOLD_DENSITY_CAL=suit): one calibration factor per density taxon.
#
# The source commit and file digests are written to data/v11/sources.json.
args <- commandArgs(trailingOnly = TRUE)
wf   <- normalizePath(if (length(args)) args[1] else file.path("..", "workflows"), mustWork = TRUE)
out  <- here::here("data/v11")
dir.create(out, showWarnings = FALSE, recursive = TRUE)
con  <- DBI::dbConnect(duckdb::duckdb())
on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
q <- function(sql) invisible(DBI::dbExecute(con, sql))

# the snapshots, unioned by name; flags absent from an older snapshot take their control value
att <- file.path(wf, "data/v11/attribution")
q(sprintf("
  CREATE TABLE att AS SELECT * FROM read_parquet('%s/*.parquet', union_by_name = true)
  WHERE zone_fld = 'programarea_key'
    AND (metric_key LIKE 'score!_%%' ESCAPE '!' OR metric_key LIKE 'extrisk!_%%!_v10!_global' ESCAPE '!'
         OR metric_key LIKE '%%ecoregion!_rescaled' ESCAPE '!' OR metric_key = 'primprod_v10')", att))
ctl <- c(nc_atl_source = "'2018'", fold_density_cal = "'none'", share_basis = "'taxon'", range_fill = "'er'")
q(sprintf("COPY (SELECT * REPLACE (%s) FROM att ORDER BY variant, metric_key, zone_value)
  TO '%s/attribution_programarea.parquet' (FORMAT parquet, COMPRESSION zstd)",
  paste(sprintf("coalesce(CAST(%s AS VARCHAR), %s) AS %s", names(ctl), ctl, names(ctl)), collapse = ", "), out))

q(sprintf("COPY (
  SELECT mdl_key, zone_key, sp_cat, scientific_name, common_name, n_searched, n_occupied, n_records, w, w_reason
  FROM read_csv('%s/data/v11/zone_weights_occ.csv') ORDER BY sp_cat, mdl_key, zone_key)
  TO '%s/occ_pairs.parquet' (FORMAT parquet, COMPRESSION zstd)", wf, out))

invisible(file.copy(file.path(wf, "data/v11/density_cal_factors_suit.csv"), out, overwrite = TRUE))

src <- c(file.path("data/v11/attribution", list.files(att, "\\.parquet$")),
         "data/v11/zone_weights_occ.csv", "data/v11/density_cal_factors_suit.csv")
git <- function(...) suppressWarnings(system2("git", c("-C", wf, ...), stdout = TRUE))
jsonlite::write_json(list(
  workflows_commit = git("rev-parse", "--short", "HEAD"),
  workflows_branch = git("rev-parse", "--abbrev-ref", "HEAD"),
  uncommitted      = intersect(src, sub("^.. ", "", git("status", "--porcelain", "--", src))),
  files = lapply(setNames(src, src), function(f) unname(tools::md5sum(file.path(wf, f))))),
  file.path(out, "sources.json"), auto_unbox = TRUE, pretty = TRUE)
message("wrote ", paste(list.files(out), collapse = ", "))

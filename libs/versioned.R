# versioned.R — one book source, rendered per MST release
# initiated by .Rprofile (alongside functions.R)
#
# The apps render nine releases from one codebase via `?ver=`; this makes the docs
# do the same via `DOCS_VER`. Before it, ONE build mixed FOUR versions:
#
#   docs/VERSION       v8   drove only the publish path — no .qmd ever read it
#   libs/functions.R   v4   the ecoregion/programarea PMTiles the maps actually drew
#   db.qmd             v6   paths and the "Rows (v6)" table header
#   stats.R            —    an UNVERSIONED api.marinesensitivity.org/stats.json,
#                           falling back to hardcoded v7 numbers
#
# So rebuilding a v4 doc set printed v8 numbers under a v4 label: worse than a
# stale figure, because it reads as authoritative. Every number on every page now
# comes from THAT version's published tables.
#
# Design rules, mirroring msens/R/version.R:
#  - NEVER fall back to another version's numbers. A missing figure renders as a
#    visible placeholder; it does not silently borrow v8's.
#  - capability and table presence come from the release's own manifest, so a v1
#    build OMITS a section rather than describing behaviour v1 never had.
#  - column names are resolved by msens::sdm_cols(), not re-derived here — a
#    second copy of that rule is how a v3 page ends up printing `is_valid_usa`.

# ---- which version is this build? --------------------------------------------

#' The version this build documents: env `DOCS_VER`, else the `VERSION` file.
#' Validated against the published registry, so a typo fails loudly at render.
doc_ver <- local({
  cached <- NULL
  function(refresh = FALSE) {
    if (!is.null(cached) && !refresh) return(cached)
    v <- trimws(Sys.getenv("DOCS_VER", ""))
    if (!nzchar(v)) v <- trimws(readLines(here::here("VERSION"), warn = FALSE)[1])
    if (!grepl("^v[0-9]+[a-z]?$", v))
      stop("DOCS_VER / VERSION does not name a release: '", v, "'", call. = FALSE)
    cached <<- v
    v
  }
})

#' That version's manifest — the contract describing what it published.
doc_manifest <- local({
  cached <- NULL
  function(refresh = FALSE) {
    if (!is.null(cached) && !refresh) return(cached)
    cached <<- msens::atlas_manifest(doc_ver(), refresh = refresh)
    cached
  }
})

#' The whole registry (all releases), for the Releases timeline.
doc_versions <- local({
  cached <- NULL
  function() {
    if (is.null(cached)) cached <<- msens::atlas_versions()
    cached
  }
})

#' Row for this version in the registry (title, status, released).
doc_version_row <- function(ver = doc_ver()) {
  d <- doc_versions()
  d[match(ver, d$ver), , drop = FALSE]
}

# ---- capability + table gates -------------------------------------------------

#' Does this release declare a capability? Unknown capabilities are FALSE.
doc_can <- function(what) msens::manifest_can(doc_manifest(), what)

#' Did this release publish a given table? Presence, never assumption.
doc_has <- function(tbl) tbl %in% names(doc_manifest()$tables)

#' Names of the tables this release published.
doc_tables <- function() names(doc_manifest()$tables)

# ---- reading this version's published tables ----------------------------------

# One DuckDB connection per render, configured for path-style S3 over HTTPS
# (the bucket name contains dots, which breaks virtual-hosted-style TLS).
.doc_con <- local({
  con <- NULL
  function() {
    if (!is.null(con) && DBI::dbIsValid(con)) return(con)
    con <<- DBI::dbConnect(duckdb::duckdb())
    DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
    DBI::dbExecute(con, "SET s3_url_style='path'; SET s3_region='us-east-1';")
    con
  }
})

#' A published table of THIS version, as a data frame.
#'
#' Reads the URL the manifest declares — so a table the release never published
#' errors here rather than silently resolving to some other version's file.
#' `sql` may reference the table by name.
doc_tbl <- function(tbl, sql = NULL) {
  m <- doc_manifest()
  if (!tbl %in% names(m$tables))
    stop(sprintf("%s does not publish `%s` (has: %s) — gate this section on doc_has()",
                 doc_ver(), tbl, paste(names(m$tables), collapse = ", ")), call. = FALSE)
  src <- sprintf("read_parquet('%s')", m$tables[[tbl]])
  q   <- if (is.null(sql)) sprintf("SELECT * FROM %s", src)
         else gsub(sprintf("\\b%s\\b", tbl), src, sql)
  DBI::dbGetQuery(.doc_con(), q)
}

#' Column names + types of a published table, without reading it.
doc_cols <- function(tbl) {
  m <- doc_manifest()
  DBI::dbGetQuery(.doc_con(), sprintf(
    "DESCRIBE SELECT * FROM read_parquet('%s')", m$tables[[tbl]]))
}

#' Row count of a published table.
doc_nrow <- function(tbl) doc_tbl(tbl, sprintf("SELECT count(*) AS n FROM %s", tbl))$n

# ---- computed statistics ------------------------------------------------------

# Which column carries which concept in THIS release is msens's rule, resolved by
# introspection. Answered against a connection carrying just this version's views.
.doc_keys <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)
    con <- .doc_con(); m <- doc_manifest()
    for (t in intersect(c("taxon", "model"), names(m$tables)))
      DBI::dbExecute(con, sprintf(
        "CREATE OR REPLACE TEMP VIEW %s AS SELECT * FROM read_parquet('%s')", t, m$tables[[t]]))
    cached <<- msens::sdm_cols(con, mc_tbl = NULL)
    cached
  }
})

#' Statistics for THIS version, computed from its own published tables.
#'
#' Returns `NA` for anything the release cannot answer (rather than a number from
#' elsewhere); `doc_stat_fmt()` renders that as a visible placeholder.
doc_stats <- local({
  cached <- NULL
  function(refresh = FALSE) {
    if (!is.null(cached) && !refresh) return(cached)
    m <- doc_manifest()
    out <- list(ver = doc_ver(), status = m$status, grid_id = m$grid_id)

    k <- tryCatch(.doc_keys(), error = function(e) NULL)
    valid_sql <- if (is.null(k)) NULL else {
      # v1-v7's is_ok already baked in the marine/category cull; v8's
      # is_valid_usa means only "has >=1 merged cell in US waters", so scoring
      # eligibility there also needs is_marine (msens::sdm_cols() reports it).
      paste0("WHERE ", k$valid, if (!is.na(k$marine)) paste0(" AND ", k$marine) else "")
    }

    out$total_taxa <- tryCatch(doc_nrow("taxon"), error = function(e) NA_integer_)
    out$valid_species <- tryCatch(
      doc_tbl("taxon", sprintf("SELECT count(*) AS n FROM taxon %s", valid_sql))$n,
      error = function(e) NA_integer_)

    # Program-Area subset: a SPATIAL question, answered by the zone tables, never
    # by the validity flag (conflating the two is what v7 fixed). zone_taxon
    # carries zone_fld/zone_value + taxon_authority/taxon_id on every release, so
    # one query serves all nine. Counted on the (authority, id) PAIR: the two
    # namespaces (WORMS, BOTW) renumber independently, so counting bare ids
    # collides birds with invertebrates.
    out$species_program_areas <- tryCatch({
      if (!doc_can("programareas") || !doc_has("zone_taxon")) NA_integer_ else
        doc_tbl("zone_taxon", paste(
          "SELECT count(DISTINCT taxon_authority || ':' || taxon_id) AS n",
          "FROM zone_taxon WHERE zone_fld = 'programarea_key'"))$n
    }, error = function(e) NA_integer_)

    zn <- tryCatch(doc_manifest()$zones, error = function(e) NULL)
    cnt <- function(f) if (is.data.frame(zn) && f %in% zn$fld) as.integer(zn$n[zn$fld == f][1]) else NA_integer_
    out$n_program_areas <- cnt("programarea_key")
    out$n_ecoregions    <- cnt("ecoregion_key")
    out$n_subregions    <- cnt("subregion_key")
    out$n_planning_areas <- cnt("planarea_key")

    # datasets: registered vs actually used by the scores (msens::dataset_is_scored)
    ds <- tryCatch(doc_datasets(), error = function(e) NULL)
    out$n_datasets_registered <- if (is.null(ds)) NA_integer_ else nrow(ds)
    out$n_datasets <- if (is.null(ds)) NA_integer_ else sum(ds$is_scored & ds$ds_key != "ms_merge")
    out$n_cells <- tryCatch(doc_nrow("cell"), error = function(e) NA_integer_)
    out$n_models <- tryCatch(doc_nrow("model"), error = function(e) NA_integer_)
    cached <<- out
    out
  }
})

#' How many VALID taxa each dataset actually supplied a model for.
#'
#' The distinction that matters on the data-sources page. A release's `model`
#' registry counts models it *catalogued*, which is not what it *used*: v1
#' registers 29 FWS critical-habitat models but only 27 attach to a valid taxon,
#' and only 4 reach the scored output. Presenting a 27-taxon pilot in the same
#' column as AquaMaps' 16,871 makes a release look far broader than it was —
#' which is exactly how v1 came to read as a five-dataset release.
#'
#' Counted on the (authority, id) PAIR for the same reason as everywhere else:
#' the WoRMS and BirdLife namespaces number independently.
doc_dataset_taxa <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)
    if (!doc_has("taxon_model")) { cached <<- data.frame(); return(cached) }
    m   <- doc_manifest()
    k   <- .doc_keys()
    tm  <- m$tables[["taxon_model"]]; tx <- m$tables[["taxon"]]
    tmc <- DBI::dbGetQuery(.doc_con(), sprintf(
      "DESCRIBE SELECT * FROM read_parquet('%s')", tm))$column_name
    valid <- paste0("t.", k$valid, if (!is.na(k$marine)) paste0(" AND t.", k$marine) else "")
    # v8 keys the relation on ms_merge_key; v1-v7 on taxon_id
    sql <- if ("ms_merge_key" %in% tmc)
      sprintf("SELECT tm.ds_key, count(DISTINCT tm.ms_merge_key) AS n_taxa
                 FROM read_parquet('%s') tm JOIN read_parquet('%s') t USING (ms_merge_key)
                WHERE %s GROUP BY 1", tm, tx, valid)
    else
      sprintf("SELECT tm.ds_key, count(DISTINCT t.taxon_authority || ':' || t.taxon_id) AS n_taxa
                 FROM read_parquet('%s') tm JOIN read_parquet('%s') t ON tm.taxon_id = t.taxon_id
                WHERE %s GROUP BY 1", tm, tx, valid)
    cached <<- tryCatch(DBI::dbGetQuery(.doc_con(), sql), error = function(e) data.frame())
    cached
  }
})

#' This version's `dataset` table, with `is_scored` guaranteed.
#'
#' `is_scored` distinguishes datasets that fed the scores from ones merely
#' registered — v8 ingests `gm` + `nc` but excludes them from the merge, so the
#' registry reads as 11 inputs where 8 produced the numbers. v8 now stamps the
#' column; earlier releases get it derived from their own `taxon_model` edges by
#' the same msens rule.
doc_datasets <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)
    d  <- doc_tbl("dataset")
    nt <- doc_dataset_taxa()
    d$n_taxa <- if (nrow(nt)) nt$n_taxa[match(d$ds_key, nt$ds_key)] else NA_integer_
    if (!"is_scored" %in% names(d)) {
      tm_ds <- if (doc_has("taxon_model")) {
        tm <- doc_tbl("taxon_model")
        if ("ds_key" %in% names(tm)) tm$ds_key else NULL
      } else NULL
      d$is_scored <- msens::dataset_is_scored(d$ds_key, tm_ds)
    }
    # A dataset that attaches to NO valid taxon contributed nothing, whatever the
    # registry says. This is stricter than "has an edge" and it is the honest test:
    # v8 registers gm/nc with real models and zero valid-taxon links.
    if (nrow(nt)) {
      contributed <- !is.na(d$n_taxa) & d$n_taxa > 0
      d$is_scored <- d$is_scored & (contributed | d$ds_key == "ms_merge")
    }
    cached <<- d
    d
  }
})

# ---- species categories -------------------------------------------------------

#' Species categories in this release, and whether each is SCORED.
#'
#' "Scored" is introspected, not listed: a category is scored iff the release
#' published an `extrisk_{cat}` metric for it. That distinction is real and it
#' moves between releases — v1 scored `reptile`; v3 onward carry reptile taxa but
#' score none of them, having split sea turtles into their own `turtle` category;
#' v8 drops the `other` bucket entirely and adds `primary_producer`. Reading it
#' from the metric registry means the table cannot claim a category is scored in a
#' release that never produced a metric for it.
doc_sp_cats <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)
    k <- .doc_keys()
    valid <- paste0(k$valid, if (!is.na(k$marine)) paste0(" AND ", k$marine) else "")
    d <- doc_tbl("taxon", sprintf(
      "SELECT sp_cat, count(*) AS n_taxa, sum(CASE WHEN %s THEN 1 ELSE 0 END) AS n_valid
         FROM taxon WHERE sp_cat IS NOT NULL GROUP BY 1 ORDER BY 3 DESC, 2 DESC", valid))
    keys <- tryCatch(doc_tbl("metric", "SELECT DISTINCT metric_key FROM metric")$metric_key,
                     error = function(e) character(0))
    d$scored <- paste0("extrisk_", d$sp_cat) %in% keys
    cached <<- d
    d
  }
})

# ---- the validity funnel ------------------------------------------------------

#' Cumulative effect of each validity gate this release's own columns can express.
#'
#' Deliberately NOT a transcription of the pipeline's internal steps: it applies
#' the gates in order to the release's published `taxon` table and reports what
#' survives. A gate whose column the release does not carry is OMITTED rather than
#' guessed, so the table never implies a filter that version did not apply.
doc_funnel <- function() {
  k    <- .doc_keys()
  cols <- doc_cols("taxon")$column_name
  has  <- function(x) all(x %in% cols)

  # (label, predicate) applied cumulatively; NULL predicate = no filter
  steps <- list(list("Source taxa (all datasets)", NULL))
  if (has("taxon_id"))
    steps <- c(steps, list(list("Resolved to a taxon id", "taxon_id IS NOT NULL")))
  if (has(k$tkey))
    steps <- c(steps, list(list("Has a merged distribution",
                                sprintf("%s IS NOT NULL", k$tkey))))
  ext <- c(if (has("worms_is_extinct")) "coalesce(worms_is_extinct, FALSE) = FALSE",
           if (has("redlist_code")) "coalesce(redlist_code, '') <> 'EX'",
           if (has("iucn_code"))    "coalesce(iucn_code, '') <> 'EX'")
  if (length(ext))
    steps <- c(steps, list(list("Not extinct", paste(ext, collapse = " AND "))))
  if (!is.na(k$marine))
    steps <- c(steps, list(list("Marine (family + percent-marine cull)", k$marine)))
  else if (has("worms_is_marine"))
    # birds are resolved through BirdLife, not WoRMS, so a NULL WoRMS marine flag
    # on a BOTW taxon is "not assessed", not "not marine" — treating it as failure
    # would drop every seabird at this step
    steps <- c(steps, list(list("Marine (WoRMS, or a BirdLife bird)",
      "(coalesce(worms_is_marine, FALSE) OR taxon_authority = 'botw')")))
  where <- character(0); rows <- list()
  for (s in steps) {
    if (!is.null(s[[2]])) where <- c(where, s[[2]])
    n <- doc_tbl("taxon", sprintf("SELECT count(*) AS n FROM taxon%s",
      if (length(where)) paste0(" WHERE ", paste(where, collapse = " AND ")) else ""))$n
    rows[[length(rows) + 1]] <- data.frame(step = s[[1]], remaining = n)
  }

  # The final row is the release's OWN validity flag applied to the whole table,
  # NOT the conjunction of the diagnostic gates above it — because it is not that
  # conjunction. v7's `is_ok` bakes in rules the published columns cannot express,
  # so ANDing it onto the accumulated clause lands 4 short of the release's own
  # answer. A funnel whose last row disagrees with the headline count on the same
  # page is worse than no funnel, so this row is the authority and the assertion
  # below is what keeps it that way.
  auth <- paste0(k$valid, if (!is.na(k$marine)) paste0(" AND ", k$marine) else "")
  n_valid <- doc_tbl("taxon", sprintf("SELECT count(*) AS n FROM taxon WHERE %s", auth))$n
  rows[[length(rows) + 1]] <- data.frame(
    step = sprintf("Valid for scoring (the release's `%s`)", k$valid), remaining = n_valid)

  out <- do.call(rbind, rows)
  stopifnot("funnel does not end at the release's own valid-species count" =
              identical(as.numeric(n_valid), as.numeric(doc_stats()$valid_species)))
  out$removed <- c(0, head(out$remaining, -1) - tail(out$remaining, -1))
  out
}

# ---- the release timeline -----------------------------------------------------

#' One row per published release, for the Releases timeline.
#'
#' Reads EVERY release's manifest and published `taxon` table, not just this
#' build's — which is the point: the comparison is the thing the per-version pages
#' cannot show. Each figure still comes from the release it describes.
#'
#' Deliberately lean: the manifest answers most of it (grid, id field, tables,
#' capabilities, spatial units), so only the species counts need a Parquet read.
doc_releases <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)
    reg <- doc_versions()
    con <- .doc_con()
    rows <- lapply(seq_len(nrow(reg)), function(i) {
      v <- reg$ver[i]
      m <- tryCatch(msens::atlas_manifest(v), error = function(e) NULL)
      if (is.null(m)) return(NULL)
      tb  <- names(m$tables)
      # resolve this release's own column names through the package rule
      for (t in intersect(c("taxon", "model"), tb))
        DBI::dbExecute(con, sprintf(
          "CREATE OR REPLACE TEMP VIEW %s AS SELECT * FROM read_parquet('%s')", t, m$tables[[t]]))
      k <- tryCatch(msens::sdm_cols(con, mc_tbl = NULL), error = function(e) NULL)
      q <- function(sql) tryCatch(DBI::dbGetQuery(con, sql)$n, error = function(e) NA_real_)
      valid <- if (is.null(k)) NA_real_ else q(sprintf(
        "SELECT count(*) n FROM taxon WHERE %s%s", k$valid,
        if (!is.na(k$marine)) paste0(" AND ", k$marine) else ""))
      pra <- if (!"zone_taxon" %in% tb || !isTRUE(m$capabilities$programareas)) NA_real_ else q(sprintf(
        "SELECT count(DISTINCT taxon_authority || ':' || taxon_id) n FROM read_parquet('%s')
          WHERE zone_fld = 'programarea_key'", m$tables[["zone_taxon"]]))
      ds <- tryCatch({
        d <- DBI::dbGetQuery(con, sprintf(
          "SELECT * FROM read_parquet('%s')", m$tables[["dataset"]]))
        tmds <- if ("taxon_model" %in% tb) tryCatch(
          DBI::dbGetQuery(con, sprintf("SELECT DISTINCT ds_key FROM read_parquet('%s')",
                                       m$tables[["taxon_model"]]))$ds_key,
          error = function(e) NULL) else NULL
        sc <- if ("is_scored" %in% names(d)) d$is_scored else
          msens::dataset_is_scored(d$ds_key, tmds)
        sum(sc & d$ds_key != "ms_merge")
      }, error = function(e) NA_real_)
      zn <- m$zones
      unit <- if (is.data.frame(zn) && nrow(zn)) {
        nm <- c(programarea_key = "Program Areas", planarea_key = "Planning Areas",
                ecoregion_key = "Ecoregions", subregion_key = "Subregions")
        paste(sprintf("%s (%s)", nm[zn$fld], zn$n), collapse = ", ")
      } else ""
      data.frame(
        ver = v, status = reg$status[i],
        released = as.character(reg$released[i]),
        title = if ("title" %in% names(reg)) reg$title[i] else "",
        grid = m$grid_id, id_field = m$id_field,
        n_datasets = ds, valid_species = valid, species_pra = pra,
        n_metrics = if (is.data.frame(m$metrics)) length(unique(m$metrics$metric_key)) else NA_real_,
        units = unit, stringsAsFactors = FALSE)
    })
    cached <<- do.call(rbind, Filter(Negate(is.null), rows))
    cached
  }
})

# ---- what changed in this release ---------------------------------------------

#' Curated release bullets (`data/release_notes.yml`), for one version.
doc_release_notes <- local({
  cached <- NULL
  function(ver = doc_ver()) {
    if (is.null(cached)) cached <<- tryCatch(
      yaml::read_yaml(here::here("data/release_notes.yml")), error = function(e) list())
    cached[[ver]]
  }
})

#' Machine-derived difference between a release and the one before it.
#'
#' The counts in the "what changed" callout come from HERE, not from the curated
#' YAML, so a bullet can describe a change while the figures beside it stay tied
#' to the releases themselves. Prose is editorial; numbers are read.
#'
#' Returns `NULL` for the earliest release, which has nothing to differ from.
doc_version_delta <- local({
  cached <- new.env(parent = emptyenv())
  function(ver = doc_ver()) {
    if (!is.null(cached[[ver]])) return(cached[[ver]])
    rel <- doc_releases()                      # newest first
    i   <- match(ver, rel$ver)
    if (is.na(i) || i >= nrow(rel)) return(NULL)
    prev <- rel[i + 1, ]; this <- rel[i, ]

    ds <- function(v) {
      m <- tryCatch(msens::atlas_manifest(v), error = function(e) NULL)
      if (is.null(m) || !"dataset" %in% names(m$tables)) return(character(0))
      d <- tryCatch(DBI::dbGetQuery(.doc_con(), sprintf(
        "SELECT * FROM read_parquet('%s')", m$tables[["dataset"]])), error = function(e) NULL)
      if (is.null(d)) return(character(0))
      tm <- if ("taxon_model" %in% names(m$tables)) tryCatch(
        DBI::dbGetQuery(.doc_con(), sprintf("SELECT DISTINCT ds_key FROM read_parquet('%s')",
                                            m$tables[["taxon_model"]]))$ds_key,
        error = function(e) NULL) else NULL
      keep <- if ("is_scored" %in% names(d)) d$is_scored else
        msens::dataset_is_scored(d$ds_key, tm)
      # normalise the AquaMaps key so `am_0.05` -> `am` is not reported as a
      # dataset being dropped and another added
      sort(unique(msens::normalize_ds_key(d$ds_key[keep & d$ds_key != "ms_merge"])))
    }
    a <- ds(prev$ver); b <- ds(this$ver)
    out <- list(
      prev = prev$ver,
      added = setdiff(b, a), removed = setdiff(a, b),
      valid_prev = prev$valid_species, valid_this = this$valid_species,
      grid_changed = !identical(prev$grid, this$grid),
      grid_prev = prev$grid, grid_this = this$grid,
      id_changed = !identical(prev$id_field, this$id_field),
      id_prev = prev$id_field, id_this = this$id_field,
      units_changed = !identical(prev$units, this$units))
    cached[[ver]] <- out
    out
  }
})

#' Per-zone score change between a release and the one before it, all metrics.
#'
#' Answers "what did this release actually move", which the species count cannot:
#' v4b, v5 and v4 all report an unchanged 9,795 valid species while changing the
#' values substantially.
#'
#' Choosing the spatial unit is the whole problem. It must be one BOTH releases
#' scored, on the same geometry vintage, **and** with the same member keys — the
#' three tests are not redundant. Every release resolves `subregion_key` to the
#' same vintage while meaning different things by it (v1 `AKL48`, v7 `FULL`, v8
#' `AT`), so a vintage check alone would report a delta for a redefinition.
#' Program Areas are the preferred unit and are genuinely stable — one geometry
#' hash and the same 20 keys across v2–v8 — but v1 has none, so v1→v2 falls back
#' to Planning Areas, and ecoregions are the last resort since all nine share them.
doc_score_delta <- local({
  cached <- new.env(parent = emptyenv())
  function(ver = doc_ver()) {
    if (!is.null(cached[[ver]])) return(cached[[ver]])
    rel <- doc_releases(); i <- match(ver, rel$ver)
    if (is.na(i) || i >= nrow(rel)) return(NULL)
    prev <- rel$ver[i + 1]

    scores <- function(v, fld) {
      m <- tryCatch(msens::atlas_manifest(v), error = function(e) NULL)
      if (is.null(m) || !all(c("zone", "zone_metric", "metric") %in% names(m$tables))) return(NULL)
      zc <- DBI::dbGetQuery(.doc_con(), sprintf(
        "DESCRIBE SELECT * FROM read_parquet('%s')", m$tables[["zone"]]))$column_name
      vc <- if ("value" %in% zc) "value" else "val"
      mm <- DBI::dbGetQuery(.doc_con(), sprintf(
        "DESCRIBE SELECT * FROM read_parquet('%s')", m$tables[["zone_metric"]]))$column_name
      sc <- if ("value" %in% mm) "value" else "val"
      tryCatch(DBI::dbGetQuery(.doc_con(), sprintf(
        "SELECT z.%s AS zone_key, mt.metric_key, zm.%s AS score
           FROM read_parquet('%s') z
           JOIN read_parquet('%s') zm USING (zone_seq)
           JOIN read_parquet('%s') mt USING (metric_seq)
          WHERE z.fld = '%s'",
        vc, sc, m$tables[["zone"]], m$tables[["zone_metric"]], m$tables[["metric"]], fld)),
        error = function(e) NULL)
    }
    zset <- function(v) {
      z <- tryCatch(msens::atlas_manifest(v)$zones, error = function(e) NULL)
      if (!is.data.frame(z) || !nrow(z)) return(NULL)
      stats::setNames(if ("zone_set_key" %in% names(z)) z$zone_set_key else rep(NA, nrow(z)), z$fld)
    }
    za <- zset(prev); zb <- zset(ver)
    if (is.null(za) || is.null(zb)) return(NULL)

    for (fld in c("programarea_key", "planarea_key", "ecoregion_key")) {
      if (!fld %in% names(za) || !fld %in% names(zb)) next
      if (!identical(za[[fld]], zb[[fld]])) next            # different vintage
      a <- scores(prev, fld); b <- scores(ver, fld)
      if (is.null(a) || is.null(b) || !nrow(a) || !nrow(b)) next
      # and the member keys must actually match, whatever the vintage says
      if (!identical(sort(unique(a$zone_key)), sort(unique(b$zone_key)))) next
      d <- msens::zone_score_delta(a, b, labels = c(prev, ver))
      d$fld <- fld; d$zone_set_key <- unname(zb[[fld]]); d$prev <- prev
      cached[[ver]] <- d
      return(d)
    }
    NULL
  }
})

#' Which spatial units this release actually REPORTS scores on.
#'
#' Not the same question as which zones exist. v3–v7 all carry the 36 Planning
#' Areas in `zone`, with a couple of non-composite metrics attached, and compute a
#' composite score for none of them — the geometry is history, not a reporting
#' unit. Reading "has zones" as "reports scores" is what let the application offer
#' a Program Areas view of v1, which has no Program Areas at all, and draw an
#' empty map with an `Inf`/`-Inf` legend.
#'
#' Measured on the composite metric, which is the score the maps and reports show.
doc_scored_units <- local({
  cached <- new.env(parent = emptyenv())
  function(ver = doc_ver()) {
    if (!is.null(cached[[ver]])) return(cached[[ver]])
    m <- tryCatch(msens::atlas_manifest(ver), error = function(e) NULL)
    if (is.null(m) || !all(c("zone", "zone_metric", "metric") %in% names(m$tables)))
      return(NULL)
    sc <- DBI::dbGetQuery(.doc_con(), sprintf(
      "DESCRIBE SELECT * FROM read_parquet('%s')", m$tables[["zone_metric"]]))$column_name
    val <- if ("value" %in% sc) "value" else "val"
    out <- tryCatch(DBI::dbGetQuery(.doc_con(), sprintf(
      "SELECT z.fld, count(*) AS n
         FROM read_parquet('%s') z
         JOIN read_parquet('%s') zm USING (zone_seq)
         JOIN read_parquet('%s') mt USING (metric_seq)
        WHERE mt.metric_key LIKE 'score!_%%' ESCAPE '!'
        GROUP BY 1 HAVING count(*) > 0 ORDER BY 2 DESC",
      m$tables[["zone"]], m$tables[["zone_metric"]], m$tables[["metric"]])),
      error = function(e) NULL)
    cached[[ver]] <- out
    out
  }
})

#' Render the standardized "what changed" callout for this release.
doc_changes_callout <- function(ver = doc_ver()) {
  n <- doc_release_notes(ver)
  if (is.null(n)) return(invisible(NULL))
  d <- doc_version_delta(ver)
  row <- doc_version_row(ver)
  ttl <- if (isTRUE(n$basis)) sprintf("%s — the basis everything since builds on", ver)
         else sprintf("What changed in %s%s", ver,
                      if (!is.null(d)) sprintf(", relative to %s", d$prev) else "")

  # `note` (blue/info), not `important` (red): this is orientation for every
  # reader arriving on the page, not a warning about something wrong.
  cat("::: {.callout-note}\n## ", ttl, "\n\n", sep = "")
  if (nrow(row) && nzchar(as.character(row$title)))
    cat("*", as.character(row$title), "*\n\n", sep = "")

  lab <- c(datasets = "Datasets", methods = "Methods", zones = "Reported units",
           scope = "Scope", technology = "Technology")
  for (k in names(lab)) {
    if (is.null(n[[k]])) next
    cat("**", lab[[k]], "** — ", trimws(n[[k]]), sep = "")
    # the measured units sit with the prose that describes them
    if (k == "zones") {
      u <- doc_scored_units(ver)
      if (!is.null(u) && nrow(u))
        cat(" *(measured: ",
            paste(sprintf("%s %s", n_fmt(u$n), sub("_key$", "", u$fld)), collapse = ", "),
            " scored on the composite metric.)*", sep = "")
    }
    cat("\n\n")
  }

  # the measured facts, so the prose above is never the only account
  if (!is.null(d)) {
    bits <- c(
      if (length(d$added))   sprintf("datasets added: %s", paste0("`", d$added, "`", collapse = ", ")),
      if (length(d$removed)) sprintf("datasets no longer contributing: %s",
                                     paste0("`", d$removed, "`", collapse = ", ")),
      if (!is.na(d$valid_prev) && !is.na(d$valid_this))
        sprintf("valid species %s → %s", n_fmt(d$valid_prev), n_fmt(d$valid_this)),
      if (isTRUE(d$grid_changed)) sprintf("**grid changed** (`%s` → `%s`), so `cell_id` denotes a different place",
                                          d$grid_prev, d$grid_this),
      if (isTRUE(d$id_changed))   sprintf("public model id `%s` → `%s`", d$id_prev, d$id_this),
      if (isTRUE(d$units_changed)) "spatial units changed")
    if (length(bits))
      cat("*Measured against ", d$prev, ": ", paste(bits, collapse = "; "), ".*\n\n", sep = "")
  }
  cat(":::\n\n")
  invisible(NULL)
}

# ---- formatting ---------------------------------------------------------------

#' Integer with thousands separator: 16153 -> "16,153". Vectorised.
#'
#' Anything not a finite number renders as a VISIBLE placeholder rather than
#' `NA` — the point being that a reader can see a figure is missing for this
#' release, instead of it silently reading as a real value.
n_fmt <- function(x) {
  if (!length(x)) return(character(0))
  v <- suppressWarnings(as.numeric(x))
  ifelse(is.na(v) | !is.finite(v),
         "[not published for this version]",
         formatC(as.integer(v), format = "d", big.mark = ","))
}

#' A statistic for this version, formatted — or a VISIBLE placeholder.
#'
#' Never a number borrowed from another release: an obviously-missing figure is
#' recoverable, a plausible wrong one is not.
doc_stat <- function(key) {
  s <- doc_stats()
  if (!key %in% names(s)) return("[unknown statistic]")
  v <- s[[key]]
  if (is.character(v)) v else n_fmt(v)
}

# ---- zone geometry (PMTiles), by vintage --------------------------------------

#' PMTiles URL for a spatial unit in THIS version, from the manifest.
#'
#' Replaces `ver <- "v4"` in functions.R, which drew v4 outlines on every build
#' regardless of the version being documented. `zone_set_key` is a VINTAGE, so one
#' tileset legitimately serves several releases — which is why the manifest, not
#' the version string, is the right source.
doc_zone_pmtiles <- function(fld) {
  z <- doc_manifest()$zones
  if (!is.data.frame(z) || !nrow(z) || !"pmtiles" %in% names(z)) return(NA_character_)
  i <- match(fld, z$fld)
  if (is.na(i)) return(NA_character_)
  z$pmtiles[i]
}

#' Spatial units this version scored, as a data frame (`fld`, `n`, `pmtiles`).
doc_zones <- function() {
  z <- doc_manifest()$zones
  if (is.data.frame(z)) z else data.frame()
}

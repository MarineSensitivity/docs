# stats.R — current Marine Sensitivity Toolkit species & zone counts, pulled live from the
# API (https://api.marinesensitivity.org/stats.json) so the docs render the actual numbers
# for the current database version. If the API is unreachable at render time, falls back to
# the last-known values so the build still succeeds.
#
# Usage in a .qmd (hidden setup chunk):
#   source(here::here("stats.R"))
# then inline, e.g.:  `r n_fmt(mst_stats$valid_species)` valid marine species

mst_stats <- local({
  fallback <- list(
    version                 = "v7",
    total_taxa              = 17561L,
    valid_species           = 16153L,
    species_full_study_area = 16153L,
    species_program_areas   = 9230L,
    n_program_areas         = 20L,
    n_ecoregions            = 12L,
    n_datasets              = 9L,
    n_cells                 = 662075L,
    funnel = data.frame(
      step      = 1:8,
      filter    = c("Source taxa (all datasets)", "Resolved taxon ID",
                    "Has a merged model (distribution)", "Not extinct", "Marine",
                    "Accepted taxonomy (excl. non-turtle reptiles)",
                    "Mapped to ≥1 cell — valid (is_ok)",
                    "Within BOEM Program Areas (spatial subset)"),
      remaining = c(17561L, 17561L, 16388L, 16367L, 16213L, 16158L, 16153L, 9230L),
      removed   = c(0L, 0L, 1173L, 21L, 154L, 55L, 5L, 6923L)))
  out <- tryCatch(
    jsonlite::fromJSON("https://api.marinesensitivity.org/stats.json"),
    error   = function(e) NULL,
    warning = function(w) NULL)
  if (is.null(out) || is.null(out$valid_species)) fallback else utils::modifyList(fallback, out)
})

# integer with thousands separator, e.g. 16153 -> "16,153"
n_fmt <- function(x) formatC(as.integer(x), format = "d", big.mark = ",")

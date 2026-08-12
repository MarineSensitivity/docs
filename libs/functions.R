# helper functions
# initiated by .Rprofile (after libs/versioned.R, whose doc_* helpers this uses)
#
# There used to be a `ver <- "v4"` here, and a `ver = "v4"` default on
# map_ecoregions(). It was the second of four competing version constants in the
# book, and the one with visual consequences: whatever release a build claimed to
# document, the maps drew v4's ecoregion and Program-Area outlines. Geometry now
# comes from the manifest of the version being documented — via its zone_set_key,
# a VINTAGE, so one tileset legitimately serves several releases.

g <- function(x){
  # glossary term
  if (knitr::is_html_output())
    return("")
  x
}

map_ecoregions <- function() {
  # Interactive map of BOEM Ecoregions — plus Program Area outlines for the
  # releases that HAVE Program Areas. v1 scored Planning Areas and declares
  # `capabilities.programareas = FALSE`, so drawing the 2026 Program Areas there
  # would put entirely plausible, entirely wrong boundaries under a v1 heading.
  # The ecoregions themselves are byte-identical across v1-v8, so the map still
  # renders; only the Program Area layers drop out.

  ver     <- doc_ver()
  has_pra <- doc_can("programareas")

  # read ecoregion and program area polygons from gpkg
  # use local data/ folder (for GitHub Actions) vs shared drives
  er_local  <- here::here("data/ply_ecoregions_2025.gpkg")
  pra_local <- here::here(glue::glue("data/ply_programareas_2026_{ver}.gpkg"))
  # the Program-Area geometry is shared across releases (the zone registry
  # measures ONE geometry, `programarea_2026-01`, covering v2-v8), so fall back to
  # whichever vintage is checked in rather than 404ing on a per-version filename
  # that was never written
  if (!file.exists(pra_local)) {
    cand <- sort(Sys.glob(here::here("data/ply_programareas_2026_v*.gpkg")), decreasing = TRUE)
    if (length(cand)) pra_local <- cand[1]
  }
  if (file.exists(er_local)) {
    er_gpkg  <- er_local
    pra_gpkg <- pra_local
  } else {
    dir_data <- ifelse(
      Sys.info()[["sysname"]] == "Linux",
      "/share/data",
      "~/My Drive/projects/msens/data")
    dir_v    <- glue::glue("{dir_data}/derived/{ver}")
    er_gpkg  <- glue::glue("{dir_v}/ply_ecoregions_2025.gpkg")
    pra_gpkg <- glue::glue("{dir_v}/ply_programareas_2026_{ver}.gpkg")
  }
  if (!file.exists(er_gpkg)) return(invisible(NULL))
  has_pra <- has_pra && file.exists(pra_gpkg)

  er  <- sf::read_sf(er_gpkg)
  pra <- if (has_pra) sf::read_sf(pra_gpkg) else NULL

  # colour the ecoregions this release actually works in: the ones its Program
  # Areas touch, or all of them when it has none
  if (has_pra) {
    sf::sf_use_s2(FALSE)
    n_intersects <- lengths(sf::st_intersects(er, pra))
    sf::sf_use_s2(TRUE)
  } else {
    n_intersects <- rep(1L, nrow(er))
  }

  er_pra <- er |>
    sf::st_drop_geometry() |>
    dplyr::filter(n_intersects > 0) |>
    dplyr::select(ecoregion_key, ecoregion_name) |>
    dplyr::arrange(ecoregion_key)

  eco_keys  <- er_pra$ecoregion_key
  eco_names <- er_pra$ecoregion_name

  # spectral palette matched to number of intersecting ecoregions
  n_eco <- length(eco_keys)
  set.seed(42)
  eco_colors <- sample(
    rev(RColorBrewer::brewer.pal(
      max(n_eco, 3), "Spectral"))[seq_len(n_eco)])

  # PMTiles from THIS version's manifest, keyed by zone_set_key (a VINTAGE), not
  # from a hardcoded /pmtiles/{ver}/ path on the file host.
  #
  # The layer id inside the published tiles is the zone TYPE (`ecoregion`), not
  # the source table name, so URL and source_layer must move together: the new URL
  # with the old layer name renders a silently EMPTY overlay, no error. Same trap
  # the scores app documents at apps/scores/app.R.
  host    <- "https://file.marinesensitivity.org/pmtiles"
  url_eco <- doc_zone_pmtiles("ecoregion_key")
  url_pra <- doc_zone_pmtiles("programarea_key")
  lyr_eco <- "ecoregion"
  lyr_pra <- "programarea"
  if (is.na(url_eco)) {
    url_eco <- glue::glue("{host}/{ver}/ply_ecoregions_2025.pmtiles")
    lyr_eco <- "ply_ecoregions_2025"
  }
  if (is.na(url_pra)) {
    url_pra <- glue::glue("{host}/{ver}/ply_programareas_2026.pmtiles")
    lyr_pra <- "ply_programareas_2026"
  }

  # base map
  base <- mapgl::maplibre(
    style  = mapgl::carto_style("voyager"),
    bounds = list(c(-190, 15), c(-60, 75)))

  eco_filter <- c("in", "ecoregion_key", eco_keys)

  # build the map using composable helpers
  m <- base |>
    msens::add_pmfill(
      url           = url_eco,
      source_layer  = lyr_eco,
      col_key       = "ecoregion_key",
      colors        = stats::setNames(eco_colors, eco_keys),
      filter_keys   = eco_keys,
      fill_opacity  = 0.6,
      outline_color = "black",
      outline_width = 3,
      tooltip       = mapgl::concat(
        mapgl::get_column("ecoregion_name"),
        " (", mapgl::get_column("ecoregion_key"), ")"),
      # only `{type}_key` + `{type}_name` survive into the published zone tiles
      # (build_zone_sets.qmd keeps exactly those), so the old "Region:" line —
      # which read `region_name` — would render blank on every version now that
      # the tiles come from the manifest
      popup         = mapgl::concat(
        "<strong>", mapgl::get_column("ecoregion_name"), "</strong><br>",
        "Key: ",    mapgl::get_column("ecoregion_key")),
      hover_options = list(fill_opacity = 0.9)) |>
    # ecoregion labels from PMTile features (bold black)
    mapgl::add_symbol_layer(
      id           = "eco_lbl",
      source       = "main_src",
      source_layer = lyr_eco,
      text_field   = mapgl::get_column("ecoregion_key"),
      text_size    = 14,
      text_font    = list("Open Sans Bold"),
      text_color   = "black",
      text_halo_color = "white",
      text_halo_width = 2,
      text_allow_overlap = FALSE,
      filter       = eco_filter)

  # Program Area outlines + labels only where the release HAS Program Areas.
  # Added as a separate step, not a conditional inside one pipe, because a
  # symbol layer naming a source that was never created renders nothing at all —
  # silently, exactly like a wrong source_layer.
  if (has_pra)
    m <- m |>
      msens::add_pmline(list(
        list(url = url_pra, source_layer = lyr_pra,
             id = "pra_ln", source_id = "pra_src",
             line_color = "white", line_width = 1))) |>
      mapgl::add_symbol_layer(
        id           = "pra_lbl",
        source       = "pra_src",
        source_layer = lyr_pra,
        text_field   = mapgl::get_column("programarea_key"),
        text_size    = 11,
        text_font    = list("Open Sans Semibold"),
        text_color   = "#333333",
        text_halo_color = "white",
        text_halo_width = 1.5,
        text_allow_overlap = FALSE)

  m <- m |>
    mapgl::add_layers_control(
      layers = c(
        list("Ecoregion fills"    = "main_fill",
             "Ecoregion outlines" = "main_ln",
             "Ecoregion labels"   = "eco_lbl"),
        if (has_pra) list("Program Area outlines" = "pra_ln",
                          "Program Area labels"   = "pra_lbl"))) |>
    mapgl::add_fullscreen_control() |>
    mapgl::add_categorical_legend(
      legend_title = "BOEM Ecoregions",
      values       = eco_names,
      colors       = eco_colors,
      position     = "bottom-left")

  # html output: return interactive widget
  if (knitr::is_html_output())
    return(m)

  # non-html output: generate static png via webshot2 if missing, then include
  img <- here::here("figures/map-ecoregions-static.png")
  if (!file.exists(img)) {
    tmp_html <- tempfile(fileext = ".html")
    htmlwidgets::saveWidget(m, tmp_html, selfcontained = TRUE)
    webshot2::webshot(tmp_html, img, vwidth = 1200, vheight = 700, delay = 15)
    unlink(tmp_html)
  }
  knitr::include_graphics(img)
}

caption_ecoregions <- function() {
  # Key-to-name legend for the ecoregion map.
  #
  # This used to read a `.ecoregions_caption` global that map_ecoregions() wrote
  # with `<<-`, which made the caption ORDER-DEPENDENT: Quarto evaluates the
  # `fig-cap: !expr` before the chunk body on some paths, so the caption could
  # come from whichever chapter last drew a map — or error outright on the first.
  # It now derives the same lookup from the same source, independently.
  z <- .zone_names()
  if (!length(z$eco)) return("BOEM Ecoregions (colored) and Program Area outlines.")
  paste0(
    "BOEM Ecoregions (colored) and Program Area outlines. ",
    "**Ecoregion keys**: ", z$eco, ".",
    if (nzchar(z$pra)) paste0(" **Program Area keys**: ", z$pra, ".") else "")
}

# key = name lookups for the version being documented, memoised so the caption and
# the map do not read the geopackages twice
.zone_names <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)
    out <- list(eco = "", pra = "")
    er_gpkg <- here::here("data/ply_ecoregions_2025.gpkg")
    if (file.exists(er_gpkg)) {
      er <- sf::st_drop_geometry(sf::read_sf(er_gpkg))
      er <- er[order(er$ecoregion_key), ]
      out$eco <- paste(er$ecoregion_key, "=", er$ecoregion_name, collapse = "; ")
    }
    if (doc_can("programareas")) {
      pra_gpkg <- sort(Sys.glob(here::here("data/ply_programareas_2026_v*.gpkg")),
                       decreasing = TRUE)
      if (length(pra_gpkg)) {
        pr <- sf::st_drop_geometry(sf::read_sf(pra_gpkg[1]))
        pr <- pr[order(pr$programarea_key), ]
        out$pra <- paste(pr$programarea_key, "=", pr$programarea_name, collapse = "; ")
      }
    }
    cached <<- out
    out
  }
})

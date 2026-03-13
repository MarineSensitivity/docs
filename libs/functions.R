# helper functions
# initiated by .Rprofile

ver <- "v4"

g <- function(x){
  # glossary term
  if (knitr::is_html_output())
    return("")
  x
}

map_ecoregions <- function(ver="v4") {
  # interactive map of BOEM ecoregions and program areas

  # librarian::shelf(
  #   dplyr,
  #   gh,
  #   glue,
  #   here,
  #   knitr,
  #   librarian,
  #   mapgl,
  #   quarto,
  #   RColorBrewer,
  #   stringr,
  #   tidyjson,
  #   yaml)
  # ver="v4"

  # read ecoregion and program area polygons from gpkg
  # use local data/ folder (for GitHub Actions) vs shared drives
  er_local  <- here::here("data/ply_ecoregions_2025.gpkg")
  pra_local <- here::here(glue::glue("data/ply_programareas_2026_{ver}.gpkg"))
  if (file.exists(er_local) && file.exists(pra_local)) {
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

  er  <- sf::read_sf(er_gpkg)
  pra <- sf::read_sf(pra_gpkg)

  # find ecoregions that intersect with program areas
  sf::sf_use_s2(FALSE)
  n_intersects <- lengths(sf::st_intersects(er, pra))
  sf::sf_use_s2(TRUE)

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

  # pmtiles urls (unversioned — scores joined at render time)
  url_eco <- glue::glue("https://file.marinesensitivity.org/pmtiles/{ver}/ply_ecoregions_2025.pmtiles")
  url_pra <- glue::glue("https://file.marinesensitivity.org/pmtiles/{ver}/ply_programareas_2026.pmtiles")
  lyr_eco <- "ply_ecoregions_2025"
  lyr_pra <- "ply_programareas_2026"

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
      popup         = mapgl::concat(
        "<strong>", mapgl::get_column("ecoregion_name"), "</strong><br>",
        "Key: ",    mapgl::get_column("ecoregion_key"), "<br>",
        "Region: ", mapgl::get_column("region_name")),
      hover_options = list(fill_opacity = 0.9)) |>
    msens::add_pmline(list(
      list(url = url_pra, source_layer = lyr_pra,
           id = "pra_ln", source_id = "pra_src",
           line_color = "white", line_width = 1))) |>
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
      filter       = eco_filter) |>
    # program area labels from PMTile features
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
      text_allow_overlap = FALSE) |>
    mapgl::add_layers_control(
      layers = list(
        "Ecoregion fills"       = "main_fill",
        "Ecoregion outlines"    = "main_ln",
        "Ecoregion labels"      = "eco_lbl",
        "Program Area outlines" = "pra_ln",
        "Program Area labels"   = "pra_lbl")) |>
    mapgl::add_fullscreen_control() |>
    mapgl::add_categorical_legend(
      legend_title = "BOEM Ecoregions",
      values       = eco_names,
      colors       = eco_colors,
      position     = "bottom-left")

  # build caption with key-to-name lookup
  eco_lookup <- paste(
    eco_keys, "=", eco_names, collapse = "; ")
  pra_info <- pra |>
    sf::st_drop_geometry() |>
    dplyr::select(programarea_key, programarea_name) |>
    dplyr::arrange(programarea_key)
  pra_lookup <- paste(
    pra_info$programarea_key, "=", pra_info$programarea_name,
    collapse = "; ")

  # store caption for retrieval by caption_ecoregions()
  .ecoregions_caption <<- list(
    eco = eco_lookup,
    pra = pra_lookup)

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
  # build caption after map_ecoregions() has been called
  cap <- .ecoregions_caption
  paste0(
    "BOEM Ecoregions (colored) and Program Area outlines. ",
    "**Ecoregion keys**: ", cap$eco, ". ",
    "**Program Area keys**: ", cap$pra, ".")
}

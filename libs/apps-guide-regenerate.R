# apps-guide-regenerate.R ----
# regenerate the assets behind apps-guide.qmd:
#   1. parse the in-app Conductor tours straight out of each app's app.R
#   2. for every tour step, inject a spotlight highlight box around the same
#      CSS element the tour points at, then screenshot the viewport
#   3. write figures/apps-guide/<app>-NN.png and a steps.json manifest
#
# run this manually whenever the in-app tours change. it is NOT part of the
# quarto pre-render (it needs the sibling `apps` repo checked out AND the live
# apps reachable at the urls below). apps-guide.qmd renders from the committed
# manifest + pngs, so a plain `quarto render` never needs any of this.
#
#   Rscript libs/apps-guide-regenerate.R
#
# note: we drive chromote directly (webshot2's own engine) rather than
# webshot2::webshot(), because webshot2 has no hook to run javascript before
# the capture and we need that to draw the highlight box. the resulting pngs
# are plain raster images, so they work in every quarto format (html/pdf/docx).

librarian::shelf(chromote, jsonlite, here, glue, fs, png, quiet = TRUE)

`%||%` <- function(a, b) if (is.null(a)) b else a

# config ----
# sibling apps repo; override with MSENS_APPS_DIR if checked out elsewhere.
apps_dir <- Sys.getenv(
  "MSENS_APPS_DIR",
  unset = normalizePath(file.path(here::here(), "..", "apps"), mustWork = FALSE))

# urls are the live, deployed apps. verify these match the current deploy.
apps <- list(
  scores = list(
    name  = "Scores",
    app_r = file.path(apps_dir, "mapgl", "app.R"),
    url   = "https://app.marinesensitivity.org/scores/"),
  species = list(
    name  = "Species",
    app_r = file.path(apps_dir, "mapsp", "app.R"),
    url   = "https://app.marinesensitivity.org/species/"))

fig_dir  <- here::here("figures", "apps-guide")
manifest <- file.path(fig_dir, "steps.json")
fs::dir_create(fig_dir)

vwidth   <- 1280
vheight  <- 860
connect      <- 5      # base seconds for the app to boot before doing anything
net_stable   <- 5      # seconds of no new network requests = map tiles done loading
net_max      <- 35     # cap on the network-idle wait
max_wait     <- 25     # extra seconds to poll for a slow-rendering target element
post_click   <- 8      # floor after activating a tab/sidebar (websocket content)
paint        <- 2      # final buffer so freshly rendered content paints
max_attempts <- 6      # the score raster paints only ~40% of loads (mapbox race),
cell_thresh  <- 0.015  # so retry a fresh session until colored cells exceed this
                       # fraction of the map area (empty maps measure ~0.005)

# extract_steps: parse Conductor tour steps from an app.R ----
# the tours are written as a chained Conductor$new()$step(...)$step(...). we
# walk the parse tree, find each step() call (whose function position is the
# `$`(receiver, step) selector), and pull its named literal args in source
# order by recursing into the receiver before recording the current step.
extract_steps <- function(app_r) {
  exprs <- parse(app_r, keep.source = FALSE)

  is_step <- function(e)
    is.call(e) && is.call(e[[1]]) && length(e[[1]]) == 3L &&
    identical(e[[1]][[1]], as.name("$")) &&
    identical(e[[1]][[3]], as.name("step"))

  out <- list()
  rec <- function(e) {
    if (!is_step(e)) return(invisible())
    rec(e[[1]][[2]])                 # earlier steps live in the receiver
    args <- as.list(e)[-1]
    grab <- function(nm)
      if (nm %in% names(args))
        tryCatch(eval(args[[nm]]), error = function(...) NA_character_)
      else NA_character_
    out[[length(out) + 1]] <<- list(
      title    = grab("title"),
      text     = grab("text"),
      selector = grab("el"),
      position = grab("position"))
  }
  walk <- function(e) {
    if (is_step(e)) { rec(e); return(invisible()) }
    if (!is.call(e)) return(invisible())
    # recurse into children; tryCatch swallows empty argument slots (e.g. x[]
    # or foo(,)), whose empty symbol errors the instant it is forced
    for (p in as.list(e)) tryCatch(walk(p), error = function(...) NULL)
  }
  for (ex in exprs) walk(ex)
  out
}

# dismiss_modal_js: fallback to clear the welcome splash ----
# the ?splash=false url flag (above) is the primary suppression; this strips
# any lingering modal + backdrop for deploys that predate that flag, so the
# screenshots always show the actual interface.
dismiss_modal_js <- "
  (function(){
    document.querySelectorAll('.modal, .modal-backdrop').forEach(function(e){ e.remove(); });
    document.body.classList.remove('modal-open');
    document.body.style.overflow = ''; document.body.style.paddingRight = '';
    return 'OK';
  })();"

# highlight_js: spotlight the tour's css selector ----
# draws a red outline around the element and dims everything else via a giant
# box-shadow, mirroring the visual emphasis of the live conductor tour.
highlight_js <- function(selector) {
  sel <- gsub("'", "\\\\'", gsub("\\\\", "\\\\\\\\", selector))
  glue::glue("
    (function() {
      var el = document.querySelector('<<sel>>');
      if (!el) return 'NOT_FOUND';
      el.scrollIntoView({block:'center', inline:'center'});
      var r = el.getBoundingClientRect(), pad = 6;
      var box = document.createElement('div'), s = box.style;
      s.position='fixed';
      s.left=(r.left-pad)+'px'; s.top=(r.top-pad)+'px';
      s.width=(r.width+2*pad)+'px'; s.height=(r.height+2*pad)+'px';
      s.border='4px solid #ff3b30'; s.borderRadius='6px';
      s.boxShadow='0 0 0 9999px rgba(0,0,0,0.35)';
      s.zIndex='2147483647'; s.pointerEvents='none';
      document.body.appendChild(box);
      return 'OK';
    })();",
    .open = "<<", .close = ">>")
}

# has_selector: TRUE once the element exists in the live DOM ----
has_selector <- function(b, selector) {
  sel <- gsub("'", "\\\\'", gsub("\\\\", "\\\\\\\\", selector))
  isTRUE(b$Runtime$evaluate(
    glue::glue("!!document.querySelector('<<sel>>')",
               .open = "<<", .close = ">>"))$result$value)
}

# wait_net_idle: block until map tiles stop loading ----
# mapbox raster tiles (the score cells / SDM) load over http and are flaky —
# a fixed delay catches them in some sessions but not others. instead poll the
# resource-timing entry count and return once it has been unchanged for
# `net_stable` seconds (tiles done) or `net_max` is hit.
wait_net_idle <- function(b, stable_for = net_stable, timeout = net_max) {
  b$Runtime$evaluate("try{performance.setResourceTimingBufferSize(5000)}catch(e){}")
  count <- function()
    b$Runtime$evaluate("performance.getEntriesByType('resource').length")$result$value
  prev <- -1L; stable <- 0; waited <- 0
  repeat {
    n <- count()
    stable <- if (isTRUE(n == prev)) stable + 1 else 0
    prev <- n
    if (stable >= stable_for || waited >= timeout) break
    Sys.sleep(1); waited <- waited + 1
  }
  invisible(waited)
}

# is_activator: does clicking this element reveal content worth showing? ----
# tab nav-links switch the visible panel; the sidebar collapse toggle opens
# the sidebar. we click these before capturing so the screenshot shows the
# resulting content (flower plot, species table, report form, species info).
# other targets (dropdowns, map zoom/fullscreen) are left alone — clicking
# them would open a menu or change the view.
is_activator <- function(selector)
  grepl("nav-link", selector, fixed = TRUE) ||
  grepl("collapse-toggle", selector, fixed = TRUE)

# click_js: click the selector (used to activate tabs / open the sidebar) ----
click_js <- function(selector) {
  sel <- gsub("'", "\\\\'", gsub("\\\\", "\\\\\\\\", selector))
  glue::glue("
    (function(){
      var el = document.querySelector('<<sel>>');
      if (!el) return 'NOT_FOUND';
      el.click();
      return 'OK';
    })();",
    .open = "<<", .close = ">>")
}

# has_text: TRUE once an element has rendered visible text ----
# used to wait out outputs that are suspended while hidden (e.g. the species
# info panel, which only renders ~6s after its sidebar is opened).
has_text <- function(b, selector) {
  sel <- gsub("'", "\\\\'", gsub("\\\\", "\\\\\\\\", selector))
  n <- b$Runtime$evaluate(glue::glue(
    "(function(){var e=document.querySelector('<<sel>>');
       return e ? e.innerText.trim().length : 0;})()",
    .open = "<<", .close = ">>"))$result$value
  isTRUE(n > 0)
}

# highlight_target: what to box after activating ----
# the opened sidebar (showing the species info) rather than its tiny toggle;
# tabs box the tab itself, with the revealed panel visible below.
highlight_target <- function(selector)
  if (grepl("collapse-toggle", selector, fixed = TRUE)) "aside.sidebar" else selector

# content_target: element whose text must appear before capture, or NA ----
content_target <- function(selector)
  if (grepl("collapse-toggle", selector, fixed = TRUE)) "#species_info" else NA_character_

# needs_cells: should this step show a colored cell raster? ----
# every step shows the cell map except the Scores tabs that switch away from
# it (the flower plot, the species table) or to a different outline-only map
# (the report builder). only these get the render check + retry.
needs_cells <- function(selector)
  !grepl("Plot of Scores|Table of Species|Report", selector)

# colored_frac: fraction of the map area painted with saturated cell color ----
# reads the captured png bytes directly; near-empty maps (basemap + outlines
# only) measure ~0.005, a rendered cell raster measures >0.03.
colored_frac <- function(bytes) {
  a  <- png::readPNG(bytes)
  w  <- dim(a)[2]; x0 <- round(w * 0.30)   # map area is the right ~70%
  r  <- a[, x0:w, 1]; g <- a[, x0:w, 2]; bl <- a[, x0:w, 3]
  mx <- pmax(r, g, bl); mn <- pmin(r, g, bl)
  mean((mx - mn) > 0.12 & mx > 0.15 & mx < 0.95)
}

# capture_once: one full session -> navigate, prepare, highlight, png bytes ----
# `connect` lets the app boot, then wait_net_idle() blocks until mapbox tiles
# finish loading; we also poll up to `max_wait` for renderUI-populated targets
# (e.g. the species layer bar) that appear after the initial paint. returns the
# raw png bytes, or NULL if the session errored.
capture_once <- function(nav_url, selector) {
  b <- chromote::ChromoteSession$new(width = vwidth, height = vheight)
  on.exit(b$close(), add = TRUE)
  tryCatch({
    b$Page$navigate(nav_url, wait_ = TRUE)
    Sys.sleep(connect)
    b$Runtime$evaluate(dismiss_modal_js)   # fallback: clear any welcome splash
    wait_net_idle(b)                       # block until the map tiles finish
    Sys.sleep(paint)
    waited <- 0
    while (!has_selector(b, selector) && waited < max_wait) {
      Sys.sleep(1); waited <- waited + 1
    }
    # activate tabs / open the sidebar so the screenshot shows real content
    if (is_activator(selector)) {
      b$Runtime$evaluate(click_js(selector))
      # nudge shiny to re-evaluate output visibility: a programmatic click that
      # opens the sidebar doesn't reliably un-suspend its suspend-when-hidden
      # outputs (e.g. species_info), but a resize event forces a recalc
      b$Runtime$evaluate("window.dispatchEvent(new Event('resize'));")
      Sys.sleep(post_click)   # floor for websocket-rendered panels (plot/table)
      wait_net_idle(b)        # block until the report tab's embedded map tiles load
      ct <- content_target(selector)   # wait out suspended-while-hidden outputs
      if (!is.na(ct)) {
        waited <- 0
        while (!has_text(b, ct) && waited < max_wait) {
          b$Runtime$evaluate("window.dispatchEvent(new Event('resize'));")
          Sys.sleep(1); waited <- waited + 1
        }
      }
      Sys.sleep(paint)   # let the just-rendered content paint before capture
    }
    hl  <- highlight_target(selector)
    res <- b$Runtime$evaluate(highlight_js(hl))$result$value %||% "NULL"
    if (!identical(res, "OK"))
      message(glue::glue("    ! highlight target not found ({res}): {hl}"))
    shot <- b$Page$captureScreenshot(
      clip = list(x = 0, y = 0, width = vwidth, height = vheight, scale = 1))
    jsonlite::base64_dec(shot$data)
  }, error = function(e) {
    message(glue::glue("    ! capture error: {conditionMessage(e)}"))
    NULL
  })
}

# shoot_step: capture, verify the cell raster painted, retry if not ----
# the score raster paints only ~40% of loads (a mapbox layer-add race), so for
# cell-bearing steps we retry fresh sessions and keep the best render.
shoot_step <- function(url, selector, file) {
  nav_url <- paste0(url, if (grepl("?", url, fixed = TRUE)) "&" else "?", "splash=false")
  want    <- needs_cells(selector)
  best <- NULL; best_frac <- -1
  for (attempt in seq_len(if (want) max_attempts else 1L)) {
    bytes <- capture_once(nav_url, selector)
    if (is.null(bytes)) next
    frac <- if (want) colored_frac(bytes) else 1
    if (frac > best_frac) { best_frac <- frac; best <- bytes }
    if (frac >= cell_thresh) break
    message(glue::glue(
      "    cells not painted (frac={format(round(frac, 4))}), retry {attempt}/{max_attempts}"))
  }
  if (is.null(best)) stop(glue::glue("all captures failed for {selector}"))
  writeBin(best, file)
  invisible(best_frac)
}

# run ----
all_steps <- list()
for (key in names(apps)) {
  app <- apps[[key]]
  message(glue::glue("== {app$name}  ({app$app_r})"))
  if (!file.exists(app$app_r)) {
    warning(glue::glue("missing app.R, skipping {app$name}: {app$app_r}"))
    next
  }
  steps <- extract_steps(app$app_r)
  message(glue::glue("   {length(steps)} tour steps"))
  for (i in seq_along(steps)) {
    st  <- steps[[i]]
    png <- glue::glue("{key}-{sprintf('%02d', i)}.png")
    message(glue::glue("   [{i}/{length(steps)}] {st$title}  <-  {st$selector}"))
    frac <- shoot_step(app$url, st$selector, file.path(fig_dir, png))
    message(glue::glue("       cell-fraction = {format(round(frac, 4))}"))
    all_steps[[length(all_steps) + 1]] <- list(
      app      = app$name,
      app_key  = key,
      n        = i,
      title    = st$title,
      text     = st$text,
      selector = st$selector,
      url      = app$url,
      image    = glue::glue("/figures/apps-guide/{png}"))
  }
}

jsonlite::write_json(all_steps, manifest, auto_unbox = TRUE, pretty = TRUE)
message(glue::glue("wrote {manifest}  ({length(all_steps)} steps)"))

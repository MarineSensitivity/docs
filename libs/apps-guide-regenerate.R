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

librarian::shelf(chromote, jsonlite, here, glue, fs, quiet = TRUE)

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
settle     <- 8    # base seconds for shiny + mapbox tiles to paint
max_wait   <- 25   # extra seconds to poll for a slow-rendering target element
post_click <- 7    # seconds after activating a tab/sidebar for content to render

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

# shoot_step: navigate, wait for the target, highlight, capture ----
# a base `settle` lets shiny + mapbox tiles paint; we then poll up to
# `max_wait` for renderUI-populated targets (e.g. the species layer bar)
# that appear after the initial paint.
shoot_step <- function(url, selector, file) {
  b <- chromote::ChromoteSession$new(width = vwidth, height = vheight)
  on.exit(b$close(), add = TRUE)
  # ?splash=false suppresses the welcome modal in both apps; the JS dismissal
  # below is a fallback for any deploy that predates that flag
  nav_url <- paste0(url, if (grepl("?", url, fixed = TRUE)) "&" else "?", "splash=false")
  b$Page$navigate(nav_url, wait_ = TRUE)
  Sys.sleep(settle)
  b$Runtime$evaluate(dismiss_modal_js)   # fallback: clear any welcome splash
  Sys.sleep(3)                           # let the app repaint behind it
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
    Sys.sleep(post_click)   # let the revealed panel / embedded map render
    ct <- content_target(selector)   # wait out suspended-while-hidden outputs
    if (!is.na(ct)) {
      waited <- 0
      while (!has_text(b, ct) && waited < max_wait) {
        b$Runtime$evaluate("window.dispatchEvent(new Event('resize'));")
        Sys.sleep(1); waited <- waited + 1
      }
      Sys.sleep(2)   # let the just-rendered content paint before capture
    }
  }
  hl  <- highlight_target(selector)
  res <- b$Runtime$evaluate(highlight_js(hl))$result$value %||% "NULL"
  if (!identical(res, "OK"))
    message(glue::glue("    ! highlight target not found ({res}): {hl}"))
  shot <- b$Page$captureScreenshot(
    clip = list(x = 0, y = 0, width = vwidth, height = vheight, scale = 1))
  writeBin(jsonlite::base64_dec(shot$data), file)
  invisible(file)
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
    shoot_step(app$url, st$selector, file.path(fig_dir, png))
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

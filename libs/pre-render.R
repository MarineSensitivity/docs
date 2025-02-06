librarian::shelf(
  glue, here, stringr,
  quiet = T)

gh_token <- Sys.getenv("GITHUB_TOKEN")
dir_out  <- here("libs/pre-render_downloads")

# svg figure ----
download.file(
  "https://docs.google.com/drawings/d/16vr4BpARl9qWMsXeNkasorGwfMM69662OywMN2AsLT4/export/svg",
  "figures/gdraw_spp-sens_rast-tbl-aoi.svg")

# github wiki markdown ----
url_md   <- glue("https://raw.github.com/wiki/MarineSensitivity/server/Server-Setup.md") # ?login=bbest&token={gh_token}")
out_md   <- here(glue("{dir_out}/{basename(url_md)}"))

download.file(url_md, out_md)
readLines(out_md) |>
  str_replace_all("^##", "###") |>  # decrement header levels
  writeLines(out_md)

# github raw files ----
files = c(
  "https://github.com/MarineSensitivity/server/blob/main/docker-compose.yml",
  "https://github.com/MarineSensitivity/server/blob/main/caddy/Caddyfile")

for (f in files) {
  # f = files[1]
  u <- f |>
    str_replace("github.com", "raw.githubusercontent.com") |>
    str_replace("blob"      , "refs/heads")
  o <- here(glue("{dir_out}/{basename(u)}"))
  download.file(u, o)
}


Sys.setenv(QUARTO_CHROMIUM_HEADLESS_MODE = "new")

# wiki markdown ----


# manual listings images ----
#   Quarto document listings only appear in html.
#   But the chromote-based webshot2::webshot() does not handle:
#   - the software component icons
#   - the full captions for the apps listing
#  So, we manually screenshot the images from the url to the file and keep these comments.

# librarian::shelf(
#   webshot2)

# webshot(
#   url      = "https://marinesensitivity.org/docs/apps.html",
#   file     = "figures/listing-apps.png",
#   selector = "#listing-list-apps",
#   zoom     = 2)

# webshot(
#   url      = "https://marinesensitivity.org/docs/software.html",
#   file     = "figures/listing-software.png",
#   selector = "#listing-list-components",
#   zoom     = 2,
#   delay    = 5)


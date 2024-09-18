download.file(
  "https://docs.google.com/drawings/d/16vr4BpARl9qWMsXeNkasorGwfMM69662OywMN2AsLT4/export/svg",
  "figures/gdraw_spp-sens_rast-tbl-aoi.svg")

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


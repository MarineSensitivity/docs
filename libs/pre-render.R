librarian::shelf(
  webshot2)

webshot(
  url      = "https://marinesensitivity.org/docs/apps.html",
  file     = "figures/listing-apps.png",
  selector = "#listing-list-apps",
  zoom     = 2)

# manual since image icons not rendering
# webshot(
#   url      = "https://marinesensitivity.org/docs/software.html",
#   file     = "figures/listing-software.png",
#   selector = "#listing-list-components",
#   zoom     = 2,
#   delay    = 5)

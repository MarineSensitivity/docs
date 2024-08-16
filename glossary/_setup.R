# glossary setup - persistent across chapters

# initiated by .Rprofile:
#   source("glossary/_setup.R") # glossary setup

if (!"glossary" %in% rownames(utils::installed.packages()))
  utils::install.packages(
    "glossary",
    repos = c(
      "https://debruine.r-universe.dev",
      "https://cloud.r-project.org"))
library(glossary)

glossary_path("glossary/glossary.yml")
glossary_persistent("glossary/glossary-persistent.yml")

glossary_popup("click")



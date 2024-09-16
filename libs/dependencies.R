# run this manually when adding R packages or Quarto extensions

# add to DESCRIPTION
pkgs <- c(
  "dplyr", "gh", "glue", "here", "knitr", "quarto", "stringr", "tidyjson",
  "yaml")
sapply(pkgs, usethis::use_package)

# install Quarto _extensions in Terminal:
#  quarto add quarto-ext/fontawesome
#  quarto install extension debruine/quarto-glossary

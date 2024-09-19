# run this manually when adding R packages or Quarto extensions

# add to DESCRIPTION
pkgs_cran <- c(
  "dplyr", "gh", "glue", "here", "knitr", "quarto", "stringr", "tidyjson",
  "yaml")
pkgs_github <- c(
  "offshorewindhabitat/offhabr")

sapply(pkgs_cran, usethis::use_package)
#sapply(pkgs_github, usethis::use_dev_package)
# TODO: function to install from GitHub using basename
# use_github <- function(pkg){
#   usethis::use_dev_package(pkg, remote = paste0("offshorewindhabitat/", pkg))
# }

usethis::use_dev_package("offhabr", remote = "offshorewindhabitat/offhabr")

# install Quarto _extensions in Terminal:
#  quarto add quarto-ext/fontawesome
#  quarto install extension debruine/quarto-glossary

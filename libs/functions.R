# helper functions
# initiated by .Rprofile

g <- function(x){
  # glossary term
  if (knitr::is_html_output())
    return("")
  x
}

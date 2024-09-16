# cleanup because we need this _quarto.yml directive for creating both docx and pdf:
#   keep-md: true
#  per [Supporting file are cleanup to soon when using multiformat](https://github.com/quarto-dev/quarto-cli/issues/8373#issuecomment-1979245883)

mds <- list.files(pattern = ".+\\.docx\\.md", recursive = T)
unlink(mds)

dirs <- list.files(pattern = ".+_files")
unlink(dirs, recursive = TRUE)

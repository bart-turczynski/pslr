# Freshness advice never phrases elapsed time, or the absence of a check, as
# the list being out of date: the printed report of `status` names neither
# "outdated" nor "update available" (PSLR-lohhvukn).
expect_not_called_outdated <- function(status) {
  printed <- paste(format(status), collapse = "\n")
  expect_no_match(printed, "outdated", ignore.case = TRUE)
  expect_no_match(printed, "update available", ignore.case = TRUE)
}

# PSL-freshness harm corpus (McQuistin et al., IMC '23).
#
# McQuistin, Snyder, Perkins, Haddadi, Tyson, "A First Look at the Privacy
# Harms of the Public Suffix List" (IMC '23) shows that an outdated PSL silently
# produces the wrong registrable domain -- the wrong privacy boundary. When a
# newly added eTLD is missing from a stale list, a tenant host such as
# `foo.myshopify.com` collapses to registrable domain `myshopify.com`, treating
# every tenant as the same site (paper s3, Table 2).
#
# These tests pin the paper's Table-2 eTLDs against the bundled snapshot so we
# can never ship a list stale enough to reintroduce the documented harm. The
# discriminating assertion is exactly the harm: the tenant label must be BELOW
# the boundary (registrable = `foo.myshopify.com`), not above it (a stale list
# would give suffix `com`, registrable `myshopify.com`).
#
# Table 2 mixes two rule shapes, verified against the bundled .dat:
#   * plain rules    (e.g. `myshopify.com`)          -- the eTLD is the entry.
#   * wildcard rules (e.g. `*.digitaloceanspaces.com`) -- the eTLD is one label
#     below the entry, so the bare parent is NOT itself a public suffix.

# Plain Table-2 eTLDs: each entry is itself a public suffix.
freshness_plain <- c(
  "myshopify.com",
  "smushcdn.com",
  "readthedocs.io",
  "netlify.app",
  "web.app",
  "carrd.co",
  "altervista.org",
  "lpages.co",
  "sp.gov.br",
  "mg.gov.br",
  "pr.gov.br",
  "rs.gov.br",
  "sc.gov.br"
)

# Wildcard Table-2 eTLDs: listed as `*.<entry>`, so the boundary sits one label
# below the entry and the bare entry is not itself a public suffix.
freshness_wildcard <- c(
  "digitaloceanspaces.com",
  "r.appspot.com"
)

test_that("plain Table-2 eTLDs are recognized public suffixes", {
  expect_equal(
    is_public_suffix(freshness_plain),
    rep(TRUE, length(freshness_plain))
  )
})

test_that("plain Table-2 eTLDs put the boundary below the tenant label", {
  tenant <- paste0("tenant.", freshness_plain)

  # Suffix is the eTLD itself -- not the parent TLD a stale list would report.
  expect_equal(public_suffix(tenant), freshness_plain)

  # Registrable domain keeps the tenant label, so distinct tenants stay
  # distinct instead of collapsing onto the shared eTLD (the paper's harm).
  expect_equal(registrable_domain(tenant), tenant)
})

test_that("distinct tenants of a plain Table-2 eTLD stay distinct", {
  # The concrete privacy harm: on a stale list both collapse to `myshopify.com`.
  got <- registrable_domain(c("foo.myshopify.com", "bar.myshopify.com"))
  expect_equal(got, c("foo.myshopify.com", "bar.myshopify.com"))
  expect_false(got[[1]] == got[[2]])
})

test_that("wildcard Table-2 entries put the boundary below the entry", {
  # The bare parent is not itself a public suffix under a `*.<entry>` rule ...
  expect_equal(
    is_public_suffix(freshness_wildcard),
    rep(FALSE, length(freshness_wildcard))
  )

  # ... but any single label below it is (the wildcard expansion).
  labelled <- paste0("reg.", freshness_wildcard)
  expect_equal(
    is_public_suffix(labelled),
    rep(TRUE, length(freshness_wildcard))
  )

  tenant <- paste0("tenant.", labelled)
  expect_equal(public_suffix(tenant), labelled)
  expect_equal(registrable_domain(tenant), tenant)
})

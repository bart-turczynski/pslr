# Public query API (PRD s6, s7).
#
# Thin, vectorised wrappers over the canonicalization layer (R/canonicalize.R)
# and the cached core matcher (R/matcher.R). Each function owns argument
# matching and the user-facing `section` / `output` / `unknown` / `invalid`
# policies; the heavy lifting of normalization, matching, and caching lives
# below. `unknown` and `output` are applied here, after the cache, so they never
# affect the cache key (PRD s8.2).

# Match a scalar option argument against its choices. When the caller did not
# supply the argument (`supplied = FALSE`, i.e. `missing()` at the call site),
# the formal's full choice vector selects the first choice; any value the caller
# does supply must be a single string drawn from the choices, so non-scalar or
# unknown values abort -- `invalid` never suppresses these programming errors
# (PRD s5.2). Detecting "supplied" via `missing()` rather than comparing against
# the choice vector means an explicit non-scalar argument that happens to equal
# the default (e.g. `invalid = c("na", "error")`) still aborts.
match_opt <- function(value, choices, name, supplied) {
  if (!supplied) {
    return(choices[1L])
  }
  scalar_string <- length(value) == 1L && is.character(value) && !is.na(value)
  if (!scalar_string || !value %in% choices) {
    stop(
      sprintf(
        "`%s` must be one of: %s.", name,
        paste0("\"", choices, "\"", collapse = ", ")
      ),
      call. = FALSE
    )
  }
  value
}

# Append the terminal root dot where the input carried one and the value is not
# NA. Used for hostname-shaped outputs only (PRD s5.3, s6.3).
restore_root_dot <- function(x, had_dot) {
  m <- had_dot & !is.na(x)
  x[m] <- paste0(x[m], ".")
  x
}

# Decode canonical ASCII A-labels to Unicode, leaving NA untouched (PRD s6.3).
decode_ascii <- function(x) {
  # Decode only real A-labels: skip NA and the empty string. puny_decode("")
  # returns NA, which would turn a documented empty subdomain ("") into NA.
  ok <- !is.na(x) & nzchar(x)
  if (any(ok)) {
    x[ok] <- punycoder::puny_decode(x[ok], strict = FALSE)
  }
  x
}

# Re-attach the names of `domain` to a length-preserving result (PRD s7.1).
name_like <- function(out, domain) {
  names(out) <- names(domain)
  out
}

# Build the shared per-element result frame used by every public function.
# Returns canonical ASCII (no terminal dot) match fields plus the input status,
# canonical host, label counts, and the `had_dot` flag. The `unknown = "na"`
# policy is applied here by erasing the implicit-default rule's derived fields;
# `output` and terminal-dot restoration are left to the callers.
psl_query_frame <- function(domain, section, unknown, invalid) {
  canon <- psl_canonicalize(domain, invalid)
  n <- length(canon$input)
  public_suffix <- rep(NA_character_, n)
  registrable_domain <- rep(NA_character_, n)
  rule <- rep(NA_character_, n)
  kind <- rep(NA_character_, n)
  rule_section <- rep(NA_character_, n)
  ps_depth <- rep(NA_integer_, n)
  n_labels <- rep(NA_integer_, n)

  valid <- canon$status == "ok"
  if (any(valid)) {
    res <- psl_resolve_cores(canon$core[valid], section)
    public_suffix[valid] <- res$public_suffix
    registrable_domain[valid] <- res$registrable_domain
    rule[valid] <- res$rule
    kind[valid] <- res$kind
    rule_section[valid] <- res$rule_section
    ps_depth[valid] <- res$ps_depth
    n_labels[valid] <- lengths(strsplit(canon$core[valid], ".", fixed = TRUE))
  }

  if (identical(unknown, "na")) {
    drop <- !is.na(kind) & kind == "default"
    public_suffix[drop] <- NA_character_
    registrable_domain[drop] <- NA_character_
    rule[drop] <- NA_character_
    rule_section[drop] <- NA_character_
    kind[drop] <- NA_character_
    ps_depth[drop] <- NA_integer_
  }

  data.frame(
    # unname so a named `domain` cannot become data.frame row names (PRD s7.2).
    input = unname(canon$input), status = canon$status, had_dot = canon$had_dot,
    host_ascii = canon$host, core = canon$core,
    n_labels = n_labels, ps_depth = ps_depth,
    public_suffix = public_suffix, registrable_domain = registrable_domain,
    rule = rule, kind = kind, rule_section = rule_section,
    stringsAsFactors = FALSE
  )
}

#' Public suffix of a host
#'
#' Returns the public suffix (effective top-level domain, eTLD) of each host
#' under the selected Public Suffix List policy, following the official
#' prevailing-rule algorithm.
#'
#' @param domain Character vector of DNS hostnames (not URLs). Each element may
#'   be a mixed-case ASCII, Unicode, or A-label hostname, a single label, or a
#'   hostname with exactly one terminal root dot. See **Input contract**.
#' @param section Which rule sections are eligible: `"all"` (default; ICANN and
#'   PRIVATE), `"icann"`, or `"private"`. Section filtering happens before
#'   prevailing-rule selection, so `"private"` does not silently add ICANN
#'   rules; a host matching no rule in the section falls through to the implicit
#'   default rule unless `unknown = "na"`.
#' @param output `"ascii"` (default) returns lowercase A-labels; `"unicode"`
#'   decodes them after matching. A terminal root dot is preserved either way.
#' @param unknown `"default"` (default) applies the spec's implicit `*` rule, so
#'   an unlisted single label is its own public suffix; `"na"` returns `NA` when
#'   no explicit rule in the selected section matches.
#' @param invalid `"na"` (default) returns `NA` for each invalid element without
#'   a warning; `"error"` aborts on the first invalid element, reporting its
#'   1-based index.
#'
#' @section Input contract:
#' `NA` is treated as missing (returns `NA`), not invalid. Invalid elements
#' include empty or whitespace-only strings, leading or consecutive dots, URL
#' syntax, IPv6 addresses, canonical dotted-decimal IPv4 literals, and labels
#' that fail hostname/IDNA validation. Wrong argument types and non-scalar or
#' unknown option values always abort regardless of `invalid`.
#'
#' @return A character vector with `length(domain)`, preserving the names of
#'   `domain`. Other attributes are dropped.
#' @seealso [registrable_domain()], [is_public_suffix()], [suffix_extract()],
#'   [public_suffix_rule()]
#' @examples
#' public_suffix("www.example.com")
#' public_suffix("example.co.uk")
#' public_suffix("example.com.")
#' public_suffix("madeuptld", unknown = "na")
#' @export
public_suffix <- function(domain,
                          section = c("all", "icann", "private"),
                          output = c("ascii", "unicode"),
                          unknown = c("default", "na"),
                          invalid = c("na", "error")) {
  section <- match_opt(section, c("all", "icann", "private"), "section",
                       !missing(section))
  output <- match_opt(output, c("ascii", "unicode"), "output",
                      !missing(output))
  unknown <- match_opt(unknown, c("default", "na"), "unknown",
                       !missing(unknown))
  invalid <- match_opt(invalid, c("na", "error"), "invalid",
                       !missing(invalid))

  fr <- psl_query_frame(domain, section, unknown, invalid)
  out <- restore_root_dot(fr$public_suffix, fr$had_dot)
  if (identical(output, "unicode")) {
    out <- decode_ascii(out)
  }
  name_like(out, domain)
}

#' Registrable domain of a host
#'
#' Returns the registrable domain (eTLD+1) of each host: its public suffix plus
#' one host label to the left. It is `NA` when no such label exists (the host is
#' itself a public suffix) or when the public suffix is `NA`.
#'
#' @inheritParams public_suffix
#' @inheritSection public_suffix Input contract
#' @return A character vector with `length(domain)`, preserving the names of
#'   `domain`. Other attributes are dropped.
#' @seealso [public_suffix()], [is_public_suffix()], [suffix_extract()]
#' @examples
#' registrable_domain("www.example.co.uk")
#' registrable_domain("com")
#' registrable_domain("foo.madeuptld", unknown = "na")
#' @export
registrable_domain <- function(domain,
                               section = c("all", "icann", "private"),
                               output = c("ascii", "unicode"),
                               unknown = c("default", "na"),
                               invalid = c("na", "error")) {
  section <- match_opt(section, c("all", "icann", "private"), "section",
                       !missing(section))
  output <- match_opt(output, c("ascii", "unicode"), "output",
                      !missing(output))
  unknown <- match_opt(unknown, c("default", "na"), "unknown",
                       !missing(unknown))
  invalid <- match_opt(invalid, c("na", "error"), "invalid",
                       !missing(invalid))

  fr <- psl_query_frame(domain, section, unknown, invalid)
  out <- restore_root_dot(fr$registrable_domain, fr$had_dot)
  if (identical(output, "unicode")) {
    out <- decode_ascii(out)
  }
  name_like(out, domain)
}

#' Is a host itself a public suffix?
#'
#' `TRUE` exactly when the valid canonical host equals its own public suffix
#' under the selected policy. Returns `NA` whenever [public_suffix()] would
#' return `NA` (missing or invalid input, or an unresolved host under
#' `unknown = "na"`). Under the default `unknown = "default"`, an unlisted
#' single label such as `"madeuptld"` is `TRUE` via the implicit `*` rule; ask
#' `unknown = "na"` to test explicit membership instead.
#'
#' @inheritParams public_suffix
#' @inheritSection public_suffix Input contract
#' @return A logical vector with `length(domain)`, preserving the names of
#'   `domain`.
#' @seealso [public_suffix()]
#' @examples
#' is_public_suffix("com")
#' is_public_suffix("example.com")
#' is_public_suffix("madeuptld")
#' is_public_suffix("madeuptld", unknown = "na")
#' @export
is_public_suffix <- function(domain,
                             section = c("all", "icann", "private"),
                             unknown = c("default", "na"),
                             invalid = c("na", "error")) {
  section <- match_opt(section, c("all", "icann", "private"), "section",
                       !missing(section))
  unknown <- match_opt(unknown, c("default", "na"), "unknown",
                       !missing(unknown))
  invalid <- match_opt(invalid, c("na", "error"), "invalid",
                       !missing(invalid))

  fr <- psl_query_frame(domain, section, unknown, invalid)
  out <- rep(NA, length(domain))
  resolved <- !is.na(fr$public_suffix)
  out[resolved] <- fr$n_labels[resolved] == fr$ps_depth[resolved]
  name_like(out, domain)
}

#' Split hosts into subdomain, registrant label, and public suffix
#'
#' @inheritParams public_suffix
#' @inheritSection public_suffix Input contract
#' @return A base [data.frame] with one row per input and columns, in order:
#'   `input` (original, unchanged), `host` (canonical host in `output` form),
#'   `subdomain` (labels left of the registrable domain; `""` when none),
#'   `domain` (the single registrant label left of the suffix), `suffix` (the
#'   public suffix), and `registrable_domain` (eTLD+1). `domain`, `subdomain`,
#'   and `registrable_domain` are `NA` when the host is itself a public suffix.
#'   If public-suffix resolution is `NA`, every derived column except `input`
#'   and a successfully normalized `host` is `NA`. Zero-length input returns a
#'   zero-row frame; all-invalid input keeps one row per input. Root dots are
#'   preserved on `host`, `suffix`, and `registrable_domain` only.
#' @seealso [public_suffix()], [public_suffix_rule()]
#' @examples
#' suffix_extract("www.example.co.uk")
#' suffix_extract(c("example.com", "com", NA))
#' @export
suffix_extract <- function(domain,
                           section = c("all", "icann", "private"),
                           output = c("ascii", "unicode"),
                           unknown = c("default", "na"),
                           invalid = c("na", "error")) {
  section <- match_opt(section, c("all", "icann", "private"), "section",
                       !missing(section))
  output <- match_opt(output, c("ascii", "unicode"), "output",
                      !missing(output))
  unknown <- match_opt(unknown, c("default", "na"), "unknown",
                       !missing(unknown))
  invalid <- match_opt(invalid, c("na", "error"), "invalid",
                       !missing(invalid))

  fr <- psl_query_frame(domain, section, unknown, invalid)
  n <- nrow(fr)
  host <- fr$host_ascii
  suffix <- restore_root_dot(fr$public_suffix, fr$had_dot)
  registrable <- restore_root_dot(fr$registrable_domain, fr$had_dot)
  domain_label <- rep(NA_character_, n)
  subdomain <- rep(NA_character_, n)

  has_rd <- !is.na(fr$registrable_domain)
  for (i in which(has_rd)) {
    labels <- strsplit(fr$core[i], ".", fixed = TRUE)[[1L]]
    cut <- fr$n_labels[i] - fr$ps_depth[i] # index of the registrant label
    domain_label[i] <- labels[cut]
    subdomain[i] <- if (cut > 1L) {
      paste(labels[seq_len(cut - 1L)], collapse = ".")
    } else {
      ""
    }
  }

  if (identical(output, "unicode")) {
    host <- decode_ascii(host)
    suffix <- decode_ascii(suffix)
    registrable <- decode_ascii(registrable)
    domain_label <- decode_ascii(domain_label)
    subdomain <- decode_ascii(subdomain)
  }

  data.frame(
    input = fr$input, host = host, subdomain = subdomain,
    domain = domain_label, suffix = suffix,
    registrable_domain = registrable, stringsAsFactors = FALSE
  )
}

#' Inspect the prevailing PSL rule for each host
#'
#' @inheritParams public_suffix
#' @inheritSection public_suffix Input contract
#' @return A base [data.frame] with one row per input and columns, in order:
#'   `input` (original), `host_ascii` (canonical A-label host), `rule` (the
#'   canonical rule including `*.` or `!`, `"*"` for the implicit default),
#'   `kind` (`"normal"`, `"wildcard"`, `"exception"`, or `"default"`),
#'   `rule_section` (`"icann"`, `"private"`, or `NA` for the default/no result),
#'   and `public_suffix_ascii` (the derived A-label public suffix). Invalid rows
#'   are `NA` in every derived column. A valid host left unresolved by
#'   `unknown = "na"` keeps `host_ascii` while the rule and suffix columns are
#'   `NA`. An exception `rule` retains its `!` for auditability. Zero-length
#'   input returns a zero-row frame; all-invalid input keeps one row per input.
#' @seealso [public_suffix()], [suffix_extract()]
#' @examples
#' public_suffix_rule("www.example.co.uk")
#' public_suffix_rule("madeuptld")
#' @export
public_suffix_rule <- function(domain,
                               section = c("all", "icann", "private"),
                               unknown = c("default", "na"),
                               invalid = c("na", "error")) {
  section <- match_opt(section, c("all", "icann", "private"), "section",
                       !missing(section))
  unknown <- match_opt(unknown, c("default", "na"), "unknown",
                       !missing(unknown))
  invalid <- match_opt(invalid, c("na", "error"), "invalid",
                       !missing(invalid))

  fr <- psl_query_frame(domain, section, unknown, invalid)
  data.frame(
    input = fr$input,
    host_ascii = fr$host_ascii,
    rule = fr$rule,
    kind = fr$kind,
    rule_section = fr$rule_section,
    public_suffix_ascii = restore_root_dot(fr$public_suffix, fr$had_dot),
    stringsAsFactors = FALSE
  )
}

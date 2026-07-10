# Public query API (PRD s6, s7).
#
# Thin, vectorised wrappers over the canonicalization layer (R/canonicalize.R)
# and the cached core matcher (R/matcher.R). Each function owns argument
# matching and the user-facing `section` / `output` / `unknown` / `invalid`
# policies; the heavy lifting of normalization, matching, and caching lives
# below. `unknown` and `output` are applied here, after the cache, so they never
# affect the cache key (PRD s8.2).

# Validate a scalar option argument against its choices, returning it unchanged.
# The value must be a single non-NA string drawn from `choices`; anything else
# (non-scalar, non-character, NA, or an unknown value) aborts -- these are
# programming errors that `invalid` never suppresses (PRD s5.2). Each option
# carries a scalar formal default that is a member of `choices`, so an omitted
# argument arrives as its default and passes unchanged; an explicit value equal
# to the default takes the same path, while an explicit non-scalar (e.g.
# `invalid = c("na", "error")`) still aborts on the length-1 check.
check_choice <- function(value, choices, arg) {
  scalar_string <- length(value) == 1L && is.character(value) && !is.na(value)
  if (!scalar_string || !value %in% choices) {
    stop(
      sprintf(
        "`%s` must be one of: %s.",
        arg,
        paste0("\"", choices, "\"", collapse = ", ")
      ),
      call. = FALSE
    )
  }
  value
}

# Validate the three option arguments every query function shares (`section`,
# `unknown`, `invalid`) and return them as a list; `output` is validated by the
# callers that accept it.
resolve_common_opts <- function(section, unknown, invalid) {
  list(
    section = check_choice(section, c("all", "icann", "private"), "section"),
    unknown = check_choice(unknown, c("default", "na"), "unknown"),
    invalid = check_choice(invalid, c("na", "error"), "invalid")
  )
}

# Match a scalar option argument against its choices, selecting the first choice
# when the caller omitted it (`supplied = FALSE`, i.e. `missing()` at the call
# site). Retained for `psl_use()`, which still carries a choice-vector default;
# the query functions use scalar defaults and `check_choice()` instead.
match_opt <- function(value, choices, name, supplied) {
  if (!supplied) {
    return(choices[1L])
  }
  check_choice(value, choices, name)
}

# Append the terminal root dot where the input carried one and the value is not
# NA. Used for hostname-shaped outputs only (PRD s5.3, s6.3).
restore_root_dot <- function(x, had_dot) {
  m <- had_dot & !is.na(x)
  x[m] <- paste0(x[m], ".")
  x
}

# Decode canonical ASCII A-labels to Unicode across one or more parallel
# columns, leaving NA untouched (PRD s6.3). The distinct decode-eligible values
# are pooled across every column and crossed into punycoder::puny_decode()
# exactly once, then mapped back to each position -- so N identical outputs (and
# A-labels shared by overlapping columns like suffix/registrable/host) are
# decoded only once. Equal input strings decode identically, so deduplication is
# byte-identical to decoding each position independently. Per-element semantics
# are preserved exactly: NA in -> NA out (never decoded); "" in -> "" out (the
# nzchar guard is load-bearing -- puny_decode("") returns NA, which would turn a
# documented empty subdomain into NA); any other value -> its
# puny_decode(strict = FALSE) result. Returns the decoded columns as a list, in
# the argument order.
decode_ascii_pool <- function(...) {
  cols <- list(...)
  eligible <- lapply(cols, \(x) !is.na(x) & nzchar(x))
  pool <- unique(unlist(
    Map(\(x, ok) x[ok], cols, eligible),
    use.names = FALSE
  ))
  if (length(pool)) {
    decoded <- punycoder::puny_decode(pool, strict = FALSE)
    cols <- Map(
      function(x, ok) {
        x[ok] <- decoded[match(x[ok], pool)]
        x
      },
      cols,
      eligible
    )
  }
  cols
}

# Single-column convenience wrapper over decode_ascii_pool() for the
# length-preserving accessors (`public_suffix()` / `registrable_domain()`).
decode_ascii <- function(x) {
  decode_ascii_pool(x)[[1L]]
}

# Re-attach the names of `domain` to a length-preserving result (PRD s7.1).
name_like <- function(out, domain) {
  names(out) <- names(domain)
  out
}

# Build the shared per-element result columns used by every public function.
# Returns a plain LIST of parallel column vectors (not a data.frame): canonical
# ASCII (no terminal dot) match fields plus the input status, canonical host,
# the `had_dot` flag, and the byte offsets `ps_start` / `rd_start`
# (used by `suffix_extract()` to slice out the registrant label and subdomain
# without a per-row `strsplit`). Returning a bare list avoids the ~0.1-0.2 ms
# `data.frame()` construction on every call: the length-preserving accessors
# (`public_suffix()` / `registrable_domain()` / `is_public_suffix()`) read the
# one or two columns they need directly, and only `suffix_extract()` /
# `public_suffix_rule()` pay for a `data.frame()` -- once, at the end. The
# `unknown = "na"` policy is applied here by erasing the implicit-default rule's
# derived fields; `output` and terminal-dot restoration are left to the callers.
# The `engine` is threaded in explicitly by the callers (each resolves the
# default engine once) rather than fetched from the global state here.
psl_query_cols <- function(
  engine,
  domain,
  section,
  unknown,
  invalid,
  fields = psl_result_char_cols
) {
  canon <- psl_canonicalize(domain, invalid)
  n <- length(canon$input)
  valid <- canon$status == "ok"

  # The eight match columns start NA (via the RESULT schema) so invalid inputs
  # stay NA; valid cores are resolved once and copied in column by column. Only
  # the string columns named in `fields` are derived (kind/rule_section and the
  # offsets are always present); the copy loop and the `unknown = "na"` drop
  # below are shape-preserving, so NA-ing an unrequested column is inert.
  m <- psl_match_alloc(n)
  if (any(valid)) {
    res <- psl_resolve_cores(engine, canon$core[valid], section, fields)
    for (col in psl_result_cols) {
      m[[col]][valid] <- res[[col]]
    }
  }

  # `unknown = "na"` erases the implicit-default rule's derived fields.
  if (identical(unknown, "na")) {
    drop <- !is.na(m$kind) & m$kind == "default"
    for (col in psl_result_char_cols) {
      m[[col]][drop] <- NA_character_
    }
    m$ps_depth[drop] <- NA_integer_
  }

  list(
    # unname so a named `domain` cannot become data.frame row names when a
    # caller wraps these columns in a data.frame (PRD s7.2).
    input = unname(canon$input),
    status = canon$status,
    had_dot = canon$had_dot,
    host_ascii = canon$host,
    core = canon$core,
    ps_depth = m$ps_depth,
    ps_start = m$ps_start,
    rd_start = m$rd_start,
    public_suffix = m$public_suffix,
    registrable_domain = m$registrable_domain,
    rule = m$rule,
    kind = m$kind,
    rule_section = m$rule_section
  )
}

# Shared body of the length-preserving single-string accessors
# `public_suffix()` and `registrable_domain()`: they differ only in which
# result column they read (`field`) and, via the same name, which `fields`
# projection they request. Validates the common opts and `output`, resolves the
# default engine, derives just `field`, restores the terminal root dot, decodes
# A-labels to Unicode on demand, and re-attaches the names of `domain`.
psl_query_vector <- function(domain, field, section, output, unknown, invalid) {
  opts <- resolve_common_opts(section, unknown, invalid)
  output <- check_choice(output, c("ascii", "unicode"), "output")

  engine <- psl_default_engine()
  cols <- psl_query_cols(
    engine,
    domain,
    opts$section,
    opts$unknown,
    opts$invalid,
    fields = field
  )
  out <- restore_root_dot(cols[[field]], cols$had_dot)
  if (identical(output, "unicode")) {
    out <- decode_ascii(out)
  }
  name_like(out, domain)
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
public_suffix <- function(
  domain,
  section = "all",
  output = "ascii",
  unknown = "default",
  invalid = "na"
) {
  psl_query_vector(
    domain,
    "public_suffix",
    section,
    output,
    unknown,
    invalid
  )
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
registrable_domain <- function(
  domain,
  section = "all",
  output = "ascii",
  unknown = "default",
  invalid = "na"
) {
  psl_query_vector(
    domain,
    "registrable_domain",
    section,
    output,
    unknown,
    invalid
  )
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
is_public_suffix <- function(
  domain,
  section = "all",
  unknown = "default",
  invalid = "na"
) {
  opts <- resolve_common_opts(section, unknown, invalid)

  engine <- psl_default_engine()
  cols <- psl_query_cols(
    engine,
    domain,
    opts$section,
    opts$unknown,
    opts$invalid,
    fields = "public_suffix"
  )
  out <- rep(NA, length(domain))
  resolved <- !is.na(cols$public_suffix)
  out[resolved] <- cols$ps_start[resolved] == 1L
  name_like(out, domain)
}

# Slice the registrant label and subdomain straight out of the canonical core
# using the byte offsets from the matcher, replacing a per-row `strsplit`. In a
# core `subdomain.domain.suffix`, `rd_start` points at the registrable domain
# (`domain.suffix`) and `ps_start` at the suffix, so the registrant label spans
# `[rd_start, ps_start - 2]` (dropping the dot at `ps_start - 1`) and the
# subdomain is `[1, rd_start - 2]`. A registrable domain starting at position 1
# has no subdomain (`""`), matching the old `cut > 1` rule. Returns a two-column
# list (`domain`, `subdomain`), both NA where there is no registrable domain.
psl_slice_registrant <- function(cols) {
  n <- length(cols$input)
  domain_label <- rep(NA_character_, n)
  subdomain <- rep(NA_character_, n)
  has_rd <- !is.na(cols$registrable_domain)
  if (any(has_rd)) {
    core_rd <- cols$core[has_rd]
    rd0 <- cols$rd_start[has_rd]
    ps0 <- cols$ps_start[has_rd]
    domain_label[has_rd] <- substr(core_rd, rd0, ps0 - 2L)
    subdomain[has_rd] <- ifelse(rd0 > 1L, substr(core_rd, 1L, rd0 - 2L), "")
  }
  list(domain = domain_label, subdomain = subdomain)
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
suffix_extract <- function(
  domain,
  section = "all",
  output = "ascii",
  unknown = "default",
  invalid = "na"
) {
  opts <- resolve_common_opts(section, unknown, invalid)
  output <- check_choice(output, c("ascii", "unicode"), "output")

  engine <- psl_default_engine()
  cols <- psl_query_cols(
    engine,
    domain,
    opts$section,
    opts$unknown,
    opts$invalid,
    fields = c("public_suffix", "registrable_domain")
  )
  host <- cols$host_ascii
  suffix <- restore_root_dot(cols$public_suffix, cols$had_dot)
  registrable <- restore_root_dot(cols$registrable_domain, cols$had_dot)
  parts <- psl_slice_registrant(cols)
  domain_label <- parts$domain
  subdomain <- parts$subdomain

  if (identical(output, "unicode")) {
    # One pooled puny_decode() crossing for all five columns: suffix,
    # registrable, and host share A-labels heavily, so decode distinct values
    # just once.
    decoded <- decode_ascii_pool(
      host,
      suffix,
      registrable,
      domain_label,
      subdomain
    )
    host <- decoded[[1L]]
    suffix <- decoded[[2L]]
    registrable <- decoded[[3L]]
    domain_label <- decoded[[4L]]
    subdomain <- decoded[[5L]]
  }

  data.frame(
    input = cols$input,
    host = host,
    subdomain = subdomain,
    domain = domain_label,
    suffix = suffix,
    registrable_domain = registrable,
    stringsAsFactors = FALSE
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
public_suffix_rule <- function(
  domain,
  section = "all",
  unknown = "default",
  invalid = "na"
) {
  opts <- resolve_common_opts(section, unknown, invalid)

  engine <- psl_default_engine()
  cols <- psl_query_cols(
    engine,
    domain,
    opts$section,
    opts$unknown,
    opts$invalid,
    fields = c("public_suffix", "registrable_domain", "rule")
  )
  data.frame(
    input = cols$input,
    host_ascii = cols$host_ascii,
    rule = cols$rule,
    kind = cols$kind,
    rule_section = cols$rule_section,
    public_suffix_ascii = restore_root_dot(cols$public_suffix, cols$had_dot),
    stringsAsFactors = FALSE
  )
}

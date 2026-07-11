// cpp11 core matcher for pslr (PRD s6, s8.2).
//
// Holds partitioned, immutable rule indexes (normal / wildcard / exception, per
// ICANN and PRIVATE section) behind an external pointer, and runs the official
// prevailing-rule algorithm right-to-left in time proportional to the host's
// label count, not the rule count.
//
// The R layer owns normalization, terminal-dot handling, result shaping, and
// errors; this file only sees canonical lowercase ASCII hosts and returns the
// prevailing rule as (public-suffix depth, kind, section) per host.

#include <cpp11.hpp>

#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

using namespace cpp11;

namespace {

// kind indexes
constexpr int KIND_NORMAL = 0;
constexpr int KIND_WILDCARD = 1;
constexpr int KIND_EXCEPTION = 2;
// section indexes / codes
constexpr int SEC_ICANN = 0;
constexpr int SEC_PRIVATE = 1;
// section_code 2 ("all") is handled as the fall-through in find_section().

struct Matcher {
  // sets[section][kind] of canonical keys. For a wildcard rule the key is its
  // parent labels; for an exception it is the full (post-'!') labels.
  std::unordered_set<std::string> sets[2][3];
};

// Map a rule-kind string to its set index, rejecting anything outside the
// three known kinds. The old build loop treated "anything not normal/wildcard"
// as EXCEPTION, so a misspelled kind was silently bucketed as an exception;
// validating here turns that into a clear boundary error instead.
int kind_index(const std::string& kind) {
  if (kind == "normal") return KIND_NORMAL;
  if (kind == "wildcard") return KIND_WILDCARD;
  if (kind == "exception") return KIND_EXCEPTION;
  cpp11::stop(
      "unknown rule kind '%s': expected 'normal', 'wildcard', or 'exception'",
      kind.c_str());
}

std::vector<std::string> split_labels(const std::string& host) {
  std::vector<std::string> labels;
  std::size_t start = 0;
  std::size_t pos;
  while ((pos = host.find('.', start)) != std::string::npos) {
    labels.push_back(host.substr(start, pos - start));
    start = pos + 1;
  }
  labels.push_back(host.substr(start));
  return labels;
}

// Look a key up in the requested section(s). Returns the section it was found
// in (SEC_ICANN / SEC_PRIVATE), or -1 if absent. For SECTION_ALL, ICANN wins a
// cross-section tie so the more authoritative boundary is reported.
int find_section(const Matcher* m, int kind, const std::string& key,
                 int section_code) {
  if (section_code == SEC_ICANN) {
    return m->sets[SEC_ICANN][kind].count(key) ? SEC_ICANN : -1;
  }
  if (section_code == SEC_PRIVATE) {
    return m->sets[SEC_PRIVATE][kind].count(key) ? SEC_PRIVATE : -1;
  }
  if (m->sets[SEC_ICANN][kind].count(key)) return SEC_ICANN;
  if (m->sets[SEC_PRIVATE][kind].count(key)) return SEC_PRIVATE;
  return -1;
}

void matcher_finalizer(SEXP ptr) {
  Matcher* m = static_cast<Matcher*>(R_ExternalPtrAddr(ptr));
  if (m == nullptr) return;
  delete m;
  R_ClearExternalPtr(ptr);
}

}  // namespace

// The matcher is exchanged with R as an opaque external pointer (a plain SEXP),
// because cpp11's code generator only forward-declares registered signatures
// and cannot see the Matcher type. Building it once and reusing the pointer
// keeps the active matcher immutable after construction (PRD s8.2).
[[cpp11::register]]
SEXP psl_build_matcher(strings keys, strings kinds, integers sections) {
  R_xlen_t n = keys.size();
  // Validate the parallel-vector contract at the boundary: the three columns
  // must describe the same rows. A mismatch is a programming error in the R
  // caller, not something to paper over with an out-of-range index.
  if (kinds.size() != n || sections.size() != n) {
    cpp11::stop(
        "keys, kinds, and sections must have the same length "
        "(got %td, %td, %td)",
        static_cast<std::ptrdiff_t>(n),
        static_cast<std::ptrdiff_t>(kinds.size()),
        static_cast<std::ptrdiff_t>(sections.size()));
  }

  // Pass 1: validate every row and tally the exact per-(section, kind) count.
  // Reserving each of the six sets to its true size (instead of a fraction of
  // n, which would over-allocate all six) means the insert pass below never
  // rehashes. Validation happens here so a bad row aborts before any build.
  std::size_t counts[2][3] = {{0, 0, 0}, {0, 0, 0}};
  for (R_xlen_t i = 0; i < n; ++i) {
    int sec = sections[i];
    if (sec != SEC_ICANN && sec != SEC_PRIVATE) {
      cpp11::stop("section code %d out of range: expected 0 (ICANN) or 1 "
                  "(PRIVATE)",
                  sec);
    }
    counts[sec][kind_index(std::string(kinds[i]))] += 1;
  }

  // Build into a unique_ptr so an exception anywhere below (e.g. a bad_alloc
  // while inserting) frees the Matcher; ownership is only released to R once
  // the external pointer and its finalizer are safely registered.
  std::unique_ptr<Matcher> m = std::make_unique<Matcher>();
  for (int s = 0; s < 2; ++s) {
    for (int k = 0; k < 3; ++k) {
      m->sets[s][k].reserve(counts[s][k]);
    }
  }

  // Pass 2: insert. Every row was validated in pass 1, so the lookups here
  // cannot fail.
  for (R_xlen_t i = 0; i < n; ++i) {
    int sec = sections[i];
    int k = kind_index(std::string(kinds[i]));
    m->sets[sec][k].insert(std::string(keys[i]));
  }

  SEXP ptr = PROTECT(R_MakeExternalPtr(m.get(), R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(ptr, matcher_finalizer, TRUE);
  m.release();  // R owns the Matcher now; the finalizer will delete it.
  UNPROTECT(1);
  return ptr;
  // gcov attributes an unreachable epilogue basic block to the closing brace
  // (the explicit `return` above always leaves first), so exclude that line
  // from coverage rather than chase a line no test can reach.
}  // # nocov

[[cpp11::register]]
list psl_match(SEXP matcher, strings hosts, int section_code) {
  const Matcher* m = static_cast<const Matcher*>(R_ExternalPtrAddr(matcher));
  // Guard the C boundary: a NULL address means the pointer was never built or
  // its finalizer already ran (R_ClearExternalPtr). Dereferencing it below
  // would be undefined behaviour, so stop with a clear message instead.
  if (m == nullptr) {
    cpp11::stop("matcher external pointer is NULL (not built or already freed)");
  }
  R_xlen_t n = hosts.size();
  writable::integers ps_depth(n);
  writable::integers kind(n);
  writable::integers section(n);
  // 1-based byte offsets into the canonical ASCII host, letting the R layer
  // derive the suffix / registrable / rule strings with a single vectorized
  // substr per column instead of a per-host paste loop. Inputs are canonical
  // ASCII (host_normalize output), so byte offset == character offset.
  //   ps_start  : where the public suffix (ps_depth labels) begins.
  //   rd_start  : where the registrable domain (ps_depth + 1 labels) begins;
  //               NA when there is no registrant label (n_labels <= ps_depth).
  //   ps1_start : where the wildcard rule body (ps_depth - 1 labels, i.e. the
  //               suffix minus its leftmost label) begins; NA when ps_depth < 2.
  writable::integers ps_start(n);
  writable::integers rd_start(n);
  writable::integers ps1_start(n);

  for (R_xlen_t i = 0; i < n; ++i) {
    std::string host = hosts[i];
    std::vector<std::string> labels = split_labels(host);
    int nlab = static_cast<int>(labels.size());

    // Right-anchored suffixes: suf[k] == labels[k..nlab-1] joined by '.'.
    std::vector<std::string> suf(nlab);
    suf[nlab - 1] = labels[nlab - 1];
    for (int k = nlab - 2; k >= 0; --k) {
      suf[k] = labels[k] + "." + suf[k + 1];
    }

    bool has_exc = false;
    int exc_ps = -1;
    int exc_sec = -1;
    int best_ps = 0;
    int best_kind = -1;
    int best_sec = -1;

    for (int k = 0; k < nlab; ++k) {
      const std::string& s = suf[k];
      int depth = nlab - k;

      // Exception: rule '!s' matches; prevailing suffix strips its leftmost
      // label, so its public-suffix depth is depth - 1. Exceptions take
      // precedence over every other rule; among them the longest wins.
      int es = find_section(m, KIND_EXCEPTION, s, section_code);
      if (es >= 0) {
        int ps = depth - 1;
        if (!has_exc || ps > exc_ps) {
          has_exc = true;
          exc_ps = ps;
          exc_sec = es;
        }
      }

      // Normal: rule 's' matches; public-suffix depth == depth.
      int ns = find_section(m, KIND_NORMAL, s, section_code);
      if (ns >= 0 && depth > best_ps) {
        best_ps = depth;
        best_kind = KIND_NORMAL;
        best_sec = ns;
      }

      // Wildcard: rule '*.s' matches only if there is a label to its left
      // (k >= 1); the '*' label is part of the public suffix, so depth + 1.
      // A normal rule of equal length wins the tie (it is reached first).
      if (k >= 1) {
        int ws = find_section(m, KIND_WILDCARD, s, section_code);
        if (ws >= 0 && depth + 1 > best_ps) {
          best_ps = depth + 1;
          best_kind = KIND_WILDCARD;
          best_sec = ws;
        }
      }
    }

    int pd;
    if (has_exc) {
      pd = exc_ps;
      ps_depth[i] = exc_ps;
      kind[i] = KIND_EXCEPTION;
      section[i] = exc_sec;
    } else if (best_kind >= 0) {
      pd = best_ps;
      ps_depth[i] = best_ps;
      kind[i] = best_kind;
      section[i] = best_sec;
    } else {
      // Implicit default '*' rule: the rightmost single label is its own
      // public suffix.
      pd = 1;
      ps_depth[i] = 1;
      kind[i] = 3;  // default
      section[i] = NA_INTEGER;
    }

    // Byte offset (1-based) where the rightmost `d` labels begin: suf[nlab - d]
    // is exactly that string, so it starts host.size() - suf[nlab - d].size()
    // bytes in. Valid only for 1 <= d <= nlab; NA_INTEGER otherwise (which the
    // R layer maps to an NA / absent string, matching the old derive_one guard
    // that returns NA for a public-suffix depth < 1).
    std::size_t host_len = host.size();
    auto start_for_depth = [&](int d) -> int {
      if (d < 1 || d > nlab) return NA_INTEGER;
      return static_cast<int>(host_len - suf[nlab - d].size()) + 1;
    };
    ps_start[i] = start_for_depth(pd);
    rd_start[i] = start_for_depth(pd + 1);
    ps1_start[i] = start_for_depth(pd - 1);
  }

  using namespace cpp11::literals;
  return writable::list({
      "ps_depth"_nm = ps_depth,
      "kind"_nm = kind,
      "section"_nm = section,
      "ps_start"_nm = ps_start,
      "rd_start"_nm = rd_start,
      "ps1_start"_nm = ps1_start,
  });
}

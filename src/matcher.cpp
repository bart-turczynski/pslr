// cpp11 core matcher for pslr (PRD s6, s8.2).
//
// Indexes the immutable rule set as a reverse-label trie -- keyed on labels
// RIGHT-TO-LEFT, with per-section end-of-rule flags at each node -- held behind
// an external pointer. Matching a host is a single descent from the trie root
// that consumes the host's labels right-to-left, running the official
// prevailing-rule algorithm in time proportional to the host's label count, not
// the rule count.
//
// The R layer owns normalization, terminal-dot handling, result shaping, and
// errors; this file only sees canonical lowercase ASCII hosts and returns the
// prevailing rule as (public-suffix depth, kind, section) per host.

#include <cpp11.hpp>

#include <memory>
#include <string>
#include <unordered_map>
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
// section_code 2 ("all") is handled as the fall-through in node_section().

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

// ---------------------------------------------------------------------------
// Reverse-label trie: the matcher's data structure.
//
// Instead of materializing every right-anchored suffix string per host and
// re-hashing overlapping tails, the rules are indexed in a trie keyed on labels
// RIGHT-TO-LEFT. A single descent from the host's rightmost label then visits
// exactly the suffixes that could match a rule, reading each node's per-section
// end-of-rule flags to drive the prevailing-rule selection.
// ---------------------------------------------------------------------------

// One node = one right-anchored label path (the empty path is the root). A node
// carries, per section, whether a rule of each kind ENDS at this exact path:
// ends[section][kind]. For a wildcard the stored path is its PARENT labels
// (post-'*.'); for an exception the full post-'!' labels; for a normal rule the
// key as-is -- the trie indexes the canonical rule keys, decomposed into labels.
struct TrieNode {
  bool ends[2][3] = {{false, false, false}, {false, false, false}};
  std::unordered_map<std::string, std::unique_ptr<TrieNode>> children;
};

// The trie matcher owns its root; the root's unique_ptr children cascade-free
// the whole tree when the TrieMatcher is deleted by its finalizer.
struct TrieMatcher {
  TrieNode root;
};

// Which section a rule of `kind` ending at `node` belongs to, under the request
// filter: for a single section only that one counts; for SECTION_ALL
// (section_code 2) ICANN wins a cross-section tie so the more authoritative
// boundary is reported.
int node_section(const TrieNode* node, int kind, int section_code) {
  if (section_code == SEC_ICANN) {
    return node->ends[SEC_ICANN][kind] ? SEC_ICANN : -1;
  }
  if (section_code == SEC_PRIVATE) {
    return node->ends[SEC_PRIVATE][kind] ? SEC_PRIVATE : -1;
  }
  if (node->ends[SEC_ICANN][kind]) return SEC_ICANN;
  if (node->ends[SEC_PRIVATE][kind]) return SEC_PRIVATE;
  return -1;
}

void trie_matcher_finalizer(SEXP ptr) {
  TrieMatcher* m = static_cast<TrieMatcher*>(R_ExternalPtrAddr(ptr));
  if (m == nullptr) return;
  delete m;
  R_ClearExternalPtr(ptr);
}

}  // namespace

// The matcher is exchanged with R as an opaque external pointer (a plain SEXP),
// because cpp11's code generator only forward-declares registered signatures
// and cannot see the TrieMatcher type. Building it once and reusing the pointer
// keeps the active matcher immutable after construction (PRD s8.2).
//
// Build the reverse-label trie behind the external pointer. Boundary validation
// (parallel-vector lengths, section in {0,1}, kind via kind_index) runs as a
// first pass so a bad row aborts before any node is created.
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

  // Pass 1: validate every row (section range + known kind) so a bad row stops
  // the build before any allocation.
  for (R_xlen_t i = 0; i < n; ++i) {
    int sec = sections[i];
    if (sec != SEC_ICANN && sec != SEC_PRIVATE) {
      cpp11::stop("section code %d out of range: expected 0 (ICANN) or 1 "
                  "(PRIVATE)",
                  sec);
    }
    kind_index(std::string(kinds[i]));
  }

  // Build into a unique_ptr so any exception below frees the whole trie;
  // ownership is released to R only once pointer + finalizer are registered.
  std::unique_ptr<TrieMatcher> m = std::make_unique<TrieMatcher>();
  for (R_xlen_t i = 0; i < n; ++i) {
    int sec = sections[i];
    int k = kind_index(std::string(kinds[i]));
    std::vector<std::string> labels = split_labels(std::string(keys[i]));
    // Walk the key's labels RIGHT-TO-LEFT (rightmost first), creating child
    // nodes as needed, then flag end-of-rule at the terminal node.
    TrieNode* node = &m->root;
    for (int j = static_cast<int>(labels.size()) - 1; j >= 0; --j) {
      std::unique_ptr<TrieNode>& child = node->children[labels[j]];
      if (!child) child = std::make_unique<TrieNode>();
      node = child.get();
    }
    node->ends[sec][k] = true;
  }

  SEXP ptr = PROTECT(R_MakeExternalPtr(m.get(), R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(ptr, trie_matcher_finalizer, TRUE);
  m.release();  // R owns the TrieMatcher now; the finalizer will delete it.
  UNPROTECT(1);
  return ptr;
  // gcov attributes an unreachable epilogue basic block to the closing brace
  // (the explicit `return` above always leaves first), so exclude that line
  // from coverage rather than chase a line no test can reach.
}  // # nocov

// Match hosts against the trie: one right-to-left label descent per host yields
// the 6-column result list the R engine consumes (public-suffix depth, kind,
// section, plus the three 1-based byte offsets).
[[cpp11::register]]
list psl_match(SEXP matcher, strings hosts, int section_code) {
  const TrieMatcher* m =
      static_cast<const TrieMatcher*>(R_ExternalPtrAddr(matcher));
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

    // Cumulative suffix byte-lengths for depths 1..nlab, derived from the host
    // ALONE (independent of the trie): the depth-d suffix is
    // label[nlab-d] + "." + suffix(d-1). This lets us compute start_for_depth
    // for any depth even where the trie descent stopped short.
    std::vector<std::size_t> suffix_len(nlab + 1, 0);
    for (int d = 1; d <= nlab; ++d) {
      suffix_len[d] =
          labels[nlab - d].size() + (d > 1 ? 1 + suffix_len[d - 1] : 0);
    }

    bool has_exc = false;
    int exc_ps = -1;
    int exc_sec = -1;
    int best_ps = 0;
    int best_kind = -1;
    int best_sec = -1;

    // One descent: from the root, consume labels right-to-left. At depth d the
    // node represents the depth-d suffix; read its flags to drive the
    // exception / normal / wildcard prevailing-rule selection. If a label has no
    // child, no rule shares these rightmost d labels at ANY depth >= d, so we
    // stop -- the host matches no further rule.
    const TrieNode* node = &m->root;
    for (int d = 1; d <= nlab; ++d) {
      auto it = node->children.find(labels[nlab - d]);
      if (it == node->children.end()) break;
      node = it->second.get();

      // Exception '!s': prevailing suffix strips its leftmost label -> ps
      // depth - 1. Exceptions beat everything; among them the longest wins.
      int es = node_section(node, KIND_EXCEPTION, section_code);
      if (es >= 0) {
        int ps = d - 1;
        if (!has_exc || ps > exc_ps) {
          has_exc = true;
          exc_ps = ps;
          exc_sec = es;
        }
      }

      // Normal 's': public-suffix depth == d.
      int ns = node_section(node, KIND_NORMAL, section_code);
      if (ns >= 0) {
        // Take on strictly greater depth, or on an equal-ps tie against a
        // wildcard already chosen (a normal rule of equal length wins the tie).
        // This descent runs depth-ascending, so the "normal wins the tie" rule
        // is made explicit here rather than falling out of visit order.
        if (d > best_ps || (d == best_ps && best_kind == KIND_WILDCARD)) {
          best_ps = d;
          best_kind = KIND_NORMAL;
          best_sec = ns;
        }
      }

      // Wildcard '*.s': matches only with a label to its left (d < nlab); the
      // '*' label joins the public suffix, so depth + 1. Strict '>' means it
      // can never displace a normal rule of equal resulting ps.
      if (d < nlab) {
        int ws = node_section(node, KIND_WILDCARD, section_code);
        if (ws >= 0 && d + 1 > best_ps) {
          best_ps = d + 1;
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

    // Byte offset (1-based) where the rightmost `d` labels begin: the depth-d
    // suffix is suffix_len[d] bytes long, so it starts host.size() -
    // suffix_len[d] bytes in. Valid only for 1 <= d <= nlab; NA_INTEGER
    // otherwise (which the R layer maps to an NA / absent string, matching the
    // old derive_one guard that returns NA for a public-suffix depth < 1).
    std::size_t host_len = host.size();
    auto start_for_depth = [&](int d) -> int {
      if (d < 1 || d > nlab) return NA_INTEGER;
      return static_cast<int>(host_len - suffix_len[d]) + 1;
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

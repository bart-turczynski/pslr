# Prune stale on-disk PSL cache snapshots

Removes superseded `psl-<hex>.dat` snapshot files from the user cache
directory, always keeping the snapshot named by the active commit marker
plus the `keep` most-recent other snapshots by modification time.

## Usage

``` r
psl_cache_prune(keep = 1L)
```

## Arguments

- keep:

  Number of previous snapshots to retain *in addition to* the active
  one, as a single non-negative whole number. The default `1` keeps the
  current snapshot and one previous snapshot (two `.dat` files). `0`
  keeps only the active snapshot; the active snapshot is never removed,
  even then.

## Value

Invisibly, a character vector of the removed snapshot file paths, empty
when nothing was pruned.

## Details

Each
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
that finds changed upstream content writes a new content-addressed
snapshot and repoints the commit marker at it, but never removes the
snapshot it supersedes; across many refreshes these accumulate.
`psl_cache_prune()` reclaims that space.

This operates on the *on-disk* snapshot files and is distinct from
`psl_cache_clear()`, which flushes the in-memory match-result cache for
the current session: pruning deletes stale `.dat` files from disk to
reclaim space, whereas clearing only discards computed query results.
Pruning never changes which list is active and never removes the active
snapshot, so the active matcher and a later `psl_use("cache")` keep
working.

When there is no cache directory or no commit marker (nothing has been
published yet), there is no active snapshot to anchor retention on, so
the call is a no-op that returns an empty vector rather than an error.

## See also

[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md),
which writes the snapshots this prunes;
[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md).

## Examples

``` r
if (interactive()) {
  psl_refresh(force = TRUE)
  psl_cache_prune() # keep the current snapshot and one previous
  psl_cache_prune(keep = 0) # keep only the active snapshot
}
```

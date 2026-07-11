# Construct a self-contained PSL engine

Builds a process-local Public Suffix List engine bound to a specific
snapshot, without switching the session-global active list that
[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
controls.

## Usage

``` r
psl_engine(source = "bundled", path = NULL)

# S3 method for class 'psl_snapshot'
print(x, ...)

# S3 method for class 'psl_engine'
print(x, ...)
```

## Arguments

- source:

  Where to load the list from: `"bundled"` (the pinned package snapshot)
  or `"path"` (a custom file).

- path:

  For `source = "path"`, a single readable PSL-format UTF-8 file
  containing one complete ICANN section and one complete PRIVATE
  section, using official markers. Must be `NULL` for any other source.

## Value

An engine object that the query functions can be pointed at (via their
`engine=` argument) to resolve hosts against the chosen snapshot in
isolation from the session-global list.

## Details

The engine is **process-local**: its compiled matcher is a C++ external
pointer that does not serialize across R sessions or parallel workers.
Saving and reloading an engine, or sending one to a worker, does not
carry the matcher. To persist an engine, serialize its snapshot
descriptor and rebuild the engine from it in the target process.

## See also

[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md),
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)

## Examples

``` r
engine <- psl_engine("bundled")
engine
#> <psl_engine>
#>  bundled (commit 9186eeeda85cef35b1551d00731464939c765cab), 10212 rules
#>   <process-local compiled matcher>

# A custom list from a file, entirely offline.
dat <- tempfile(fileext = ".dat")
writeLines(
  c(
    "// ===BEGIN ICANN DOMAINS===",
    "com",
    "// ===END ICANN DOMAINS===",
    "// ===BEGIN PRIVATE DOMAINS===",
    "example.com",
    "// ===END PRIVATE DOMAINS==="
  ),
  dat
)
psl_engine("path", path = dat)
#> <psl_engine>
#>  path (sha256:8aeef631a4edab8d0a35bf9a8587834b3059b938c0e66e6576770cade2c15180), 2 rules
#>   <process-local compiled matcher>
```

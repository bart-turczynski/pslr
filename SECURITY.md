# Security Policy

## Supported versions

`pslr` is distributed through CRAN. Security fixes are made against the
latest released version; please upgrade to the most recent release before
reporting.

| Version              | Supported          |
| -------------------- | ------------------ |
| Latest CRAN release  | :white_check_mark: |
| Older releases       | :x:                |

## Reporting a vulnerability

**Please do not report security vulnerabilities through any public issue
tracker.**

Email the maintainer at **bartek@turczynski.pl**. Put `pslr security` in the
subject line so the report is not mistaken for an ordinary bug.

Email is the only channel guaranteed to reach the maintainer. This policy
previously named GitHub private vulnerability reporting as the preferred
route; that channel no longer resolves and must not be used.

## What to expect

- We aim to acknowledge a report within **7 days**.
- We will investigate, work on a fix, and coordinate disclosure with you.
- We are happy to credit reporters in the release notes unless you prefer to
  remain anonymous.

## Scope

`pslr` is a C++ and R library for matching domain names against the Mozilla
Public Suffix List. It makes no network connections of its own and handles no
credentials. Its security surface is the safe handling of untrusted host
strings through the C++ PSL matcher (buffer handling, UTF-8 processing, and
trie traversal).

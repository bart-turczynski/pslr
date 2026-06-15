Feature: Public Suffix List queries

  The package answers public-suffix (eTLD) and registrable-domain (eTLD+1)
  queries against the bundled Public Suffix List, following the official
  prevailing-rule algorithm.

  Scenario: A normal multi-label ICANN suffix
    When I query the host "shop.example.co.uk"
    Then the public suffix is "co.uk"
    And the registrable domain is "example.co.uk"

  Scenario: A private-section rule prevails over its ICANN parent
    When I query the host "blog.github.io"
    Then the public suffix is "github.io"
    And the registrable domain is "blog.github.io"

  Scenario: Restricting to the ICANN section ignores private rules
    When I query the host "blog.github.io" in section "icann"
    Then the public suffix is "io"
    And the registrable domain is "github.io"

  Scenario: An unlisted name falls through to the implicit default rule
    When I query the host "example.madeuptld"
    Then the public suffix is "madeuptld"
    And the registrable domain is "example.madeuptld"

  Scenario: Invalid input is missing, not an error
    When I query the host "not a host"
    Then the public suffix is missing

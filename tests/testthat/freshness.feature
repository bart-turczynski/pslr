Feature: Offline freshness advice

  pslr reports what it actually knows about the list in use: when that snapshot
  was last confirmed by its source, and whether newer bytes have already been
  downloaded. Elapsed time alone means a check is due -- it never means the
  list is out of date, because only a source can say that.

  Scenario: A snapshot no check has ever confirmed
    Given a cached snapshot that was never checked against its source
    When I ask pslr about the "cache" snapshot
    Then the freshness state is "never_checked"
    And the report does not call the list outdated

  Scenario: A snapshot confirmed inside the reminder interval
    Given a cached snapshot confirmed 2 days ago
    When I ask pslr about the "cache" snapshot
    Then the freshness state is "confirmed_current"
    And the report says "Confirmed current"

  Scenario: A confirmation older than the reminder interval
    Given a cached snapshot confirmed 9 days ago
    When I ask pslr about the "cache" snapshot
    Then the freshness state is "check_due"
    And the report says "Freshness check due"
    And the report does not call the list outdated

  Scenario: Newer bytes downloaded but not yet activated
    Given a cached snapshot confirmed 1 days ago
    And a newer snapshot has been downloaded for the same source
    When I ask pslr about the "cache" snapshot
    Then the freshness state is "update_available"
    And the report says "A newer snapshot was downloaded"

  Scenario: A list of my own has no source to be checked against
    Given a list loaded from a file of my own
    When I ask pslr about the "active" snapshot
    Then the freshness state is "untracked"
    And the report does not call the list outdated

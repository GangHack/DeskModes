# --- matching names ---------------------------------------------------------
# One rule for everywhere a person names a monitor in words: layout, primary, a combo's membership.

Write-Host ''
Write-Host 'display name matching' -ForegroundColor White

Test-Case 'names: a pattern is found inside the display name' {
    Assert-True (Test-DisplayNameMatch -Pattern 'ULTRAGEAR' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3') 'part of the name'
}

Test-Case 'names: a pattern longer than the name still matches' {
    # The system knows the monitor as XG27AQDMGR, while a person writes what is written on the box.
    # The match is checked in both directions.
    Assert-True (Test-DisplayNameMatch -Pattern 'ROG STRIX XG27AQDMGR' -Label 'XG27AQDMGR' -ShortId 'AUSAA1D') 'contains the other way round'
}

Test-Case 'names: case does not matter, and the short id works too' {
    Assert-True (Test-DisplayNameMatch -Pattern 'ultrafine' -Label 'LG ULTRAFINE' -ShortId 'GSM5CBC') 'lower case pattern'
    Assert-True (Test-DisplayNameMatch -Pattern 'AUSAA1D' -Label 'XG27AQDMGR' -ShortId 'AUSAA1D') 'by short id'
}

Test-Case 'names: an empty pattern matches nothing' {
    # An empty string as a pattern would mean "fits everybody": -like '**' is true.
    Assert-True (-not (Test-DisplayNameMatch -Pattern '' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3')) 'blank matches nothing'
}

Test-Case 'names: an unrelated name does not match' {
    Assert-True (-not (Test-DisplayNameMatch -Pattern 'DELL' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3')) 'no false positive'
}

# --- совпадение названий ----------------------------------------------------
# Одно правило на всё, где человек называет монитор словами: layout, primary,
# состав комбинации.

Write-Host ''
Write-Host 'display name matching' -ForegroundColor White

Test-Case 'names: a pattern is found inside the display name' {
    Assert-True (Test-DisplayNameMatch -Pattern 'ULTRAGEAR' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3') 'part of the name'
}

Test-Case 'names: a pattern longer than the name still matches' {
    # Система знает монитор как XG27AQDMGR, а человек пишет так, как написано на
    # коробке. Совпадение проверяется в обе стороны.
    Assert-True (Test-DisplayNameMatch -Pattern 'ROG STRIX XG27AQDMGR' -Label 'XG27AQDMGR' -ShortId 'AUSAA1D') 'contains the other way round'
}

Test-Case 'names: case does not matter, and the short id works too' {
    Assert-True (Test-DisplayNameMatch -Pattern 'ultrafine' -Label 'LG ULTRAFINE' -ShortId 'GSM5CBC') 'lower case pattern'
    Assert-True (Test-DisplayNameMatch -Pattern 'AUSAA1D' -Label 'XG27AQDMGR' -ShortId 'AUSAA1D') 'by short id'
}

Test-Case 'names: an empty pattern matches nothing' {
    # Пустая строка как шаблон означала бы «подходит всем»: -like '**' истинно.
    Assert-True (-not (Test-DisplayNameMatch -Pattern '' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3')) 'blank matches nothing'
}

Test-Case 'names: an unrelated name does not match' {
    Assert-True (-not (Test-DisplayNameMatch -Pattern 'DELL' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3')) 'no false positive'
}

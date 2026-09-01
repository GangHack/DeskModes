# --- the last chosen mode ---------------------------------------------------

Write-Host ''
Write-Host 'the remembered mode' -ForegroundColor White

Test-Case 'last mode: nothing remembered yet gives null, not a crash' {
    if (Test-Path $script:LastModeFile) { Remove-Item $script:LastModeFile -Force }
    Assert-Null (Get-LastMode) 'no file, no mode'
}

Test-Case 'last mode: a saved mode comes back with its session stamp' {
    Save-LastMode -Key 'solo:XG27AQDMGR'
    $last = Get-LastMode
    Assert-Equal 'solo:XG27AQDMGR' $last.Key 'key'
    Assert-Equal (Get-SystemSessionId) $last.Session 'stamped with the current session'
    Assert-True ([bool]$last.When) 'remembered when it happened'
    Remove-Item $script:LastModeFile -Force
}

Test-Case 'last mode: a damaged file reads as nothing remembered' {
    Set-Content -Path $script:LastModeFile -Value '{ broken' -Encoding UTF8
    Assert-Null (Get-LastMode) 'unreadable file is not a mode'
    Remove-Item $script:LastModeFile -Force
}

Test-Case 'last mode: a file without a key reads as nothing remembered' {
    # This is how a file written only part of the way to the end would look.
    Set-Content -Path $script:LastModeFile -Value '{"session":"x","when":"y"}' -Encoding UTF8
    Assert-Null (Get-LastMode) 'no key, no mode'
    Remove-Item $script:LastModeFile -Force
}

# --- and whether the stamp belongs to the power-on we are living in ---------
# The answer decides whether the tray puts the remembered mode back over a desk somebody may have just
# arranged by hand, so it must not depend on where the boot instant happened to fall.

Test-Case 'session: the same power-on is recognised through the drift of the uptime counter' {
    # The second half of the stamp is worked out from the uptime, and two processes read that at two
    # different moments. Rounded to the minute and compared as a string, as it used to be, a boot that
    # landed near a minute boundary made a tray restart look like a fresh boot.
    Assert-True (Test-SameSession -Saved '12345/1700000000' -Current '12345/1700000000') 'the same stamp'
    Assert-True (Test-SameSession -Saved '12345/1700000000' -Current '12345/1700000041') 'forty-one seconds apart is one boot'
    Assert-True (-not (Test-SameSession -Saved '12345/1700000000' -Current '12345/1700086400')) 'a day apart is not'
    Assert-True (-not (Test-SameSession -Saved '12345/1700000000' -Current '99999/1700000000')) 'a shutdown in between is another session, whatever the clock says'
}

Test-Case 'session: a stamp of an older shape is compared the way it always was' {
    # last-mode.json outlives an update, and what was written before this is 'shutdown/yyyy-MM-dd HH:mm'.
    Assert-True (Test-SameSession -Saved '12345/2026-08-30 13:25' -Current '12345/2026-08-30 13:25') 'equal strings are one session'
    Assert-True (-not (Test-SameSession -Saved '12345/2026-08-30 13:25' -Current '12345/1700000000')) 'and anything else is not'
}

Test-Case 'session: the stamp this machine gives is two parts, and the second is a number' {
    $now = Get-SystemSessionId
    $parts = @($now -split '/')
    Assert-Equal 2 $parts.Count 'the shutdown time and the moment of boot'
    $seconds = [int64]0
    Assert-True ([int64]::TryParse($parts[1], [ref]$seconds)) 'whole seconds, comparable with slack'
    Assert-True (Test-SameSession -Saved $now) 'and it is our own session'
}

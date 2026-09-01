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

# --- re-stamping the session ------------------------------------------------
# An automatic switch is not a choice, so it must not write the key — but it HAS touched the desk, and the
# startup restore reads the session to tell a fresh boot from a tray that was merely restarted.

Test-Case 'session: an automatic switch re-stamps the session and leaves the choice alone' {
    Save-LastMode -Key 'solo:XG27AQDMGR'
    # A stamp from the power-on before this one, with the choice and its date untouched.
    '{"key":"solo:XG27AQDMGR","session":"1/2","when":"2026-08-30T09:00:00"}' |
        Set-Content -Path $script:LastModeFile -Encoding UTF8

    Update-LastModeSession

    $last = Get-LastMode
    Assert-Equal 'solo:XG27AQDMGR' $last.Key 'the choice is still the choice'
    Assert-Equal '2026-08-30T09:00:00' $last.When 'and it was still made then'
    Assert-Equal (Get-SystemSessionId) $last.Session 'only the stamp moved to this power-on'
    Remove-Item $script:LastModeFile -Force
}

Test-Case 'session: re-stamping what is already stamped writes nothing' {
    # Every automatic switch comes through here — a rule, a reapply, the mode restore after a hotplug —
    # so this is the common case and not the rare one, and each of them used to cost a read, a serialise
    # and a write of a file that came out identical.
    Save-LastMode -Key 'combo:Work'
    $before = [System.IO.File]::GetLastWriteTimeUtc($script:LastModeFile)
    $text = [System.IO.File]::ReadAllText($script:LastModeFile)

    Update-LastModeSession

    Assert-Equal $before ([System.IO.File]::GetLastWriteTimeUtc($script:LastModeFile)) 'the file was not rewritten'
    Assert-Equal $text ([System.IO.File]::ReadAllText($script:LastModeFile)) 'and says exactly what it said'
    Remove-Item $script:LastModeFile -Force
}

Test-Case 'session: nothing chosen yet means nothing to re-stamp' {
    if (Test-Path $script:LastModeFile) { Remove-Item $script:LastModeFile -Force }
    Update-LastModeSession
    Assert-True (-not (Test-Path $script:LastModeFile)) 'no record is invented out of an automatic switch'
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

Test-Case 'session: a stamp of an older shape leaves the displays alone' {
    # last-mode.json outlives an update, and what was written before this is 'shutdown/yyyy-MM-dd HH:mm'.
    # Answering "another session" to that fired the startup restore once on every installation in
    # existence: the mode came back over a desk the person had arranged themselves, one time only, and
    # nobody would ever have connected the two.
    #
    # The shutdown half decides it. That one is read out of the registry by both sides and changes at
    # every power-off, so a match means the power-on we are living in — bar a crash or a Reset, which
    # leave it untouched, and that costs one skipped restore against moving somebody's desk.
    Assert-True (Test-SameSession -Saved '12345/2026-08-30 13:25' -Current '12345/2026-08-30 13:25') 'equal strings are one session'
    Assert-True (Test-SameSession -Saved '12345/2026-08-30 13:25' -Current '12345/1700000000') 'an old stamp under the same shutdown time is this session'
    Assert-True (-not (Test-SameSession -Saved '99999/2026-08-30 13:25' -Current '12345/1700000000')) 'a shutdown in between is another one, old shape or not'
    Assert-True (-not (Test-SameSession -Saved 'nonsense' -Current '12345/1700000000')) 'and a stamp of no shape at all is nobody'
}

Test-Case 'session: the stamp this machine gives is two parts, and the second is a number' {
    $now = Get-SystemSessionId
    $parts = @($now -split '/')
    Assert-Equal 2 $parts.Count 'the shutdown time and the moment of boot'
    $seconds = [int64]0
    Assert-True ([int64]::TryParse($parts[1], [ref]$seconds)) 'whole seconds, comparable with slack'
    Assert-True (Test-SameSession -Saved $now) 'and it is our own session'
}

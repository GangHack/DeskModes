# --- the version ------------------------------------------------------------
# Two things read the version line — `Set-Display.ps1 status` and the About item in the tray menu —
# and one function assembles it. What is tested here is exactly that: not "the text is pretty" but that
# there is a version, that it parses as a version, and that what a person starts a bug report with made
# it into the line.

Write-Host ''
Write-Host 'the version' -ForegroundColor White

Test-Case 'version: it is there and reads as a version' {
    Assert-True ([bool]$script:Version) 'the version is set at all'
    Assert-True ($script:Version -match '^\d+\.\d+\.\d+$') "three numbers, nothing else (got '$script:Version')"
    # A Version, not a string: comparing as strings would declare 1.10.0 older than 1.9.0.
    Assert-True ([bool]([version]$script:Version)) 'and .NET parses it as one'
}

Test-Case 'version: the line names the tool, the version, Windows and PowerShell' {
    $line = Get-VersionLine

    Assert-True ($line -like 'ScreenDeck *') 'it starts with the name, so a pasted line is self-explaining'
    Assert-True ($line -like "*$script:Version*") 'the version itself is in there'
    Assert-True ($line -like '*Windows *') 'and the Windows build - most refusals here are a build plus a driver'
    Assert-True ($line -like '*PowerShell *') 'and which PowerShell ran it'
}

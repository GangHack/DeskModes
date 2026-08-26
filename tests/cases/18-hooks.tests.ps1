# --- команды вокруг переключения --------------------------------------------

Write-Host ''
Write-Host 'the commands around a switch' -ForegroundColor White

Test-Case 'hook: a plain command goes through cmd' {
    $launch = Get-HookLaunch -Command 'taskkill /im slack.exe'
    Assert-True ($launch.File -like '*cmd.exe') 'cmd.exe'
    Assert-Equal '/c taskkill /im slack.exe' $launch.Arguments 'the command as written'
}

Test-Case 'hook: a .ps1 goes through powershell, with the policy bypassed' {
    $launch = Get-HookLaunch -Command 'C:\tools\lights.ps1'
    Assert-True ($launch.File -like '*powershell.exe') 'powershell'
    Assert-True ($launch.Arguments -like '*-ExecutionPolicy Bypass*') 'own scripts must run without ceremony'
    Assert-True ($launch.Arguments -like '*-File "C:\tools\lights.ps1"*') 'the script path is quoted'
}

Test-Case 'hook: a quoted path with spaces survives, and so do its arguments' {
    $launch = Get-HookLaunch -Command '"C:\my tools\lights.ps1" -Room bedroom'
    Assert-True ($launch.Arguments -like '*-File "C:\my tools\lights.ps1" -Room bedroom*') 'path and arguments both'
}

Test-Case 'hook: nothing to run means nothing is returned' {
    Assert-Null (Get-HookLaunch -Command '') 'empty'
    Assert-Null (Get-HookLaunch -Command '   ') 'spaces only'
}

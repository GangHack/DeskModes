# --- which PowerShell -------------------------------------------------------
# The tool is Windows PowerShell 5.1 and nothing else, and `#Requires -Version 5.1` cannot say so: it
# is a MINIMUM, which PowerShell 7 satisfies. Under 7 the load used to run on until Add-Type, and the
# person got a C# compiler error about a type they never wrote. The guard turns that into a sentence
# naming the shell to use. What is tested is what a later edit can break without noticing: that the
# guard is still there, and that it still stands in front of the thing it protects.

Write-Host ''
Write-Host 'which PowerShell' -ForegroundColor White

$script:CoreSource = [System.IO.File]::ReadAllText((Join-Path $root 'DisplayCore.ps1'))

Test-Case 'edition: PowerShell 7 is refused before anything is compiled' {
    $guard = $script:CoreSource.IndexOf('$PSVersionTable.PSEdition')
    Assert-True ($guard -ge 0) 'the guard is there at all'

    # The Add-Type is what actually fails on .NET Core. A guard below it guards nothing: the refusal
    # would arrive after the error it exists to replace.
    $compile = $script:CoreSource.IndexOf('Add-Type -TypeDefinition')
    Assert-True ($compile -ge 0) 'and the Add-Type it stands in front of is there too'
    Assert-True ($guard -lt $compile) 'the refusal comes first'
}

Test-Case 'edition: the refusal says what to do instead' {
    $guard = $script:CoreSource.IndexOf('$PSVersionTable.PSEdition')
    $said = $script:CoreSource.Substring($guard, 600)

    # A refusal that only says "no" costs the reader the evening we are trying to save them.
    Assert-True ($said -like '*5.1*') 'it names the version that works'
    Assert-True ($said -like '*.cmd*') 'and the .cmd files, which call the right shell already'
    Assert-True ($said -like '*powershell -ExecutionPolicy Bypass*') 'and the command for doing it by hand'
}
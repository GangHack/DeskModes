<#
    PSScriptAnalyzer settings — the third gate in tools\check.ps1.

    The exclusion list was not made up but drawn from an actual run of the default rules
    (PSScriptAnalyzer 1.25.0, 2026-08-26): 803 findings over 10 files, exactly seven rules. Each one
    was worked through and either switched off with a justification below or fixed by hand. After
    that the analyzer is clean, which means any new finding is new rather than drowned in noise.

    The one genuine finding out of those 803: `$args = New-Object ...EventArgs` in three places in
    the tests — an assignment to an automatic variable. Fixed by renaming rather than by an exclusion.

    A rule is switched off WHOLE and only when it argues with the project's style deliberately. If
    you add an exclusion, add a "why" line with it: without one, nobody will be able to tell a
    deliberate decision from something swept under the carpet a month later.
#>
@{
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # Coloured output is the job of the CLI and the tray: a person reads "on / off /
        # primary" with their eyes and not through a pipeline. Write-Output instead of
        # Write-Host would hand these lines to the pipeline, where the calling .cmd is waiting.
        'PSAvoidUsingWriteHost'

        # The rule wants -WhatIf/-Confirm on everything named Set-/New-/Remove-. Here that is
        # the name of 54 INTERNAL functions (New-UiTextBlock, Set-UiMode, New-FakeMonitor):
        # these are not cmdlets, nobody calls them from outside, and ShouldProcess plumbing
        # on each of them is pure ceremony. A real dry run already exists and lives where it
        # belongs: Set-Display.ps1 -DryRun.
        'PSUseShouldProcessForStateChangingFunctions'

        # The plural carries meaning here: Get-DisplayModes returns several modes,
        # Save-AppliedModes saves several. Renaming it to Get-DisplayMode would be lying
        # about what the function hands back.
        'PSUseSingularNouns'

        # The rule looks only at the same scope and therefore lies three times here:
        # (1) Set-DisplayMode uses $Width/$Height/$Hz inside the $build script block in
        # DisplayCore.ps1; (2) Displays.ps1 reads $NoHotkeys inside a function;
        # (3) $sender/$e are a .NET handler's signature, and the fakes in the tests have to
        # repeat the real function's signature even when the argument itself is of no use to
        # them. Not one genuine hit out of 44 findings.
        'PSReviewUnusedParameter'

        # `catch { }` here always comes with a comment explaining why swallowing the error is
        # the right thing: the log must not bring a monitor switch down, the monitor did not
        # answer over DDC, the button was released in time. The rule wants a throw or a
        # Write-Error — that is, exactly the behaviour that in these places IS the breakage.
        # The comment is mandatory, and it is the review that checks that, not the analyzer.
        'PSAvoidUsingEmptyCatchBlock'

        # $sender and $e are a .NET event handler's signature, and the handlers really do read
        # them ($sender.Text, $sender.Tag, $sender.DragMove()). PowerShell puts that same value
        # into $sender, so there is no shadowing in substance, while renaming means editing two
        # dozen lines in the project's most fragile code (WPF) for the sake of a name. This
        # rule's one genuine hit — $args in the tests — was fixed by renaming.
        'PSAvoidAssignmentToAutomaticVariable'

        # 509 findings out of 803, and every one of them Information. The rule counts any
        # positional call as a violation, Join-Path $root 'x' and Assert-Equal 5 $x included.
        # The project has a rule of its own on this, narrower and more useful: names are
        # mandatory when there are two or more arguments and they are of the same kind (see
        # AGENTS.md and docs/notes.md, "Argument order: name them, do not count them"). The
        # review is what holds it.
        'PSAvoidUsingPositionalParameters'
    )
}

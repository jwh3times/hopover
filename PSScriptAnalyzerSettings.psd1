# PSScriptAnalyzer settings for every tracked *.ps1 (CI's windows job and the fast checks).
# Errors and warnings fail; information-level rules (positional parameters) are left out.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # These are interactive console scripts: coloured Write-Host output is the interface.
        'PSAvoidUsingWriteHost'
        # Script and helper names are part of the documented command line (Export-Settings,
        # Save-Drivers, ...), not module cmdlets.
        'PSUseSingularNouns'
        'PSUseApprovedVerbs'
        # Every script that changes the machine takes -DryRun instead of -WhatIf/-Confirm, and the
        # New-* helpers only build objects.
        'PSUseShouldProcessForStateChangingFunctions'
        # Best-effort probes (an optional tool's JSON, a file that may be unreadable) fall back to
        # their default on purpose.
        'PSAvoidUsingEmptyCatchBlock'
        # The analyzer reads one file at a time: it misses variables a dot-sourced lib\Common.ps1
        # defines, switches read inside nested functions, and switches that only pick a parameter
        # set.
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSReviewUnusedParameter'
    )
}

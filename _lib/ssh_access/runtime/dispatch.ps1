Set-StrictMode -Version 2.0

function Invoke-SshAccessHelpCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    if ($Arguments.Count -gt 1) {
        throw 'Help accepts at most one language: en or zh.'
    }

    $Language = 'zh'
    if ($Arguments.Count -eq 1) {
        $Language = $Arguments[0].ToLowerInvariant()
        if (@('zh', 'en') -notcontains $Language) {
            throw "Unsupported help language '$($Arguments[0])'. Use en or zh."
        }
    }

    Show-SshAccessHelp -Context $Context -Language $Language
    return 0
}

function Invoke-SshAccessMain {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    Assert-SshAccessEntryProtocol
    $HelpContext = New-SshAccessHelpContext -KitRoot $script:SshAccessKitRoot
    if ($Arguments.Count -eq 0) {
        return Invoke-SshAccessHelpCommand `
            -Context $HelpContext `
            -Arguments @()
    }

    $Command = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    if (@('-h', '--help', '.h') -contains $Command) {
        return Invoke-SshAccessHelpCommand `
            -Context $HelpContext `
            -Arguments $Rest
    }
    if ($Command -eq '.help') {
        return Invoke-SshAccessHelpCommand `
            -Context $HelpContext `
            -Arguments $Rest
    }

    $Context = New-SshAccessContext -KitRoot $script:SshAccessKitRoot
    switch ($Command) {
        '.status' {
            return Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments $Rest
        }
        '.key' {
            return Invoke-SshAccessKeyCommand -Context $Context -Arguments $Rest
        }
        '.private' {
            return Invoke-SshAccessPrivateCommand -Context $Context -Arguments $Rest
        }
        '.public' {
            return Invoke-SshAccessPublicCommand -Context $Context -Arguments $Rest
        }
        '.global' {
            return Invoke-SshAccessGlobalCommand -Context $Context -Arguments $Rest
        }
        default {
            throw "Unknown SSH Access command '$($Arguments[0])'. Run '$($Context.CommandName) .help'."
        }
    }
}

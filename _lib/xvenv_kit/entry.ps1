Set-StrictMode -Version 2.0

function Write-XvenvUsage {
    param([Parameter(Mandatory = $true)][object]$Catalog)

    Write-Host 'Usage:'
    Write-Host "  $(Get-XvenvSetCommandExample $Catalog)"
    Write-Host '  xvenv status [--json]'
    Write-Host '  xvenv tools [--json]'
    Write-Host '  xvenv exec <program> [args...]'
    Write-Host '  xvenv link'
    Write-Host '  xvenv --help [zh|en]'
    Write-Host '  xvenv'
}

function Test-XvenvJsonOption {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return $Arguments.Count -eq 1 -and
        $Arguments[0].Equals('--json', [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-XvenvHelpCommand {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object[]]$Values,
        [switch]$AllowDefaultChange
    )

    if ($Values.Count -gt 2) {
        if ($AllowDefaultChange) {
            throw 'Usage: xvenv help [zh|en|default=<zh|en>]'
        }
        throw 'Usage: xvenv --help [zh|en]'
    }
    if ($Values.Count -eq 2 -and
        ([string]$Values[1]) -match '^default=(?<language>.*)$') {
        if (-not $AllowDefaultChange) {
            throw 'Persistent help settings require: xvenv help default=<zh|en>'
        }
        return Set-XvenvDefaultHelpLanguage `
            -Context $Context `
            -Language ([string]$Matches['language'])
    }
    $Language = if ($Values.Count -eq 2) {
        [string]$Values[1]
    } else {
        $null
    }
    return Invoke-XvenvHelp -Context $Context -Language $Language
}

function Invoke-XvenvMain {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments = @(),
        [AllowNull()][object]$Context = $null
    )

    if ($null -eq $Context) {
        $Context = New-XvenvContext
    }
    $Values = @($Arguments)
    if ($Values.Count -eq 0) {
        return Invoke-XvenvOpenTerminal -Context $Context
    }
    switch (([string]$Values[0]).ToLowerInvariant()) {
        'set' {
            [string[]]$Tools = @()
            if ($Values.Count -gt 1) {
                $Tools = [string[]]$Values[1..($Values.Count - 1)]
            }
            return Invoke-XvenvSet -Context $Context -ToolNames $Tools
        }
        'status' {
            [string[]]$Options = @()
            if ($Values.Count -gt 1) {
                $Options = [string[]]$Values[1..($Values.Count - 1)]
            }
            if ($Options.Count -gt 0 -and -not (Test-XvenvJsonOption $Options)) {
                throw 'Usage: xvenv status [--json]'
            }
            return Invoke-XvenvStatus `
                -Context $Context `
                -Json:($Options.Count -eq 1)
        }
        'tools' {
            [string[]]$Options = @()
            if ($Values.Count -gt 1) {
                $Options = [string[]]$Values[1..($Values.Count - 1)]
            }
            if ($Options.Count -gt 0 -and -not (Test-XvenvJsonOption $Options)) {
                throw 'Usage: xvenv tools [--json]'
            }
            return Invoke-XvenvTools `
                -Context $Context `
                -Json:($Options.Count -eq 1)
        }
        'exec' {
            if ($Values.Count -lt 2) {
                throw 'Usage: xvenv exec <program> [args...]'
            }
            [string[]]$ProgramArguments = @()
            if ($Values.Count -gt 2) {
                $ProgramArguments = [string[]]$Values[2..($Values.Count - 1)]
            }
            return Invoke-XvenvExec `
                -Context $Context `
                -Program ([string]$Values[1]) `
                -Arguments $ProgramArguments
        }
        'link' {
            if ($Values.Count -ne 1) {
                throw 'Usage: xvenv link'
            }
            return Invoke-XvenvLink -Context $Context
        }
        '--xvenv-follow-link' {
            if ($Values.Count -ne 1) {
                throw 'The xvenv link is invalid. Run xvenv link again.'
            }
            return Invoke-XvenvFollowLink -Context $Context
        }
        'help' {
            return Invoke-XvenvHelpCommand `
                -Context $Context `
                -Values $Values `
                -AllowDefaultChange
        }
        '--help' {
            return Invoke-XvenvHelpCommand -Context $Context -Values $Values
        }
        '-h' {
            return Invoke-XvenvHelpCommand -Context $Context -Values $Values
        }
        '/?' {
            return Invoke-XvenvHelpCommand -Context $Context -Values $Values
        }
        default {
            Write-XvenvUsage -Catalog $Context.Catalog
            throw "Unsupported xvenv command '$($Values[0])'."
        }
    }
}

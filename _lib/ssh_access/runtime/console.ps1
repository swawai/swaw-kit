Set-StrictMode -Version 2.0

function Write-SshAccessHeading {
    param([Parameter(Mandatory = $true)][string]$Text)

    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}

function Write-SshAccessField {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    $DisplayValue = if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        '-'
    } else {
        [string]$Value
    }
    Write-Host ('  {0,-18} {1}' -f ($Name + ':'), $DisplayValue)
}

function Write-SshAccessWarning {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Test-SshAccessAccessDeniedError {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Exception = $ErrorRecord.Exception
    while ($null -ne $Exception) {
        if ($Exception -is [UnauthorizedAccessException]) {
            return $true
        }
        $Exception = $Exception.InnerException
    }
    return $ErrorRecord.Exception.Message -match
        '(?i)(access (?:to .+ )?is denied|access denied)'
}

function Get-SshAccessErrorSummary {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    if (Test-SshAccessAccessDeniedError -ErrorRecord $ErrorRecord) {
        return 'Access denied.'
    }
    return $ErrorRecord.Exception.Message
}

function Format-SshAccessCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $DisplayArguments = foreach ($Argument in @($Arguments)) {
        if ($Argument -match '[\s"]') {
            '"' + $Argument.Replace('"', '\"') + '"'
        } else {
            $Argument
        }
    }

    if (@($DisplayArguments).Count -eq 0) {
        return $CommandName
    }
    return "$CommandName $([string]::Join(' ', [string[]]@($DisplayArguments)))"
}

function Assert-SshAccessNoArguments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Usage
    )

    if ($Arguments.Count -ne 0) {
        throw "Unexpected argument '$($Arguments[0])'. Usage: $Usage"
    }
}

function Get-SshAccessSwitchSet {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Usage
    )

    $Values = @{}
    foreach ($Argument in @($Arguments)) {
        if ($Allowed -notcontains $Argument) {
            throw "Unexpected argument '$Argument'. Usage: $Usage"
        }
        if ($Values.ContainsKey($Argument)) {
            throw "Duplicate option '$Argument'. Usage: $Usage"
        }
        $Values[$Argument] = $true
    }
    return $Values
}

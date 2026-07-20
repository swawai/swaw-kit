[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Get-GitConfigValue {
    param([string]$Key)

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $lines = @(& git config --get $Key 2>$null | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0 -or $lines.Count -eq 0) {
        return "<unset>"
    }
    return ($lines -join " ").Trim()
}

function New-InfoRow {
    param(
        [string]$Label,
        [string]$Value
    )

    return [pscustomobject]@{
        Label = $Label
        Value = $Value
    }
}

function Write-InfoRows {
    param([object[]]$Rows)

    $labelWidth = ($Rows | ForEach-Object { ($_.Label + ":").Length } | Measure-Object -Maximum).Maximum
    foreach ($row in $Rows) {
        $label = ($row.Label + ":").PadRight($labelWidth)
        Write-Host "  $label  $($row.Value)"
    }
}

try {
    $gitName = Get-GitConfigValue "user.name"
    $gitEmail = Get-GitConfigValue "user.email"

    $accessTag = switch ($env:GIT_ID_TRANSPORT) {
        "ssh" { "ssh" }
        "https" {
            switch ($env:GIT_ID_HTTPS_PROVIDER) {
                "github" { "https.github" }
                "gitlab" { "https.gitlab" }
                default { throw "Unsupported HTTPS provider '$($env:GIT_ID_HTTPS_PROVIDER)'." }
            }
        }
        default { throw "Unsupported access transport '$($env:GIT_ID_TRANSPORT)'." }
    }

    $configRows = @(
        New-InfoRow "Entry" $env:GIT_ID_ENTRY_FILE
        New-InfoRow "Name" $env:GIT_ID_NAME
        New-InfoRow "Email" $env:GIT_ID_EMAIL
        New-InfoRow "Access" $accessTag
    )

    if ($env:GIT_ID_TRANSPORT -eq "ssh") {
        # GIT_SSH_COMMAND is intentionally free-form and may contain proxy
        # credentials. Report its presence without copying secrets to logs.
        $configRows += New-InfoRow "SSH command" "configured"
    } else {
        $authorization = & {
            . "$PSScriptRoot\https-auth.ps1"
            Invoke-HttpsStatus `
                -Provider $env:GIT_ID_HTTPS_PROVIDER `
                -AccountHost $env:GIT_ID_HTTPS_HOST `
                -ExpectedUser $env:GIT_ID_HTTPS_USER `
                -Namespace $env:GIT_ID_CREDENTIAL_NAMESPACE `
                -CommandName $env:GIT_ID_ENTRY_COMMAND
        }
        $configRows += New-InfoRow "HTTPS authorization" $authorization.Trim()
        $configRows += New-InfoRow "Credential namespace" $env:GIT_ID_CREDENTIAL_NAMESPACE
    }

    $signingStatus = switch ($env:GIT_ID_SIGNING_ENABLED) {
        "false" { "disabled" }
        "true" { "enabled ($($env:GIT_ID_GPG_FORMAT))" }
        default { throw "Unsupported commit signing state '$($env:GIT_ID_SIGNING_ENABLED)'." }
    }
    $configRows += New-InfoRow "Commit signing" $signingStatus
    if ($env:GIT_ID_SIGNING_ENABLED -eq "true") {
        $configRows += New-InfoRow "Signing key" $env:GIT_ID_SIGNING_KEY
    }

    Write-Host "Config:"
    Write-InfoRows $configRows
    Write-Host ""
    Write-Host "Git sees:"
    Write-InfoRows @(
        New-InfoRow "Name" $gitName
        New-InfoRow "Email" $gitEmail
    )
    exit 0
} catch {
    Write-Host "[ERROR] Unable to show identity info: $($_.Exception.Message)"
    exit 1
}

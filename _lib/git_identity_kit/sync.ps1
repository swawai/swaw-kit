[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("write", "dry-run", "clear")]
    [string]$Mode,

    [string]$EntryCommand = "git_identity",

    [string]$EntryFile = ""
)

$ErrorActionPreference = "Stop"

function Clear-InjectedGitConfigEnvironment {
    $count = 0
    if ([int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$count)) {
        for ($i = 0; $i -lt $count; $i++) {
            Remove-Item "Env:GIT_CONFIG_KEY_$i" -ErrorAction SilentlyContinue
            Remove-Item "Env:GIT_CONFIG_VALUE_$i" -ErrorAction SilentlyContinue
        }
    }

    Remove-Item "Env:GIT_CONFIG_COUNT" -ErrorAction SilentlyContinue
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & git @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = "git exited with code $exitCode"
        }

        throw $text
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text     = $text
    }
}

function Assert-GitRepository {
    $result = Invoke-Git -Arguments @("rev-parse", "--git-dir") -AllowFailure
    if ($result.ExitCode -ne 0) {
        Write-Host "[ERROR] sync must be run inside a Git repository."
        exit 1
    }
}

function Get-LocalConfigValue {
    param([string]$Key)

    $result = Invoke-Git -Arguments @("config", "--local", "--get", $Key) -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }

    return $result.Text
}

function Set-LocalConfigValue {
    param(
        [string]$Key,
        [string]$Value
    )

    Invoke-Git -Arguments @("config", "--local", $Key, $Value) | Out-Null
}

function Unset-LocalConfigValue {
    param([string]$Key)

    Invoke-Git -Arguments @("config", "--local", "--unset-all", $Key) -AllowFailure | Out-Null
}

function New-ManagedConfigEntries {
    $entries = @(
        [pscustomobject]@{
            ConfigKey  = "user.name"
            Value      = $env:GIT_IDENTITY_NAME
            MarkerKey  = "swaw-kit-git.user-name"
            Required   = $true
        },
        [pscustomobject]@{
            ConfigKey  = "user.email"
            Value      = $env:GIT_IDENTITY_EMAIL
            MarkerKey  = "swaw-kit-git.user-email"
            Required   = $true
        }
    )

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_SSH_COMMAND)) {
        $entries += [pscustomobject]@{
            ConfigKey = "core.sshCommand"
            Value     = $env:GIT_SSH_COMMAND
            MarkerKey = "swaw-kit-git.ssh-command"
            Required  = $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_IDENTITY_SIGNING_KEY)) {
        $entries += [pscustomobject]@{
            ConfigKey = "user.signingkey"
            Value     = $env:GIT_IDENTITY_SIGNING_KEY
            MarkerKey = "swaw-kit-git.signing-key"
            Required  = $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_IDENTITY_GPG_FORMAT)) {
        $entries += [pscustomobject]@{
            ConfigKey = "gpg.format"
            Value     = $env:GIT_IDENTITY_GPG_FORMAT
            MarkerKey = "swaw-kit-git.gpg-format"
            Required  = $false
        }
    }

    foreach ($entry in $entries) {
        if ($entry.Required -and [string]::IsNullOrWhiteSpace($entry.Value)) {
            Write-Host "[ERROR] Missing required Git identity value for $($entry.ConfigKey)."
            exit 1
        }
    }

    return @($entries)
}

function Write-DryRun {
    param([object[]]$Entries)

    Write-Host "SWAW Kit Git sync (DRY RUN)"
    Write-Host "Would write local Git config:"
    foreach ($entry in $Entries) {
        Write-Host "  $($entry.ConfigKey) = $($entry.Value)"
    }

    Write-Host "Would write SWAW Kit Git marker:"
    Write-Host "  swaw-kit-git.managed = true"
    Write-Host "  swaw-kit-git.entry = $EntryCommand"
    if (-not [string]::IsNullOrWhiteSpace($EntryFile)) {
        Write-Host "  swaw-kit-git.entry-file = $EntryFile"
    }

    foreach ($entry in $Entries) {
        Write-Host "  $($entry.MarkerKey) = $($entry.Value)"
    }
}

function Write-Sync {
    param([object[]]$Entries)

    Clear-StaleManagedConfigEntries $Entries

    foreach ($entry in $Entries) {
        Set-LocalConfigValue $entry.ConfigKey $entry.Value
    }

    Set-LocalConfigValue "swaw-kit-git.managed" "true"
    Set-LocalConfigValue "swaw-kit-git.entry" $EntryCommand
    if (-not [string]::IsNullOrWhiteSpace($EntryFile)) {
        Set-LocalConfigValue "swaw-kit-git.entry-file" $EntryFile
    }

    foreach ($entry in $Entries) {
        Set-LocalConfigValue $entry.MarkerKey $entry.Value
    }

    Write-Host "SWAW Kit Git sync wrote local config for $EntryCommand."
}

function Clear-StaleManagedConfigEntries {
    param([object[]]$CurrentEntries)

    $currentMarkerKeys = @{}
    foreach ($entry in $CurrentEntries) {
        $currentMarkerKeys[$entry.MarkerKey] = $true
    }

    foreach ($entry in Get-MarkerEntries) {
        if ($currentMarkerKeys.ContainsKey($entry.MarkerKey)) {
            continue
        }

        $current = Get-LocalConfigValue $entry.ConfigKey
        if ($null -ne $current -and $current -ne $entry.Value) {
            Write-Host "[ERROR] Refusing to remove stale managed value changed since the last SWAW Kit Git sync."
            Write-Host "  $($entry.ConfigKey)"
            Write-Host "    synced:  $($entry.Value)"
            Write-Host "    current: $current"
            exit 1
        }

        if ($null -ne $current) {
            Unset-LocalConfigValue $entry.ConfigKey
        }
        Unset-LocalConfigValue $entry.MarkerKey
    }
}

function Get-MarkerEntries {
    $entries = @(
        [pscustomobject]@{
            ConfigKey = "user.name"
            MarkerKey = "swaw-kit-git.user-name"
            Value     = Get-LocalConfigValue "swaw-kit-git.user-name"
        },
        [pscustomobject]@{
            ConfigKey = "user.email"
            MarkerKey = "swaw-kit-git.user-email"
            Value     = Get-LocalConfigValue "swaw-kit-git.user-email"
        },
        [pscustomobject]@{
            ConfigKey = "core.sshCommand"
            MarkerKey = "swaw-kit-git.ssh-command"
            Value     = Get-LocalConfigValue "swaw-kit-git.ssh-command"
        },
        [pscustomobject]@{
            ConfigKey = "user.signingkey"
            MarkerKey = "swaw-kit-git.signing-key"
            Value     = Get-LocalConfigValue "swaw-kit-git.signing-key"
        },
        [pscustomobject]@{
            ConfigKey = "gpg.format"
            MarkerKey = "swaw-kit-git.gpg-format"
            Value     = Get-LocalConfigValue "swaw-kit-git.gpg-format"
        }
    )

    return @($entries | Where-Object { $null -ne $_.Value })
}

function Clear-Sync {
    $managed = Get-LocalConfigValue "swaw-kit-git.managed"
    if ($managed -ne "true") {
        Write-Host "[ERROR] No SWAW Kit Git sync marker found in this repository."
        exit 1
    }

    $markerEntry = Get-LocalConfigValue "swaw-kit-git.entry"
    if (-not [string]::IsNullOrWhiteSpace($markerEntry) -and $markerEntry -ne $EntryCommand) {
        Write-Host "[ERROR] This repository was synced by '$markerEntry', not '$EntryCommand'."
        Write-Host "Run '$markerEntry .sync --clear' or edit .git/config manually."
        exit 1
    }

    $entries = Get-MarkerEntries
    $changed = @()
    foreach ($entry in $entries) {
        $current = Get-LocalConfigValue $entry.ConfigKey
        if ($null -ne $current -and $current -ne $entry.Value) {
            $changed += [pscustomobject]@{
                ConfigKey = $entry.ConfigKey
                Expected  = $entry.Value
                Current   = $current
            }
        }
    }

    if ($changed.Count -gt 0) {
        Write-Host "[ERROR] Refusing to clear values changed since the last SWAW Kit Git sync."
        foreach ($item in $changed) {
            Write-Host "  $($item.ConfigKey)"
            Write-Host "    synced:  $($item.Expected)"
            Write-Host "    current: $($item.Current)"
        }
        exit 1
    }

    foreach ($entry in $entries) {
        if ($null -ne (Get-LocalConfigValue $entry.ConfigKey)) {
            Unset-LocalConfigValue $entry.ConfigKey
        }
    }

    Invoke-Git -Arguments @("config", "--local", "--remove-section", "swaw-kit-git") -AllowFailure | Out-Null
    Write-Host "SWAW Kit Git sync marker and unchanged managed config were cleared."
}

Clear-InjectedGitConfigEnvironment
Assert-GitRepository

switch ($Mode) {
    "dry-run" {
        Write-DryRun (New-ManagedConfigEntries)
    }
    "write" {
        Write-Sync (New-ManagedConfigEntries)
    }
    "clear" {
        Clear-Sync
    }
}

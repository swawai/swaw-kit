[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("write", "dry-run", "clear")]
    [string]$Mode,

    [ValidateNotNullOrEmpty()]
    [string]$EntryCommand = "git_identity",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EntryFile,

    [Parameter(DontShow = $true)]
    [ValidateRange(0, 2147483647)]
    [int]$TestFailConfigMutationAt = 0
)

$ErrorActionPreference = "Stop"
$EntryFile = [System.IO.Path]::GetFullPath($EntryFile)
$script:RepositoryPath = ""
$script:ConfigMutationCount = 0
$script:TestFailConfigMutationAt = $TestFailConfigMutationAt

. "$PSScriptRoot\sync-entries.ps1"

function Clear-InjectedGitConfigEnvironment {
    Remove-Item "Env:GIT_CONFIG_COUNT" -ErrorAction SilentlyContinue
    Remove-Item "Env:GIT_CONFIG_PARAMETERS" -ErrorAction SilentlyContinue
    foreach ($name in @(
        "GIT_DIR",
        "GIT_EXEC_PATH",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
        "GIT_NAMESPACE",
        "GIT_CONFIG",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_NOSYSTEM"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$CaptureFailure
    )

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & git -C $script:RepositoryPath @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0 -and -not $CaptureFailure) {
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
    $result = Invoke-Git -Arguments @("rev-parse", "--git-dir") -CaptureFailure
    if ($result.ExitCode -ne 0) {
        if ($result.Text -match 'not a git repository') {
            Write-Host "[ERROR] sync must be run inside a Git repository."
            exit 1
        }
        throw $result.Text
    }
}

function Get-LocalConfigValue {
    param([string]$Key)

    $values = @(Get-LocalConfigValues $Key)
    if ($values.Count -eq 0) {
        return $null
    }
    if ($values.Count -ne 1) {
        throw "Expected exactly one local Git config value for '$Key', found $($values.Count)."
    }

    return $values[0]
}

function Get-LocalConfigValues {
    param([string]$Key)

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& git -C $script:RepositoryPath config --local --get-all $Key 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -eq 1 -and $output.Count -eq 0) {
        return @()
    }
    if ($exitCode -ne 0) {
        $text = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = "git config --get-all '$Key' exited with code $exitCode"
        }
        throw $text
    }
    return $output
}

. "$PSScriptRoot\sync-rollback.ps1"

function Test-SensitiveConfigDisplay {
    param(
        [string]$Key,
        [string[]]$Values
    )

    $normalized = $Key.ToLowerInvariant()
    if ($normalized -in @(
        "credential.helper",
        "core.sshcommand",
        "swaw-kit-git.credential-helper",
        "swaw-kit-git.ssh-command"
    )) {
        return $true
    }
    if ($normalized -match '^credential\..*\.helper$') {
        return $true
    }
    if ($normalized -eq "swaw-kit-git.access" -and @($Values | Where-Object { $_ -match '^ssh:' }).Count -gt 0) {
        return $true
    }
    return $normalized -match '(^|\.)(password|token|secret|authorization|cookiefile|sslkey|sslcert)($|\.)'
}

function Format-ConfigValuesForDisplay {
    param(
        [string]$Key,
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    $items = @($Values)
    if ($items.Count -eq 0) {
        return "<absent>"
    }
    if (Test-SensitiveConfigDisplay $Key $items) {
        if ($items.Count -eq 1) { return "<redacted>" }
        return "<redacted: $($items.Count) values>"
    }
    return (@($items | ForEach-Object { if ($_ -eq "") { "<empty>" } else { $_ } }) -join ", ")
}

function Write-DryRun {
    param([object]$Plan)

    $Entries = @($Plan.Entries)

    Write-Host "SWAW Kit Git sync (DRY RUN)"
    Write-Host "Would write local Git config:"
    foreach ($entry in $Entries) {
        Write-Host "  $($entry.ConfigKey) = $(Format-ConfigValuesForDisplay $entry.ConfigKey @($entry.Values))"
    }

    Write-Host "Would write SWAW Kit Git marker:"
    Write-Host "  swaw-kit-git.managed = true"
    Write-Host "  swaw-kit-git.entry = $EntryCommand"
    if (-not [string]::IsNullOrWhiteSpace($EntryFile)) {
        Write-Host "  swaw-kit-git.entry-file = $EntryFile"
    }

    foreach ($entry in $Entries) {
        Write-Host "  $($entry.MarkerKey) = $(Format-ConfigValuesForDisplay $entry.MarkerKey @($entry.Values))"
        if (-not [string]::IsNullOrWhiteSpace($entry.ConfigKeyMarker)) {
            Write-Host "  $($entry.ConfigKeyMarker) = $($entry.ConfigKey)"
        }
    }
    Write-Host "  swaw-kit-git.access = $(Format-ConfigValuesForDisplay 'swaw-kit-git.access' @($env:GIT_ID_ACCESS))"

    if (@($Plan.StaleEntries).Count -gt 0) {
        Write-Host "Would remove stale managed config:"
        foreach ($entry in @($Plan.StaleEntries)) {
            Write-Host "  $($entry.ConfigKey)"
        }
    }
}

function New-SyncPlan {
    param([object[]]$Entries)

    $managed = Get-LocalConfigValue "swaw-kit-git.managed"
    if ($null -ne $managed -and $managed -ne "true") {
        throw "Invalid SWAW Kit Git managed marker value '$managed'."
    }
    if ($managed -eq "true") {
        Assert-ManagedMarkerSchema
    }
    Assert-UnmanagedConfigCanBeAdopted $Entries $managed

    $staleEntries = @()
    if ($managed -eq "true") {
        $staleEntries = @(Get-StaleManagedConfigEntries $Entries)
        Assert-StaleManagedConfigEntriesUnchanged $staleEntries
    }

    return [pscustomobject]@{
        Entries = @($Entries)
        StaleEntries = @($staleEntries)
    }
}

function Write-Sync {
    param([object]$Plan)

    $Entries = @($Plan.Entries)
    $snapshot = New-SyncConfigSnapshot (Get-SyncWriteMutationKeys $Plan)
    $hadManagedMarker = @(Get-LocalConfigValues "swaw-kit-git.managed").Count -gt 0

    Invoke-SyncConfigTransaction -Snapshot $snapshot -Operation {
        if ($hadManagedMarker) {
            Remove-LocalConfigValue "swaw-kit-git.managed"
        }
        Remove-StaleManagedConfigEntries @($Plan.StaleEntries)

        foreach ($entry in $Entries) {
            Set-LocalConfigValues $entry.ConfigKey @($entry.Values)
        }

        foreach ($entry in $Entries) {
            Set-LocalConfigValues $entry.MarkerKey @($entry.Values)
            if (-not [string]::IsNullOrWhiteSpace($entry.ConfigKeyMarker)) {
                Set-LocalConfigValue $entry.ConfigKeyMarker $entry.ConfigKey
            }
        }

        Set-LocalConfigValue "swaw-kit-git.entry" $EntryCommand
        Set-LocalConfigValue "swaw-kit-git.entry-file" $EntryFile
        Set-LocalConfigValue "swaw-kit-git.access" $env:GIT_ID_ACCESS
        Set-LocalConfigValue "swaw-kit-git.managed" "true"
    }

    Write-Host "SWAW Kit Git sync wrote local config for $EntryCommand."
}

function Test-ValueListsEqual {
    param(
        [AllowEmptyCollection()]
        [string[]]$Left,
        [AllowEmptyCollection()]
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Count; $i++) {
        if ($Left[$i] -cne $Right[$i]) {
            return $false
        }
    }
    return $true
}

function Assert-UnmanagedConfigCanBeAdopted {
    param(
        [object[]]$Entries,
        [AllowNull()]
        [string]$Managed
    )

    if ($Managed -eq "true") {
        return
    }

    $conflicts = @()
    foreach ($entry in $Entries) {
        $current = @(Get-LocalConfigValues $entry.ConfigKey)
        if ($current.Count -gt 0 -and -not (Test-ValueListsEqual $current @($entry.Values))) {
            $conflicts += [pscustomobject]@{
                ConfigKey = $entry.ConfigKey
                Current   = $current
                Requested = @($entry.Values)
            }
        }
    }

    if ($conflicts.Count -eq 0) {
        return
    }

    Write-Host "[ERROR] Refusing to overwrite existing local Git config without a SWAW Kit Git sync marker."
    foreach ($conflict in $conflicts) {
        Write-Host "  $($conflict.ConfigKey)"
        Write-Host "    existing:  $(Format-ConfigValuesForDisplay $conflict.ConfigKey @($conflict.Current))"
        Write-Host "    requested: $(Format-ConfigValuesForDisplay $conflict.ConfigKey @($conflict.Requested))"
    }
    Write-Host "Remove or reconcile these local values, then run '$EntryCommand .sync' again."
    exit 1
}

function Get-StaleManagedConfigEntries {
    param([object[]]$CurrentEntries)

    $currentEntryKeys = @{}
    foreach ($entry in $CurrentEntries) {
        $currentEntryKeys["$($entry.MarkerKey)`n$($entry.ConfigKey)"] = $true
    }

    return @(Get-MarkerEntries | Where-Object {
        -not $currentEntryKeys.ContainsKey("$($_.MarkerKey)`n$($_.ConfigKey)")
    })
}

function Assert-StaleManagedConfigEntriesUnchanged {
    param([object[]]$StaleEntries)

    $changed = @()

    foreach ($entry in $StaleEntries) {
        $current = @(Get-LocalConfigValues $entry.ConfigKey)
        if ($current.Count -gt 0 -and -not (Test-ValueListsEqual $current @($entry.Values))) {
            $changed += [pscustomobject]@{ Entry = $entry; Current = $current }
        }
    }

    if ($changed.Count -gt 0) {
        Write-Host "[ERROR] Refusing to remove stale managed values changed since the last SWAW Kit Git sync."
        foreach ($item in $changed) {
            Write-Host "  $($item.Entry.ConfigKey)"
            Write-Host "    synced:  $(Format-ConfigValuesForDisplay $item.Entry.ConfigKey @($item.Entry.Values))"
            Write-Host "    current: $(Format-ConfigValuesForDisplay $item.Entry.ConfigKey @($item.Current))"
        }
        exit 1
    }
}

function Remove-StaleManagedConfigEntries {
    param([object[]]$StaleEntries)

    foreach ($entry in $StaleEntries) {
        $current = @(Get-LocalConfigValues $entry.ConfigKey)
        if ($current.Count -gt 0) {
            Remove-LocalConfigValue $entry.ConfigKey
        }
        Remove-LocalConfigValue $entry.MarkerKey
        if (-not [string]::IsNullOrWhiteSpace($entry.ConfigKeyMarker)) {
            Remove-LocalConfigValue $entry.ConfigKeyMarker
        }
    }
}

function Test-IdentityTextEqual {
    param([string]$Left, [string]$Right)

    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ManagedMarkerValueCount {
    param(
        [string]$Key,
        [int]$ExpectedCount
    )

    $values = @(Get-LocalConfigValues $Key)
    if ($values.Count -ne $ExpectedCount) {
        throw "Managed sync marker '$Key' is incomplete: expected $ExpectedCount value(s), found $($values.Count)."
    }
    return $values
}

function Assert-ManagedMarkerSchema {
    foreach ($key in @(
        "swaw-kit-git.managed",
        "swaw-kit-git.entry",
        "swaw-kit-git.entry-file",
        "swaw-kit-git.access",
        "swaw-kit-git.user-name",
        "swaw-kit-git.user-email",
        "swaw-kit-git.credentials-in-url",
        "swaw-kit-git.ssh-command"
    )) {
        $null = Assert-ManagedMarkerValueCount $key 1
    }

    $credentialsInUrl = @(Get-LocalConfigValues "swaw-kit-git.credentials-in-url")
    if ($credentialsInUrl[0] -ne "die") {
        throw "Managed sync marker 'swaw-kit-git.credentials-in-url' must be 'die'."
    }

    $access = Get-LocalConfigValue "swaw-kit-git.access"
    $httpsMatch = [regex]::Match($access, '^https\.(?<provider>github|gitlab):(?<host>[^/\s]+)/(?<user>[^/\s]+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $httpsOnlyKeys = @(
        "swaw-kit-git.credential-namespace",
        "swaw-kit-git.credential-store",
        "swaw-kit-git.credential-interactive",
        "swaw-kit-git.https-provider",
        "swaw-kit-git.https-provider-config-key",
        "swaw-kit-git.https-username",
        "swaw-kit-git.https-username-config-key"
    )

    if ($httpsMatch.Success) {
        $helpers = @(Assert-ManagedMarkerValueCount "swaw-kit-git.credential-helper" 2)
        if ($helpers[0] -ne "" -or [string]::IsNullOrWhiteSpace($helpers[1])) {
            throw "Managed HTTPS credential-helper marker is invalid."
        }
        foreach ($key in $httpsOnlyKeys) {
            $null = Assert-ManagedMarkerValueCount $key 1
        }

        $provider = $httpsMatch.Groups["provider"].Value.ToLowerInvariant()
        $hostName = $httpsMatch.Groups["host"].Value
        $account = $httpsMatch.Groups["user"].Value
        $credentialUser = if ($provider -eq "gitlab") { "oauth2" } else { $account }
        if ((Get-LocalConfigValue "swaw-kit-git.https-provider") -ine $provider -or
            (Get-LocalConfigValue "swaw-kit-git.https-provider-config-key") -ine "credential.https://$hostName.provider" -or
            (Get-LocalConfigValue "swaw-kit-git.https-username") -ine $credentialUser -or
            (Get-LocalConfigValue "swaw-kit-git.https-username-config-key") -ine "credential.https://$hostName.username") {
            throw "Managed HTTPS marker values do not match 'swaw-kit-git.access'."
        }
    } elseif ($access -match '^ssh:.+') {
        $helpers = @(Assert-ManagedMarkerValueCount "swaw-kit-git.credential-helper" 1)
        if ($helpers[0] -ne "") {
            throw "Managed SSH credential-helper marker must contain only the helper reset."
        }
        foreach ($key in $httpsOnlyKeys) {
            $null = Assert-ManagedMarkerValueCount $key 0
        }
    } else {
        throw "Managed sync marker 'swaw-kit-git.access' is invalid: $access"
    }

    $commitSigning = @(Assert-ManagedMarkerValueCount "swaw-kit-git.commit-gpg-sign" 1)
    $tagSigning = @(Assert-ManagedMarkerValueCount "swaw-kit-git.tag-gpg-sign" 1)
    if ($commitSigning[0] -notin @("true", "false")) {
        throw "Managed sync marker 'swaw-kit-git.commit-gpg-sign' must be 'true' or 'false'."
    }
    if ($tagSigning[0] -ne "false") {
        throw "Managed sync marker 'swaw-kit-git.tag-gpg-sign' must be 'false'."
    }

    $expectedSigningValues = if ($commitSigning[0] -eq "true") { 1 } else { 0 }
    $signingKeys = @(Assert-ManagedMarkerValueCount "swaw-kit-git.signing-key" $expectedSigningValues)
    $signingFormats = @(Assert-ManagedMarkerValueCount "swaw-kit-git.gpg-format" $expectedSigningValues)
    if ($expectedSigningValues -eq 1) {
        if ([string]::IsNullOrWhiteSpace($signingKeys[0])) {
            throw "Managed sync marker 'swaw-kit-git.signing-key' must not be empty when commit signing is enabled."
        }
        if ($signingFormats[0] -notin @("openpgp", "ssh", "x509")) {
            throw "Managed sync marker 'swaw-kit-git.gpg-format' is invalid: $($signingFormats[0])"
        }
    }
}

function Clear-Sync {
    $managed = Get-LocalConfigValue "swaw-kit-git.managed"
    if ($managed -ne "true") {
        Write-Host "[ERROR] No SWAW Kit Git sync marker found in this repository."
        exit 1
    }

    $markerEntry = Get-LocalConfigValue "swaw-kit-git.entry"
    if ([string]::IsNullOrWhiteSpace($markerEntry)) {
        Write-Host "[ERROR] The SWAW Kit Git sync marker has no owning entry command."
        Write-Host "Inspect .git/config and repair or remove the incomplete marker manually."
        exit 1
    }
    if (-not (Test-IdentityTextEqual $markerEntry $EntryCommand)) {
        Write-Host "[ERROR] This repository was synced by '$markerEntry', not '$EntryCommand'."
        Write-Host "Run '$markerEntry .sync --clear' or edit .git/config manually."
        exit 1
    }

    $markerEntryFile = Get-LocalConfigValue "swaw-kit-git.entry-file"
    if ([string]::IsNullOrWhiteSpace($markerEntryFile)) {
        Write-Host "[ERROR] The SWAW Kit Git sync marker has no owning entry file."
        Write-Host "Inspect .git/config and repair or remove the incomplete marker manually."
        exit 1
    }
    try {
        $markerEntryFile = [System.IO.Path]::GetFullPath($markerEntryFile)
    } catch {
        Write-Host "[ERROR] The SWAW Kit Git sync marker contains an invalid entry file path."
        exit 1
    }
    if (-not (Test-IdentityTextEqual $markerEntryFile $EntryFile)) {
        Write-Host "[ERROR] This repository was synced by a different '$EntryCommand' entry file."
        Write-Host "  synced:  $markerEntryFile"
        Write-Host "  current: $EntryFile"
        Write-Host "Run the original entry's '.sync --clear' or edit .git/config manually."
        exit 1
    }

    Assert-ManagedMarkerSchema

    $entries = Get-MarkerEntries
    $changed = @()
    foreach ($entry in $entries) {
        $current = @(Get-LocalConfigValues $entry.ConfigKey)
        if ($current.Count -gt 0 -and -not (Test-ValueListsEqual $current @($entry.Values))) {
            $changed += [pscustomobject]@{
                ConfigKey = $entry.ConfigKey
                Expected  = @($entry.Values)
                Current   = $current
            }
        }
    }

    if ($changed.Count -gt 0) {
        Write-Host "[ERROR] Refusing to clear values changed since the last SWAW Kit Git sync."
        foreach ($item in $changed) {
            Write-Host "  $($item.ConfigKey)"
            Write-Host "    synced:  $(Format-ConfigValuesForDisplay $item.ConfigKey @($item.Expected))"
            Write-Host "    current: $(Format-ConfigValuesForDisplay $item.ConfigKey @($item.Current))"
        }
        exit 1
    }

    $snapshot = New-SyncConfigSnapshot (Get-SyncClearMutationKeys $entries)
    Invoke-SyncConfigTransaction -Snapshot $snapshot -Operation {
        foreach ($entry in $entries) {
            if (@(Get-LocalConfigValues $entry.ConfigKey).Count -gt 0) {
                Remove-LocalConfigValue $entry.ConfigKey
            }
        }
        Remove-LocalConfigSection "swaw-kit-git"
    }

    Write-Host "SWAW Kit Git sync marker and unchanged managed config were cleared."
}

try {
    $location = Get-Location
    if ($location.Provider.Name -ne "FileSystem") {
        throw "sync must be run from a filesystem directory."
    }
    $script:RepositoryPath = [System.IO.Path]::GetFullPath($location.ProviderPath)
    Clear-InjectedGitConfigEnvironment
    Assert-GitRepository

    switch ($Mode) {
        "dry-run" {
            $plan = New-SyncPlan (New-ManagedConfigEntries)
            Write-DryRun $plan
        }
        "write" {
            $plan = New-SyncPlan (New-ManagedConfigEntries)
            Write-Sync $plan
        }
        "clear" {
            Clear-Sync
        }
    }
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}

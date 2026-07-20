function Invoke-LocalConfigMutation {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureFailure,
        [switch]$Rollback
    )

    $injectFailure = $false
    if (-not $Rollback) {
        $script:ConfigMutationCount++
        $injectFailure = ($script:TestFailConfigMutationAt -gt 0 -and
            $script:ConfigMutationCount -eq $script:TestFailConfigMutationAt)
    }

    $result = Invoke-Git -Arguments $Arguments -CaptureFailure:$CaptureFailure
    if ($injectFailure) {
        throw "Injected sync config mutation failure after operation $($script:ConfigMutationCount)."
    }
    return $result
}

function Set-LocalConfigValue {
    param(
        [string]$Key,
        [string]$Value,
        [switch]$Rollback
    )

    Set-LocalConfigValues -Key $Key -Values @($Value) -Rollback:$Rollback
}

function Set-LocalConfigValues {
    param(
        [string]$Key,
        [AllowEmptyCollection()]
        [string[]]$Values,
        [switch]$Rollback
    )

    Remove-LocalConfigValue -Key $Key -AllowMissing -Rollback:$Rollback
    foreach ($value in $Values) {
        $gitValue = if ($value -eq "") { '""' } else { $value }
        Invoke-LocalConfigMutation -Arguments @("config", "--local", "--add", $Key, $gitValue) -Rollback:$Rollback | Out-Null
    }
}

function Remove-LocalConfigValue {
    param(
        [string]$Key,
        [switch]$AllowMissing,
        [switch]$Rollback
    )

    $result = Invoke-LocalConfigMutation -Arguments @("config", "--local", "--unset-all", $Key) -CaptureFailure -Rollback:$Rollback
    if ($result.ExitCode -eq 0) {
        return
    }
    if ($AllowMissing -and $result.ExitCode -eq 5 -and [string]::IsNullOrWhiteSpace($result.Text)) {
        return
    }

    $message = $result.Text
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "git config --unset-all '$Key' exited with code $($result.ExitCode)"
    }
    throw $message
}

function Remove-LocalConfigSection {
    param(
        [string]$Section,
        [switch]$Rollback
    )

    Invoke-LocalConfigMutation -Arguments @("config", "--local", "--remove-section", $Section) -Rollback:$Rollback | Out-Null
}

function Get-UniqueConfigKeys {
    param([string[]]$Keys)

    # Git subsection names (including credential URL subsections) may be
    # case-sensitive. Preserve distinct keys instead of collapsing them.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Keys) {
        if (-not [string]::IsNullOrWhiteSpace($key) -and $seen.Add($key)) {
            $key
        }
    }
}

function Get-SyncManagedMarkerKeys {
    $result = Invoke-Git -Arguments @("config", "--local", "--name-only", "--get-regexp", '.*') -CaptureFailure
    if ($result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($result.Text)) {
        return @()
    }
    if ($result.ExitCode -ne 0) {
        $message = $result.Text
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "git config could not enumerate SWAW Kit Git marker keys (exit $($result.ExitCode))."
        }
        throw $message
    }

    $markerKeys = @($result.Text -split '\r?\n' | Where-Object { $_ -imatch '^swaw-kit-git\.' })
    return @(Get-UniqueConfigKeys $markerKeys)
}

function Get-SyncWriteMutationKeys {
    param([object]$Plan)

    $keys = @(
        "swaw-kit-git.managed",
        "swaw-kit-git.entry",
        "swaw-kit-git.entry-file",
        "swaw-kit-git.access"
    )
    foreach ($entry in @($Plan.StaleEntries) + @($Plan.Entries)) {
        $keys += $entry.ConfigKey
        $keys += $entry.MarkerKey
        if (-not [string]::IsNullOrWhiteSpace($entry.ConfigKeyMarker)) {
            $keys += $entry.ConfigKeyMarker
        }
    }
    return @(Get-UniqueConfigKeys $keys)
}

function Get-SyncClearMutationKeys {
    param([object[]]$Entries)

    $keys = @($Entries | ForEach-Object { $_.ConfigKey })
    $keys += @(Get-SyncManagedMarkerKeys)
    return @(Get-UniqueConfigKeys $keys)
}

function New-SyncConfigSnapshot {
    param([string[]]$Keys)

    return @(
        foreach ($key in @(Get-UniqueConfigKeys $Keys)) {
            [pscustomobject]@{
                Key    = $key
                Values = @(Get-LocalConfigValues $key)
            }
        }
    )
}

function Restore-SyncConfigSnapshot {
    param([object[]]$Snapshot)

    $restoreErrors = @()
    $managedMarker = @($Snapshot | Where-Object { $_.Key -ieq "swaw-kit-git.managed" })
    $restoreOrder = @($Snapshot | Where-Object { $_.Key -ine "swaw-kit-git.managed" }) + $managedMarker

    foreach ($item in $restoreOrder) {
        try {
            Set-LocalConfigValues -Key $item.Key -Values @($item.Values) -Rollback
        } catch {
            $restoreErrors += "$($item.Key): $($_.Exception.Message)"
        }
    }

    $verificationErrors = @()
    foreach ($item in $Snapshot) {
        try {
            $current = @(Get-LocalConfigValues $item.Key)
            if (-not (Test-ValueListsEqual $current @($item.Values))) {
                $verificationErrors += $item.Key
            }
        } catch {
            $verificationErrors += "$($item.Key) (read failed: $($_.Exception.Message))"
        }
    }

    return [pscustomobject]@{
        Success            = ($verificationErrors.Count -eq 0)
        RestoreErrors      = $restoreErrors
        VerificationErrors = $verificationErrors
    }
}

function Invoke-SyncConfigTransaction {
    param(
        [object[]]$Snapshot,
        [scriptblock]$Operation
    )

    $script:ConfigMutationCount = 0
    try {
        & $Operation
    } catch {
        $operationError = $_.Exception.Message
        $rollback = Restore-SyncConfigSnapshot $Snapshot
        if ($rollback.Success) {
            throw "Sync config update failed and was rolled back: $operationError"
        }

        $failedKeys = @($rollback.VerificationErrors) -join ", "
        throw "Sync config update failed: $operationError`nRollback verification failed for: $failedKeys`nInspect the repository's local Git config manually before running sync again."
    }
}

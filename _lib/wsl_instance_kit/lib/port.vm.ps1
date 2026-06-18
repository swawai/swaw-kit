function Show-WslVmPortList {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        return Show-CommandHelpHint ".vm port does not accept extra arguments."
    }

    $cleanup = Invoke-WslPortMissingInstanceCleanup -All -Quiet
    if ($cleanup.ExitCode -ne 0) {
        return $cleanup.ExitCode
    }

    $items = @(Get-WslManagedPortItems -All)
    $installedNames = Get-WslInstalledDistributionNameSet
    $installedSafeNames = Get-WslPortInstalledSafeNameSet

    Write-Host "WSL port rules: current Windows user"
    if ($cleanup.Removed -gt 0) {
        Write-Host "  Cleaned missing-instance rules: $($cleanup.Removed)"
    }
    if ($items.Count -eq 0) {
        Write-Host "  (none)"
        return 0
    }

    $hasMissingInstance = $false
    foreach ($item in $items) {
        $instance = if ([string]::IsNullOrWhiteSpace($item.InstanceName)) { $item.InstanceSafeName } else { $item.InstanceName }
        $state = Get-WslManagedPortItemState -Item $item -InstalledNames $installedNames -InstalledSafeNames $installedSafeNames
        if ($state -eq "missing-instance") {
            $hasMissingInstance = $true
        }
        $target = Format-WslManagedPortItemTarget $item
        Write-Host ("  {0,-58} {1,-22} {2,-18} {3}" -f $item.Id, $instance, $state, $target)
    }

    if ($hasMissingInstance -and -not (Test-WslKitAdmin)) {
        Write-Warn "  Run $(Format-CommandLine $script:Config.CommandName @(".vm", "port", "--uac")) to request elevation and auto-clean missing-instance rules."
    }

    return 0
}

function Resolve-WslManagedPortItemById {
    param([string]$Id)

    return @(Get-WslManagedPortItems -All | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Delete-WslVmPortRule {
    param([string[]]$Rest)

    $dryRun = $false
    $uac = $false
    $ids = New-Object System.Collections.ArrayList
    foreach ($item in @($Rest)) {
        switch ($item) {
            "--dry-run" {
                $dryRun = $true
                continue
            }
            "--uac" {
                $uac = $true
                continue
            }
            default {
                if ($item.StartsWith("--")) {
                    Write-Fail "Unknown .vm port del option: $item"
                    return 1
                }

                [void]$ids.Add($item)
            }
        }
    }

    if ($ids.Count -ne 1 -or [string]::IsNullOrWhiteSpace($ids[0])) {
        return Show-CommandHelpHint ".vm port del requires a rule id shown by .vm port."
    }

    $id = $ids[0].Trim()
    if ($id -notmatch '^wsl_instance_kit-[A-Za-z0-9_.-]+-port-[A-Za-z0-9]+-[A-Za-z0-9_.-]+-\d+$') {
        Write-Fail "Invalid WSL port rule id: $id"
        Write-Fail "Run .vm port and pass one of the displayed rule ids."
        return 1
    }

    $match = @(Resolve-WslManagedPortItemById $id)
    if ($match.Count -eq 0) {
        Write-Fail "WSL port rule not found: $id"
        Write-Fail "Run .vm port and pass one of the displayed rule ids."
        return 1
    }

    if (-not $dryRun -and -not (Test-WslKitAdmin)) {
        if (-not $uac) {
            Write-Fail "This .vm port del action requires administrator privileges."
            Write-Fail "Run again with --uac to request elevation:"
            Write-Fail "  $(Format-CommandLine $script:Config.CommandName @(".vm", "port", "del", $id, "--uac"))"
            return 1
        }

        return (Invoke-WslKitElevatedCommand -CommandArgs @(".vm", "port", "del", $id))
    }

    return (Remove-WslManagedPortItem -Item $match[0] -DryRun:$dryRun)
}

function Invoke-WslVmPort {
    param([string[]]$Rest)

    if ($Rest.Count -eq 0) {
        return Show-WslVmPortList @()
    }

    if ($Rest.Count -eq 1 -and $Rest[0] -eq "--uac") {
        if (Test-WslKitAdmin) {
            return Show-WslVmPortList @()
        }

        return (Invoke-WslKitElevatedCommand -CommandArgs @(".vm", "port"))
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)
    switch ($action) {
        "del" {
            return Delete-WslVmPortRule $tail
        }
        default {
            return Show-CommandHelpHint "Unknown .vm port command: $action"
        }
    }
}

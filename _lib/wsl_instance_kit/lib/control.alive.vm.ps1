function Get-WslAliveAllTaskInfos {
    $items = New-Object System.Collections.ArrayList
    try {
        $tasks = @(Get-ScheduledTask -TaskPath (Get-WslAliveTaskPath) -ErrorAction Stop | Where-Object {
            $_.TaskName -like (Get-WslAliveTaskNameWildcard)
        } | Sort-Object -Property TaskName)
    } catch {
        return @()
    }

    $installedNames = Get-WslInstalledDistributionNameSet
    foreach ($task in $tasks) {
        $info = Get-WslAliveTaskInfoByName -TaskName $task.TaskName -InstalledNames $installedNames
        if ($info.Exists) {
            [void]$items.Add($info)
        }
    }

    return @($items)
}

function Show-WslVmAliveList {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        return Show-CommandHelpHint ".vm alive does not accept extra arguments."
    }

    $items = @(Get-WslAliveAllTaskInfos)
    Write-Host "WSL alive tasks: current Windows user"
    if ($items.Count -eq 0) {
        Write-Host "  (none)"
        return 0
    }

    foreach ($item in $items) {
        $label = if ($null -ne $item.Spec) { $item.Spec.Label } else { "unknown" }
        Write-Host ("  {0,-28} {1,-42} {2}" -f $item.TaskName, $label, $item.State)
    }

    return 0
}

function Delete-WslVmAliveTask {
    param([string[]]$Rest)

    if ($Rest.Count -ne 1 -or [string]::IsNullOrWhiteSpace($Rest[0])) {
        return Show-CommandHelpHint ".vm alive del requires a task name shown by .vm alive."
    }

    $taskName = $Rest[0].Trim()
    if (-not (Test-WslAliveTaskName $taskName)) {
        Write-Fail "Invalid alive task name: $taskName"
        Write-Fail "Run .vm alive and pass one of the displayed task names."
        return 1
    }

    $items = @(Get-WslAliveAllTaskInfos)
    $match = @($items | Where-Object { $_.TaskName -eq $taskName } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        Write-Fail "Alive task not found: $taskName"
        Write-Fail "Run .vm alive and pass one of the displayed task names."
        return 1
    }

    $exitCode = Remove-WslAliveTaskByFullName $match[0].Name -Quiet
    if ($exitCode -ne 0) {
        return $exitCode
    }

    Write-Host "Deleted WSL alive task: $taskName"
    return 0
}

function Invoke-WslVmAlive {
    param([string[]]$Rest)

    if ($Rest.Count -eq 0) {
        return Show-WslVmAliveList @()
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)
    switch ($action) {
        "del" {
            return Delete-WslVmAliveTask $tail
        }
        default {
            return Show-CommandHelpHint "Unknown .vm alive command: $action"
        }
    }
}

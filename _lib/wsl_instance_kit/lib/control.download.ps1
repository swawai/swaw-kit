function Open-WslDownloadDir {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail "ctl downloads dir does not accept extra arguments."
        return 1
    }

    $downloadDir = Get-WslDownloadDir
    Ensure-Directory $downloadDir
    return (Open-WindowsFolder $downloadDir)
}


function Invoke-DownloadControl {
    param(
        [string[]]$Rest,
        [string]$Verb = "downloads"
    )

    if ($Rest.Count -eq 1 -and $Rest[0].ToLowerInvariant() -eq "dir") {
        return (Open-WslDownloadDir -Rest @())
    }

    $commandText = $Verb
    if ($Rest.Count -gt 0) {
        $commandText = "$Verb $($Rest -join ' ')"
    }

    Write-Fail "Unknown control command: $commandText"
    Write-Fail "Usage: $($script:Config.CommandName) ctl $Verb dir"
    return 1
}


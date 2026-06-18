function Open-WslDownloadDir {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail "ctl dir downloads does not accept extra arguments."
        return 1
    }

    $downloadDir = Get-WslDownloadDir
    Ensure-Directory $downloadDir
    return (Open-WindowsFolder $downloadDir)
}

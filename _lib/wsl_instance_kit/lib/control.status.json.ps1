function Get-WslStatusSshPublicKeyInfo {
    if ([string]::IsNullOrWhiteSpace($script:Config.SshPublicKey)) {
        return [pscustomobject]@{
            Path   = ""
            Exists = $false
        }
    }

    $path = Resolve-WslStatusPath $script:Config.SshPublicKey
    return [pscustomobject]@{
        Path   = $path
        Exists = (Test-Path -LiteralPath $path -PathType Leaf)
    }
}

function Get-WslStatusWarningItems {
    $items = New-Object System.Collections.ArrayList
    foreach ($status in @(Get-WslCommandScriptLineEndingStatuses | Where-Object { $_.Warning })) {
        $item = [ordered]@{
            label   = [string]$status.Label
            message = [string]$status.Message
            path    = [string]$status.Path
        }
        [void]$items.Add([pscustomobject]$item)
    }

    return @($items)
}

function Show-WslResourceStatusJson {
    $source = Resolve-WslSource $script:Config.Source
    $installDir = Resolve-EntryPath $script:Config.InstallDir
    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    $backupRoot = Get-WslBackupRoot $backupDir
    $downloadDir = Get-WslDownloadDir
    $envFile = Resolve-WslEnvironmentFilePath
    if ($null -eq $envFile) {
        $envFile = ""
    }

    $sshKey = Get-WslStatusSshPublicKeyInfo
    $record = Get-WslDistributionRecord
    $installed = ($null -ne $record)
    $runtime = $null
    $runtimeIp = ""
    $runtimeState = if ($installed) { "unknown" } else { "not installed" }
    $runtimeVersion = ""
    $userPassword = ""
    $passwordNext = ""
    $registryBasePath = ""

    if ($installed) {
        $runtime = Get-WslDistributionRuntimeInfo $record
        $runtimeState = if ($null -eq $runtime -or [string]::IsNullOrWhiteSpace($runtime.State)) { "unknown" } else { [string]$runtime.State }
        $runtimeVersion = if ($null -eq $runtime -or [string]::IsNullOrWhiteSpace($runtime.Version)) { "" } else { [string]$runtime.Version }
        $runtimeIp = Get-WslRunningIpAddresses $runtimeState

        $passwordStatus = Get-WslUserPasswordStatus $runtimeState
        $userPassword = [string]$passwordStatus.Text
        $passwordNext = [string]$passwordStatus.Hint

        if ($record.BasePath) {
            $registryBasePath = [System.IO.Path]::GetFullPath($record.BasePath).TrimEnd("\")
        }
    }

    $data = [ordered]@{
        command          = "status"
        entry            = [string]$script:Config.CommandName
        name             = [string]$script:Config.Name
        user             = if ([string]::IsNullOrWhiteSpace($script:Config.User)) { "" } else { [string]$script:Config.User }
        source           = [string]$source
        entryFile        = [string]$script:Config.EntryFile
        installDir       = [string]$installDir
        backupDir        = [string]$backupDir
        workdir          = if ([string]::IsNullOrWhiteSpace($script:Config.DefaultWorkdir)) { "" } else { [string]$script:Config.DefaultWorkdir }
        version          = if ([string]::IsNullOrWhiteSpace($script:Config.Version)) { "" } else { [string]$script:Config.Version }
        format           = if ([string]::IsNullOrWhiteSpace($script:Config.ExportFormat)) { "" } else { [string]$script:Config.ExportFormat }
        envFile          = [string]$envFile
        sshKey           = [string]$sshKey.Path
        sshKeyExists     = [bool]$sshKey.Exists
        installed        = [bool]$installed
        state            = [string]$runtimeState
        runtimeVersion   = [string]$runtimeVersion
        ip               = [string]$runtimeIp
        userPassword     = [string]$userPassword
        passwordNext     = [string]$passwordNext
        registryBasePath = [string]$registryBasePath
        alive            = [string](Get-WslAliveStatusSummary)
        port             = [string](Get-WslPortStatusSummary)
        backupBytes      = Get-WslDirectorySizeBytes $backupDir
        backupRootBytes  = Get-WslDirectorySizeBytes $backupRoot
        downloadBytes    = Get-WslDirectorySizeBytes $downloadDir
        warnings         = @(Get-WslStatusWarningItems)
    }

    Write-CompactJson ([pscustomobject]$data) 5
    return 0
}

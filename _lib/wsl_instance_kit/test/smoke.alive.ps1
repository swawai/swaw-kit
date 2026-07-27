function Test-WslAliveHeadlessTaskAction {
    . (Join-Path $kitRoot "lib\common.ps1")
    . (Join-Path $kitRoot "lib\control.alive.ps1")

    $oldConfig = $script:Config
    try {
        $script:Config = [pscustomobject]@{
            Name          = "wsl01"
            CommandName   = "wsl01"
            EntryFileName = "wsl01.cmd"
        }

        $duration = [pscustomobject]@{
            Mode    = "duration"
            Seconds = 123
        }
        $task = Get-WslAliveTaskIdentity
        Assert-True ($task.Path -ceq "\swaw-kit\wsl_instance_kit\") "alive tasks should use the swaw-kit task folder."
        $durationAction = Get-WslAliveTaskAction $duration
        Assert-True ($durationAction.Command -ieq "conhost.exe") "duration alive task should use the headless console host."
        Assert-True ($durationAction.Arguments.StartsWith("--headless powershell.exe")) "duration alive task should run PowerShell inside a headless console."
        Assert-True ($durationAction.Arguments.Contains("-EncodedCommand")) "duration alive task should keep the self-cleanup PowerShell action."

        $logon = [pscustomobject]@{
            Mode    = "logon"
            Seconds = 0
        }
        $logonAction = Get-WslAliveTaskAction $logon
        Assert-True ($logonAction.Command -ieq "conhost.exe") "logon alive task should use the same headless console host."
        Assert-True ($logonAction.Arguments.StartsWith("--headless wsl.exe")) "logon alive task should run WSL inside a headless console."
        Assert-True ($logonAction.Arguments.Contains("wsl_instance_kit_alive_wsl01")) "logon alive task should keep the command marker."
    } finally {
        $script:Config = $oldConfig
    }
}

function ConvertTo-WslAliveSafeName {
    param([AllowNull()] [string]$Value)

    $safe = if ([string]::IsNullOrWhiteSpace($Value)) { $script:Config.Name } else { $Value }
    $safe = $safe -replace '[<>:"/\\|?*]', '_'
    $safe = $safe -replace '[\x00-\x1f]', '_'
    $safe = $safe -replace '[^A-Za-z0-9_.-]', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "wsl"
    }

    return $safe
}

function ConvertTo-WslAliveXmlText {
    param([AllowNull()] [string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function ConvertTo-WslAlivePowerShellString {
    param([AllowNull()] [string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function New-WslAliveEncodedPowerShellCommand {
    param([string]$ScriptText)

    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptText))
}

function Get-WslAliveMinimumSeconds {
    return 10
}

function Get-WslAliveTaskPath {
    return "\win-run-toolbox\wsl_instance_kit\"
}

function Get-WslAliveTaskIdentity {
    $name = ConvertTo-WslAliveSafeName $script:Config.Name
    $taskName = "alive_{0}" -f $name
    $taskPath = Get-WslAliveTaskPath

    return [pscustomobject]@{
        Path = $taskPath
        Name = $taskName
        Full = "$taskPath$taskName"
    }
}

function Get-WslAliveMarker {
    $name = ConvertTo-WslAliveSafeName $script:Config.Name
    return ("wsl_instance_kit_alive_{0}" -f $name)
}

function Resolve-WslAliveDuration {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Fail ".alive requires a number of seconds greater than or equal to $(Get-WslAliveMinimumSeconds)."
        return $null
    }

    $seconds = [long]0
    if (-not [long]::TryParse($Value.Trim(), [ref]$seconds)) {
        Write-Fail ".alive duration must be an integer number of seconds."
        return $null
    }

    if ($seconds -lt (Get-WslAliveMinimumSeconds)) {
        Write-Fail ".alive duration must be at least $(Get-WslAliveMinimumSeconds) seconds. Use .alive for long-running logon keep-alive."
        return $null
    }

    return [pscustomobject]@{
        Mode    = "duration"
        Seconds = $seconds
        Label   = "$seconds seconds"
    }
}

function Get-WslAliveShellScript {
    param([pscustomobject]$Spec)

    $marker = Get-WslAliveMarker
    if ($Spec.Mode -eq "duration") {
        return ": $marker mode=duration seconds=$($Spec.Seconds); sleep $($Spec.Seconds)"
    }

    return ": $marker mode=$($Spec.Mode) seconds=0; while :; do sleep 3600; done"
}

function Get-WslAliveActionArguments {
    param([pscustomobject]$Spec)

    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--cd", "/", "--", "sh", "-lc", (Get-WslAliveShellScript $Spec))
    return (Get-ProcessArgumentLine $nativeArgs)
}

function New-WslAliveDurationActionScript {
    param([pscustomobject]$Spec)

    $task = Get-WslAliveTaskIdentity
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--cd", "/", "--", "sh", "-lc", (Get-WslAliveShellScript $Spec))
    $nativeArgList = (@($nativeArgs) | ForEach-Object { ConvertTo-WslAlivePowerShellString $_ }) -join ", "
    $taskName = ConvertTo-WslAlivePowerShellString $task.Full

    return @"
`$wslArgs = @($nativeArgList)
& wsl.exe @wslArgs
`$exitCode = `$LASTEXITCODE
& schtasks.exe /Delete /TN $taskName /F | Out-Null
exit `$exitCode
"@
}

function Get-WslAliveTaskAction {
    param([pscustomobject]$Spec)

    if ($Spec.Mode -eq "duration") {
        $encoded = New-WslAliveEncodedPowerShellCommand (New-WslAliveDurationActionScript $Spec)
        return [pscustomobject]@{
            Command   = "powershell.exe"
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encoded"
        }
    }

    return [pscustomobject]@{
        Command   = "wsl.exe"
        Arguments = Get-WslAliveActionArguments $Spec
    }
}

function Get-WslAliveCurrentUser {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    } catch {
        return (Get-EnvOrEmpty "USERNAME")
    }
}

function Get-WslAliveDescription {
    param([pscustomobject]$Spec)

    return "win-run-toolbox WSL alive; mode=$($Spec.Mode); seconds=$($Spec.Seconds); command=$($script:Config.CommandName); wsl=$($script:Config.Name)"
}

function New-WslAliveTaskXml {
    param([pscustomobject]$Spec)

    $description = ConvertTo-WslAliveXmlText (Get-WslAliveDescription $Spec)
    $user = ConvertTo-WslAliveXmlText (Get-WslAliveCurrentUser)
    $action = Get-WslAliveTaskAction $Spec
    $command = ConvertTo-WslAliveXmlText $action.Command
    $arguments = ConvertTo-WslAliveXmlText $action.Arguments
    $triggerXml = if ($Spec.Mode -eq "logon") {
        @"
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
    </LogonTrigger>
  </Triggers>
"@
    } else {
        "  <Triggers />"
    }

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$description</Description>
  </RegistrationInfo>
$triggerXml
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Invoke-WslAliveSchtasks {
    param(
        [string[]]$CommandArgs,
        [switch]$IgnoreExitCode
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = (& schtasks.exe @CommandArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        $output = $_.Exception.Message
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        Write-Fail "schtasks.exe failed: $($CommandArgs -join ' ')"
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Write-Fail $output.Trim()
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-WslAliveTaskXmlByFullName {
    param([string]$TaskFullName)

    $result = Invoke-WslAliveSchtasks @("/Query", "/TN", $TaskFullName, "/XML", "ONE") -IgnoreExitCode
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return ""
    }

    return $result.Output
}

function Get-WslAliveTaskStateByName {
    param([string]$TaskName)

    try {
        $item = Get-ScheduledTask -TaskPath (Get-WslAliveTaskPath) -TaskName $TaskName -ErrorAction Stop
        if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.State)) {
            return [string]$item.State
        }
    } catch {
    }

    return "unknown"
}

function Get-WslAliveTaskSpecFromXml {
    param([string]$XmlText)

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        return $null
    }

    $description = ""
    try {
        [xml]$doc = $XmlText
        $node = Select-Xml -Xml $doc -XPath "//*[local-name()='Description']" | Select-Object -First 1
        if ($null -ne $node) {
            $description = [string]$node.Node.InnerText
        }
    } catch {
        $description = ""
    }

    $mode = "unknown"
    $seconds = [long]-1
    if ($description -match '(?:^|;\s*)mode=(?<mode>[A-Za-z0-9_-]+)') {
        $mode = $Matches["mode"]
    }
    if ($description -match '(?:^|;\s*)seconds=(?<seconds>\d+)') {
        [void][long]::TryParse($Matches["seconds"], [ref]$seconds)
    }
    $wslName = ""
    if ($description -match '(?:^|;\s*)wsl=(?<wsl>[^;]+)') {
        $wslName = $Matches["wsl"].Trim()
    }

    return [pscustomobject]@{
        Mode        = $mode
        Seconds     = $seconds
        Label       = Format-WslAliveTaskMode -Mode $mode -Seconds $seconds
        Description = $description
        WslName     = $wslName
    }
}

function Format-WslAliveTaskMode {
    param(
        [string]$Mode,
        [long]$Seconds
    )

    switch ($Mode) {
        "logon" {
            return "auto-start at current-user logon"
        }
        "duration" {
            if ($Seconds -ge 0) {
                return "$Seconds seconds"
            }
            return "duration"
        }
        default {
            return "unknown"
        }
    }
}

function Remove-WslAliveTaskByFullName {
    param(
        [string]$TaskFullName,
        [switch]$DryRun,
        [switch]$Quiet
    )

    $exists = -not [string]::IsNullOrWhiteSpace((Get-WslAliveTaskXmlByFullName $TaskFullName))
    if ($DryRun) {
        if (-not $Quiet) {
            if ($exists) {
                Write-Host "Would stop and delete alive task: $TaskFullName"
            } else {
                Write-Host "Would stop and delete alive task: $TaskFullName (absent)"
            }
        }
        return 0
    }

    if (-not $exists) {
        return 0
    }

    [void](Invoke-WslAliveSchtasks @("/End", "/TN", $TaskFullName) -IgnoreExitCode)
    $delete = Invoke-WslAliveSchtasks @("/Delete", "/TN", $TaskFullName, "/F")
    return $delete.ExitCode
}

function Test-WslAliveDurationTaskExpired {
    param(
        [AllowNull()] [pscustomobject]$Spec,
        [string]$State
    )

    if ($null -eq $Spec -or $Spec.Mode -ne "duration") {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($State) -or $State -ieq "unknown") {
        return $false
    }

    return ($State -ine "Running")
}

function Test-WslAliveTaskMissingInstance {
    param(
        [AllowNull()] [pscustomobject]$Spec,
        [AllowNull()] [object]$InstalledNames
    )

    if ($null -eq $Spec -or [string]::IsNullOrWhiteSpace($Spec.WslName)) {
        return $false
    }

    if ($null -eq $InstalledNames) {
        $InstalledNames = Get-WslInstalledDistributionNameSet
    }

    return (-not $InstalledNames.Contains($Spec.WslName))
}

function Get-WslAliveTaskInfoByName {
    param(
        [string]$TaskName,
        [AllowNull()] [object]$InstalledNames
    )

    $taskFullName = "$(Get-WslAliveTaskPath)$TaskName"
    $xml = Get-WslAliveTaskXmlByFullName $taskFullName
    $exists = -not [string]::IsNullOrWhiteSpace($xml)
    $spec = if ($exists) { Get-WslAliveTaskSpecFromXml $xml } else { $null }
    $state = if ($exists) { Get-WslAliveTaskStateByName $TaskName } else { "absent" }

    if ((Test-WslAliveDurationTaskExpired -Spec $spec -State $state) -or (Test-WslAliveTaskMissingInstance -Spec $spec -InstalledNames $InstalledNames)) {
        [void](Remove-WslAliveTaskByFullName $taskFullName -Quiet)
        $exists = $false
        $state = "absent"
        $spec = $null
    }

    return [pscustomobject]@{
        Exists = $exists
        TaskName = $TaskName
        Name   = $taskFullName
        State  = $state
        Spec   = $spec
    }
}

function Get-WslAliveTaskInfo {
    $task = Get-WslAliveTaskIdentity
    return (Get-WslAliveTaskInfoByName $task.Name)
}

function Get-WslAliveStatusSummary {
    $task = Get-WslAliveTaskInfo
    if (-not $task.Exists) {
        return "off"
    }

    $label = if ($null -ne $task.Spec) { $task.Spec.Label } else { "unknown" }
    return "$label ($($task.State))"
}

function Remove-WslAliveTask {
    param(
        [switch]$DryRun,
        [switch]$Quiet
    )

    $task = Get-WslAliveTaskIdentity
    return (Remove-WslAliveTaskByFullName $task.Full -DryRun:$DryRun -Quiet:$Quiet)
}

function Register-WslAliveTask {
    param(
        [pscustomobject]$Spec,
        [switch]$DryRun
    )

    $task = Get-WslAliveTaskIdentity

    if ($DryRun) {
        [void](Remove-WslAliveTask -DryRun -Quiet)
        Write-Host "Would register alive task: $($task.Full)"
        Write-Host "  Mode:    $(Format-WslAliveTaskMode -Mode $Spec.Mode -Seconds $Spec.Seconds)"
        Write-Host "  Trigger: $(if ($Spec.Mode -eq 'logon') { 'current-user logon' } else { 'manual/on-demand' })"
        Show-NativeCommand "wsl.exe" @("-d", $script:Config.Name, "-u", "root", "--cd", "/", "--", "sh", "-lc", (Get-WslAliveShellScript $Spec))
        Write-Host "schtasks.exe /Create /TN $(Format-Arg $task.Full) /XML <generated.xml> /F"
        Write-Host "schtasks.exe /Run /TN $(Format-Arg $task.Full)"
        return 0
    }

    if ($null -eq (Get-WslDistributionRecord)) {
        Write-Fail "WSL instance is not installed: $($script:Config.Name)"
        Write-Fail "Run: $($script:Config.CommandName) .install"
        return 1
    }

    $removeExit = Remove-WslAliveTask -Quiet
    if ($removeExit -ne 0) {
        return $removeExit
    }

    $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) ("wsl-alive-" + [guid]::NewGuid().ToString("N") + ".xml")
    try {
        $xml = New-WslAliveTaskXml $Spec
        [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.UnicodeEncoding]::new($false, $true))
        $create = Invoke-WslAliveSchtasks @("/Create", "/TN", $task.Full, "/XML", $xmlPath, "/F")
        if ($create.ExitCode -ne 0) {
            return $create.ExitCode
        }
    } finally {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }

    $run = Invoke-WslAliveSchtasks @("/Run", "/TN", $task.Full)
    if ($run.ExitCode -ne 0) {
        return $run.ExitCode
    }

    Write-Host "Enabled WSL alive: $(Format-WslAliveTaskMode -Mode $Spec.Mode -Seconds $Spec.Seconds)"
    Write-Host "  Task: $($task.Full)"
    Write-Host "  Replaced previous alive setting, if any."
    return 0
}

function Show-WslAliveStatus {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        return Show-CommandHelpHint ".alive status does not accept extra arguments."
    }

    $record = Get-WslDistributionRecord
    $runtime = $null
    $runtimeIp = ""
    if ($null -ne $record) {
        $runtime = Get-WslDistributionRuntimeInfo $record
        $runtimeIp = Get-WslRunningIpAddresses $runtime.State
    }

    $task = Get-WslAliveTaskInfo
    Write-Host "WSL alive: $($script:Config.CommandName)"
    Write-Host "  WSL_name:            $($script:Config.Name)"
    if ($null -eq $record) {
        Write-Host "  Installed:           no" -ForegroundColor Yellow
    } else {
        Write-Host "  Installed:           yes" -ForegroundColor Green
        if ($null -ne $runtime) {
            $runtimeState = if ([string]::IsNullOrWhiteSpace($runtime.State)) { "unknown" } else { $runtime.State }
            if ($runtimeState -ieq "Running") {
                Write-Host "  Runtime State:       $runtimeState" -ForegroundColor Green
            } elseif ($runtimeState -ieq "Stopped") {
                Write-Host "  Runtime State:       $runtimeState" -ForegroundColor Yellow
            } else {
                Write-Host "  Runtime State:       $runtimeState"
            }

            if (-not [string]::IsNullOrWhiteSpace($runtimeIp)) {
                Write-Host "  Runtime IP:          $runtimeIp"
            } elseif ($runtimeState -ieq "Running") {
                Write-Host "  Runtime IP:          (unknown)"
            } else {
                Write-Host "  Runtime IP:          (not running)"
            }
        }
    }

    Write-Host "  Alive task:          $($task.Name)"
    if (-not $task.Exists) {
        Write-Host "  Alive setting:       off"
        Write-Host "  Task State:          absent"
        return 0
    }

    Write-Host "  Alive setting:       $($task.Spec.Label)"
    if ($task.State -ieq "Running") {
        Write-Host "  Task State:          $($task.State)" -ForegroundColor Green
    } else {
        Write-Host "  Task State:          $($task.State)"
    }
    return 0
}

function Disable-WslAliveSettings {
    param([string[]]$Rest)

    $dryRun = $false
    foreach ($item in @($Rest)) {
        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        Write-Fail "Unknown .alive off option: $item"
        return 1
    }

    if ($dryRun) {
        Write-Host "Would disable all WSL alive settings."
        [void](Remove-WslAliveTask -DryRun)
        return 0
    }

    $exitCode = Remove-WslAliveTask -Quiet
    if ($exitCode -ne 0) {
        return $exitCode
    }

    Write-Host "Disabled WSL alive settings."
    Write-Host "  Task: removed or already absent $((Get-WslAliveTaskIdentity).Full)"
    return 0
}

function Invoke-WslAliveLogon {
    param([string[]]$Rest)

    $dryRun = $false
    foreach ($item in @($Rest)) {
        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        Write-Fail "Unknown .alive option: $item"
        return 1
    }

    $spec = [pscustomobject]@{
        Mode    = "logon"
        Seconds = 0
    }
    return (Register-WslAliveTask -Spec $spec -DryRun:$dryRun)
}

function Invoke-WslAliveDuration {
    param([string[]]$Rest)

    $durationText = $null
    $dryRun = $false
    foreach ($item in @($Rest)) {
        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        if ([string]::IsNullOrWhiteSpace($item)) {
            Write-Fail ".alive received an empty duration."
            return 1
        }

        if ($item.StartsWith("-")) {
            Write-Fail "Unknown .alive option: $item"
            return 1
        }

        if ($null -ne $durationText) {
            Write-Fail ".alive accepts at most one duration."
            return 1
        }

        $durationText = $item
    }

    $duration = Resolve-WslAliveDuration $durationText
    if ($null -eq $duration) {
        Write-Fail "Run: $($script:Config.CommandName) .alive <seconds>"
        return 1
    }

    return (Register-WslAliveTask -Spec $duration -DryRun:$dryRun)
}

function Invoke-WslAlive {
    param([string[]]$Rest)

    if ($Rest.Count -eq 0) {
        return Invoke-WslAliveLogon @()
    }

    if ($Rest[0].StartsWith("-")) {
        return Invoke-WslAliveLogon $Rest
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)
    switch ($action) {
        "status" {
            return Show-WslAliveStatus $tail
        }
        "off" {
            return Disable-WslAliveSettings $tail
        }
        default {
            return Invoke-WslAliveDuration $Rest
        }
    }
}

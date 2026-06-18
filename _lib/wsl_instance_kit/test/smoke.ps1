[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryFile = Join-Path $repoRoot "wsl01.cmd"
$kitCmd = Join-Path $repoRoot "_lib\wsl_instance_kit\kit.cmd"
$kitRoot = Join-Path $repoRoot "_lib\wsl_instance_kit"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExitCode {
    param(
        [int]$Actual,
        [int]$Expected,
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label failed: expected exit code $Expected, got $Actual."
    }
}

function Assert-ArrayEqual {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Label
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Label failed: expected $($Expected.Count) args, got $($Actual.Count). Actual: $($Actual -join ' | ')"
    }

    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($Actual[$i] -ne $Expected[$i]) {
            throw "$Label failed at arg $i. Expected '$($Expected[$i])', got '$($Actual[$i])'."
        }
    }
}

function Invoke-Checked {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [int]$ExpectedExitCode = 0,
        [string]$Label = $File
    )

    & $File @CommandArgs
    Assert-ExitCode $LASTEXITCODE $ExpectedExitCode $Label
}

function Invoke-Captured {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [int]$ExpectedExitCode = 0,
        [string]$Label = $File
    )

    $output = (& $File @CommandArgs 2>&1 | Out-String)
    Assert-ExitCode $LASTEXITCODE $ExpectedExitCode $Label
    return $output
}

function Test-PowerShellSyntax {
    $failed = $false
    Get-ChildItem -Path $kitRoot -Recurse -Filter "*.ps1" | ForEach-Object {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            $failed = $true
            Write-Host "SYNTAX ERROR: $($_.FullName)" -ForegroundColor Red
            $errors | ForEach-Object { Write-Host "  $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
        }
    }

    Assert-True (-not $failed) "PowerShell syntax check failed."
}

function Test-HelpTemplateShape {
    $zhLines = [System.IO.File]::ReadAllLines((Join-Path $kitRoot "help\zh-CN.txt"))
    $enLines = [System.IO.File]::ReadAllLines((Join-Path $kitRoot "help\en.txt"))
    $zhBlankCount = @($zhLines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
    $enBlankCount = @($enLines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count

    Assert-True ($zhLines.Count -eq $enLines.Count) "help templates should keep the same line count. zh-CN=$($zhLines.Count), en=$($enLines.Count)."
    Assert-True ($zhBlankCount -eq $enBlankCount) "help templates should keep the same blank-line count. zh-CN=$zhBlankCount, en=$enBlankCount."
}

function New-MockWsl {
    param([string]$TempRoot)

    $projectDir = Join-Path $TempRoot "MockWsl"
    $publishDir = Join-Path $TempRoot "publish"
    $shimDir = Join-Path $TempRoot "shim"
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null

    dotnet new console --use-program-main --name MockWsl --output $projectDir | Out-Null
    $program = @'
using System;
using System.IO;
using System.Linq;
using System.Text;

namespace MockWsl;

internal class Program
{
    static int Main(string[] args)
    {
        var path = Environment.GetEnvironmentVariable("MOCK_WSL_ARGS_PATH");
        if (!string.IsNullOrWhiteSpace(path))
        {
            File.WriteAllLines(path, args.Select(a => Convert.ToBase64String(Encoding.UTF8.GetBytes(a))));
        }

        var exitCodeText = Environment.GetEnvironmentVariable("MOCK_WSL_EXIT_CODE");
        return int.TryParse(exitCodeText, out var exitCode) ? exitCode : 0;
    }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $projectDir "Program.cs"), $program, [System.Text.UTF8Encoding]::new($false))
    dotnet publish $projectDir -c Release -r win-x64 --self-contained false -o $publishDir | Out-Null

    Copy-Item -LiteralPath (Join-Path $publishDir "MockWsl.exe") -Destination (Join-Path $shimDir "wsl.exe") -Force
    Copy-Item -LiteralPath (Join-Path $publishDir "MockWsl.dll") -Destination (Join-Path $shimDir "MockWsl.dll") -Force
    Copy-Item -LiteralPath (Join-Path $publishDir "MockWsl.runtimeconfig.json") -Destination (Join-Path $shimDir "MockWsl.runtimeconfig.json") -Force

    return $shimDir
}

function Read-MockWslArgs {
    param([string]$Path)

    return @([System.IO.File]::ReadAllLines($Path) | ForEach-Object {
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
    })
}

function Assert-MockWslNotCalled {
    param(
        [string]$Path,
        [string]$Label
    )

    Assert-True (-not (Test-Path -LiteralPath $Path)) "$Label should not call wsl.exe."
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Set-EntryLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )

    $line = 'set "' + $Name + "=" + $Value + '"'
    return [regex]::Replace($Content, '(?m)^set "' + [regex]::Escape($Name) + '=.*"\r?$', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
}

function New-WslSmokeEntryFile {
    param(
        [string]$Name,
        [string]$Source = "Ubuntu",
        [string]$InstallDir,
        [string]$BackupDir,
        [string]$User = "john"
    )

    $entryPath = Join-Path $repoRoot ("$Name.cmd")
    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "WSL_name" $Name
    $content = Set-EntryLine $content "WSL_user" $User
    $content = Set-EntryLine $content "WSL_source" $Source
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $content = Set-EntryLine $content "WSL_install_dir" $InstallDir
    }
    if (-not [string]::IsNullOrWhiteSpace($BackupDir)) {
        $content = Set-EntryLine $content "WSL_backup_dir" $BackupDir
    }
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($entryPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $entryPath
}

function New-SshEnableTestEntryFile {
    param([string]$TempRoot)

    $publicKeyPath = Join-Path $TempRoot "id_wslkit_smoke.pub"
    $publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZha2VLZXlGb3JTbW9rZVRlc3RPbmx5 wsl-kit-smoke"
    [System.IO.File]::WriteAllText($publicKeyPath, "$publicKey`r`n", [System.Text.UTF8Encoding]::new($false))

    $port = Get-FreeTcpPort
    $entryPath = Join-Path $repoRoot ("wsl.smoke-" + [guid]::NewGuid().ToString("N") + ".cmd")
    $content = [System.IO.File]::ReadAllText($entryFile)
    $sshKeyLine = 'set "WSL_SSH_public_key=' + $publicKeyPath + '"'
    $content = [regex]::Replace($content, '(?m)^set "WSL_SSH_public_key=.*"\r?$', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $sshKeyLine })
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($entryPath, $content, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        EntryFile = $entryPath
        Port      = $port
    }
}

function Decode-Base64ShRunner {
    param([string]$Runner)

    if ($Runner -notmatch "^printf '%s' '([^']+)' \| base64 -d \| sh$") {
        throw "Unexpected shell runner: $Runner"
    }

    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
}

function Test-WslDistributionExists {
    param([string]$Name)

    try {
        $items = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\*" -ErrorAction SilentlyContinue
        return ($null -ne (@($items | Where-Object { $_.DistributionName -eq $Name } | Select-Object -First 1)[0]))
    } catch {
        return $false
    }
}

Push-Location $repoRoot
try {
    Write-Host "syntax"
    Test-PowerShellSyntax
    Test-HelpTemplateShape

    Write-Host "basic commands"
    $entryTemplate = [System.IO.File]::ReadAllText($entryFile)
    Assert-True (-not $entryTemplate.Contains("WSL_systemd")) "entry template should not declare WSL_systemd."
    Assert-True (-not $entryTemplate.Contains("WSL_network")) "entry template should not declare WSL_network settings."
    Assert-True (-not $entryTemplate.Contains("WSL_SSH_port")) "entry template should not declare WSL_SSH_port."
    Assert-True (-not $entryTemplate.Contains("WSL_SSH_key")) "entry template should not declare WSL_SSH_key."
    Assert-True ($entryTemplate.Contains("WSL_SSH_public_key")) "entry template should declare WSL_SSH_public_key."

    Invoke-Checked $entryFile @("-h") 0 "entry help"
    $defaultHelpOutput = Invoke-Captured $entryFile @("--help", "en") 0 "entry help includes doctor"
    Assert-True ($defaultHelpOutput.Contains("wsl01 doctor")) "top-level help should show wsl01 doctor."
    Assert-True (-not $defaultHelpOutput.Contains("ctl doctor")) "top-level help should not show hidden ctl doctor."
    $oldHelpLang = $env:WSL_KIT_HELP_LANG
    try {
        $helpCases = @(
            @{ Args = @("--help", "zh"); Env = "en"; Expected = "version 1.0"; Unexpected = "# Basic usage:"; Label = "entry --help zh" },
            @{ Args = @("--help", "en"); Env = "zh-CN"; Expected = "# Basic usage:"; Unexpected = "# 基本用法:"; Label = "entry --help en" },
            @{ Args = @("-h", "zh"); Env = "en"; Expected = "version 1.0"; Unexpected = "# Basic usage:"; Label = "entry -h zh" },
            @{ Args = @("-h", "en"); Env = "zh-CN"; Expected = "# Basic usage:"; Unexpected = "# 基本用法:"; Label = "entry -h en" },
            @{ Args = @("/?", "zh"); Env = "en"; Expected = "version 1.0"; Unexpected = "# Basic usage:"; Label = "entry /? zh" },
            @{ Args = @("/?", "en"); Env = "zh-CN"; Expected = "# Basic usage:"; Unexpected = "# 基本用法:"; Label = "entry /? en" }
        )

        foreach ($case in $helpCases) {
            $env:WSL_KIT_HELP_LANG = $case["Env"]
            $output = Invoke-Captured -File $entryFile -CommandArgs @($case["Args"]) -ExpectedExitCode 0 -Label $case["Label"]
            $preview = $output.Substring(0, [Math]::Min(80, $output.Length)) -replace "\r?\n", " "
            Assert-True ($output.Contains($case["Expected"])) "$($case["Label"]) should override WSL_KIT_HELP_LANG. Preview: $preview"
            Assert-True (-not $output.Contains($case["Unexpected"])) "$($case["Label"]) should not use WSL_KIT_HELP_LANG. Preview: $preview"
        }
    } finally {
        $env:WSL_KIT_HELP_LANG = $oldHelpLang
    }
    $statusOutput = Invoke-Captured $entryFile @("status") 0 "entry status"
    Assert-True ($statusOutput.Contains("Backup size:")) "status should show instance backup size."
    Assert-True ($statusOutput.Contains("Backup root size:")) "status should show backup root size."
    Assert-True ($statusOutput.Contains("Download cache size:")) "status should show download cache size."
    Assert-True ($statusOutput.Contains("Alive:")) "status should show alive summary."
    Assert-True ($statusOutput.Contains("More status:")) "status should show sub-status shortcuts."
    Assert-True ($statusOutput.Contains("status ssh | port | systemd")) "status should mention status subcommands."
    Invoke-Checked $entryFile @("doctor", "extra") 1 "reject doctor extra args"
    Invoke-Checked $entryFile @("ctl", "doctor", "extra") 1 "reject hidden ctl doctor extra args"
    $directPortStatusOutput = Invoke-Captured $entryFile @("status", "port") 0 "status port"
    Assert-True ($directPortStatusOutput.Contains("Networking mode:")) "status port should show networking mode."
    Assert-True ($directPortStatusOutput.Contains("Strategy:")) "status port should show selected strategy."
    $portStatusOutput = Invoke-Captured $entryFile @("ctl", "port", "status") 0 "port status"
    Assert-True ($portStatusOutput.Contains("Networking mode:")) "port status should show networking mode."
    Assert-True ($portStatusOutput.Contains("Strategy:")) "port status should show selected strategy."
    $ctlHelpOutput = Invoke-Captured $entryFile @("ctl", "help") 1 "ctl help removed"
    Assert-True ($ctlHelpOutput.Contains("Run: wsl01 --help")) "ctl help should point to top-level help."
    Assert-True (-not $ctlHelpOutput.Contains("Usage:")) "ctl help should not print a second usage document."
    Invoke-Checked $entryFile @("ctl", "config") 1 "reject config without dir"
    Invoke-Checked $entryFile @("ctl", "config", "dir", "extra") 1 "reject config dir extra args"
    Invoke-Checked $entryFile @("ctl", "install", "dir", "extra") 1 "reject install dir extra args"
    Invoke-Checked $entryFile @("ctl", "port") 0 "port usage"
    Invoke-Checked $entryFile @("ctl", "port", "expose", "abc") 1 "reject non-numeric port expose"
    Invoke-Checked $entryFile @("ctl", "port", "remove", "70000") 1 "reject out-of-range port remove"
    Invoke-Checked $entryFile @("ctl", "port", "status", "70000") 1 "reject out-of-range port status"
    Invoke-Checked $entryFile @("ctl", "port", "expose", "8080", "--listen-address", "127.0.0.1", "--dry-run") 1 "reject custom port listen address"
    $oldUserProfile = $env:USERPROFILE
    $tempUserProfile = Join-Path $env:TEMP ("wslkit-profile-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $tempUserProfile -Force | Out-Null

        $env:USERPROFILE = $tempUserProfile
        $natDryRunOutput = Invoke-Captured $entryFile @("ctl", "port", "expose", "8080", "80", "--dry-run") 0 "nat port expose dry-run"
        Assert-True ($natDryRunOutput.Contains("listenaddress=0.0.0.0")) "nat dry-run should use the fixed 0.0.0.0 listen address."
        Assert-True ($natDryRunOutput.Contains("connectaddress=<WSL-IP>")) "nat dry-run should not require a live WSL IP."
        Assert-True ($natDryRunOutput.Contains("wsl_instance_kit-")) "nat dry-run should use the wsl_instance_kit rule prefix."
        Invoke-Checked $entryFile @("ctl", "port", "expose", "8080", "80", "--dry-run", "--uac") 0 "nat port expose dry-run with uac option"

        [System.IO.File]::WriteAllText((Join-Path $tempUserProfile ".wslconfig"), "[wsl2]`r`nnetworkingMode=mirrored # smoke note`r`n", [System.Text.UTF8Encoding]::new($false))
        $mirroredStatusOutput = Invoke-Captured $entryFile @("ctl", "port", "status") 0 "port status inline comment mode"
        Assert-True ($mirroredStatusOutput.Contains("Networking mode: mirrored")) "port status should ignore inline comments in networkingMode."
    } finally {
        $env:USERPROFILE = $oldUserProfile
        if (Test-Path -LiteralPath $tempUserProfile) {
            Remove-Item -LiteralPath $tempUserProfile -Recurse -Force
        }
    }
    Invoke-Checked $entryFile @("ctl", "install", "--dry-run") 0 "install dry-run"
    Invoke-Checked $kitCmd @("--entry-file", $entryFile, "status") 0 "kit --entry-file status"

    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        Write-Host "mock passthrough skipped: dotnet.exe not found" -ForegroundColor Yellow
        return
    }

    Write-Host "mock passthrough"
    $tempRoot = Join-Path $env:TEMP ("wslkit-smoke-" + [guid]::NewGuid().ToString("N"))
    $argsFile = Join-Path $tempRoot "args.txt"
    $oldPath = $env:PATH
    $oldAppData = $env:APPDATA
    $oldArgsPath = $env:MOCK_WSL_ARGS_PATH
    $oldExitCode = $env:MOCK_WSL_EXIT_CODE
    $sshEnableEntryFile = $null
    $restoreEntryFile = $null

    try {
        $shimDir = New-MockWsl $tempRoot
        $tempAppData = Join-Path $tempRoot "appdata"
        New-Item -ItemType Directory -Path $tempAppData -Force | Out-Null

        $env:PATH = "$shimDir;$oldPath"
        $env:APPDATA = $tempAppData
        $env:MOCK_WSL_ARGS_PATH = $argsFile

        $cmdLine = 'call "{0}" alpha "" "two words" omega' -f $entryFile
        & cmd.exe /d /c $cmdLine
        Assert-ExitCode $LASTEXITCODE 0 "passthrough empty arg"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "alpha", "", "two words", "omega") "passthrough empty arg"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $installHintOutput = Invoke-Captured $entryFile @("install") 1 "hint missing ctl install"
        Assert-True ($installHintOutput.Contains("wsl01 ctl install")) "bare install should suggest ctl install."
        Assert-True ($installHintOutput.Contains("wsl01 -- install")) "bare install should show explicit passthrough."
        Assert-True (-not (Test-Path -LiteralPath $argsFile)) "bare install should not passthrough to wsl.exe."

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $shutdownHintOutput = Invoke-Captured $entryFile @("shutdown") 1 "hint missing vm shutdown"
        Assert-True ($shutdownHintOutput.Contains("wsl01 vm shutdown")) "bare shutdown should suggest vm shutdown."
        Assert-True ($shutdownHintOutput.Contains("wsl01 -- shutdown")) "bare shutdown should show explicit passthrough."
        Assert-True (-not (Test-Path -LiteralPath $argsFile)) "bare shutdown should not passthrough to wsl.exe."

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $terminateHintOutput = Invoke-Captured $entryFile @("-t") 1 "hint missing control layer -t"
        Assert-True ($terminateHintOutput.Contains("wsl01 ctl -t")) "bare -t should suggest ctl -t."
        Assert-True ($terminateHintOutput.Contains("wsl01 vm -t")) "bare -t should suggest vm -t."
        Assert-True ($terminateHintOutput.Contains("wsl01 -- -t")) "bare -t should show explicit passthrough."
        Assert-True (-not (Test-Path -LiteralPath $argsFile)) "bare -t should not passthrough to wsl.exe."

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $configHintOutput = Invoke-Captured $entryFile @("config") 1 "hint missing ctl config dir"
        Assert-True ($configHintOutput.Contains("wsl01 ctl config dir")) "bare config should suggest ctl config dir."
        Assert-True ($configHintOutput.Contains("wsl01 -- config")) "bare config should show explicit passthrough."
        Assert-True (-not (Test-Path -LiteralPath $argsFile)) "bare config should not passthrough to wsl.exe."

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $aliveHintOutput = Invoke-Captured $entryFile @("alive", "600") 1 "hint missing ctl alive"
        Assert-True ($aliveHintOutput.Contains("wsl01 ctl alive 600")) "bare alive should suggest ctl alive."
        Assert-True ($aliveHintOutput.Contains("wsl01 -- alive 600")) "bare alive should show explicit passthrough."
        Assert-MockWslNotCalled $argsFile "bare alive"

        Invoke-Checked $entryFile @("-u", "root", "--", "whoami") 0 "passthrough native option"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "-u", "root", "--", "whoami") "passthrough native option"

        Invoke-Checked $entryFile @("--", "ssh") 0 "explicit passthrough control-looking command"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "--", "ssh") "explicit passthrough control-looking command"

        Invoke-Checked $entryFile @("ctl", "alive", "-1") 1 "reject negative alive duration"
        Invoke-Checked $entryFile @("ctl", "alive", "0") 1 "reject removed alive 0"
        Invoke-Checked $entryFile @("ctl", "alive", "9") 1 "reject too-short alive duration"
        Invoke-Checked $entryFile @("ctl", "alive", "12", "extra") 1 "reject extra alive duration"
        Invoke-Checked $entryFile @("ctl", "alive", "12", "--unknown") 1 "reject unknown alive option"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $aliveDryRunOutput = Invoke-Captured $entryFile @("ctl", "alive", "123", "--dry-run") 0 "alive dry-run"
        Assert-True ($aliveDryRunOutput.Contains("sleep 123")) "alive dry-run should show the sleep command."
        Assert-True ($aliveDryRunOutput.Contains("wsl_instance_kit_alive_wsl01")) "alive dry-run should include the alive marker."
        Assert-True ($aliveDryRunOutput.Contains("schtasks.exe /Create")) "alive dry-run should show the scheduled task create command."
        Assert-MockWslNotCalled $argsFile "alive dry-run"

        $aliveLogonDryRunOutput = Invoke-Captured $entryFile @("ctl", "alive", "--dry-run") 0 "alive logon dry-run"
        Assert-True ($aliveLogonDryRunOutput.Contains("current-user logon")) "bare ctl alive dry-run should configure logon auto-start."
        Assert-True ($aliveLogonDryRunOutput.Contains("while :; do sleep 3600; done")) "bare ctl alive dry-run should keep alive forever."

        $aliveStatusOutput = Invoke-Captured $entryFile @("ctl", "alive", "status") 0 "alive status"
        Assert-True ($aliveStatusOutput.Contains("WSL alive: wsl01")) "alive status should show heading."
        Assert-True ($aliveStatusOutput.Contains("Alive task:")) "alive status should show the scheduled task name."
        Assert-True ($aliveStatusOutput.Contains("Alive setting:")) "alive status should show the configured mode."
        Assert-True ($aliveStatusOutput.Contains("Task State:")) "alive status should show the scheduled task state."

        $aliveInvalidDurationOutput = Invoke-Captured $entryFile @("ctl", "alive", "auto") 1 "reject non-numeric alive duration"
        Assert-True ($aliveInvalidDurationOutput.Contains("duration must be an integer")) "non-numeric alive duration should be rejected."

        $aliveOffOutput = Invoke-Captured $entryFile @("ctl", "alive", "off", "--dry-run") 0 "alive off dry-run"
        Assert-True ($aliveOffOutput.Contains("Would disable all WSL alive settings")) "alive off dry-run should report disabled."

        $target = Join-Path $tempRoot "out.tar"
        Invoke-Checked $entryFile @("ctl", "export", $target) 0 "export fixed format"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--export", "wsl01", ([System.IO.Path]::GetFullPath($target)), "--format", "tar") "export fixed format"

        Invoke-Checked $entryFile @("ctl", "export", "--format", "tar.gz", $target) 1 "reject inline export format"
        Invoke-Checked $entryFile @("ctl", "backup", "--format", "tar.gz") 1 "reject inline backup format"
        Invoke-Checked $entryFile @("ctl", "backup", "dir", "extra") 1 "reject backup dir extra args"

        $restoreName = "wsl.smoke-restore-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $restoreInstallDir = Join-Path $tempRoot "restore-install"
        $restoreBackupDir = Join-Path $tempRoot "restore-backup"
        $restoreEntryFile = New-WslSmokeEntryFile -Name $restoreName -InstallDir $restoreInstallDir -BackupDir $restoreBackupDir -User ""
        New-Item -ItemType Directory -Path $restoreBackupDir -Force | Out-Null

        $backupOutput = Invoke-Captured $restoreEntryFile @("ctl", "backup") 0 "backup output path"
        Assert-True ($backupOutput -match 'Backup archive:\s+(?<path>[^\r\n]+)') "backup should print generated archive path. Output: $backupOutput"
        $backupOutputPath = $Matches["path"].Trim()
        $restoreBackupDirFull = [System.IO.Path]::GetFullPath($restoreBackupDir).TrimEnd("\") + "\"
        Assert-True ($backupOutputPath.StartsWith($restoreBackupDirFull, [System.StringComparison]::OrdinalIgnoreCase)) "backup path should be under WSL_backup_dir. Output: $backupOutput"
        Assert-True ($backupOutputPath.Contains("Backup_$restoreName`_") -and $backupOutputPath.EndsWith(".tar", [System.StringComparison]::OrdinalIgnoreCase)) "backup path should include the generated archive filename. Output: $backupOutput"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--export", $restoreName, $backupOutputPath, "--format", "tar") "backup args should use printed path"

        $restoreArchive = Join-Path $restoreBackupDir ("Backup_{0}_20260618000102.tar" -f $restoreName)
        [System.IO.File]::WriteAllBytes($restoreArchive, [byte[]](1, 2, 3))
        $restoreVhd = Join-Path $restoreBackupDir ("Backup_{0}_20260618000103.vhdx" -f $restoreName)
        [System.IO.File]::WriteAllBytes($restoreVhd, [byte[]](4, 5, 6))

        $backupListOutput = Invoke-Captured $restoreEntryFile @("ctl", "backup", "list") 0 "backup list"
        Assert-True ($backupListOutput.Contains("WSL backups: $restoreName")) "backup list should show the entry name."
        Assert-True ($backupListOutput.Contains((Split-Path -Leaf $restoreArchive))) "backup list should show tar archives. Output: $backupListOutput"
        Assert-True ($backupListOutput.Contains((Split-Path -Leaf $restoreVhd))) "backup list should show vhdx archives. Output: $backupListOutput"
        Invoke-Checked $restoreEntryFile @("ctl", "backup", "list", "extra") 1 "reject backup list extra args"
        Invoke-Checked $restoreEntryFile @("ctl", "restore") 1 "reject restore without archive"
        Invoke-Checked $restoreEntryFile @("ctl", "restore", (Join-Path $restoreBackupDir "missing.tar")) 1 "reject missing restore archive"

        Invoke-Checked $restoreEntryFile @("ctl", "restore", (Split-Path -Leaf $restoreArchive)) 0 "restore from backup basename"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--import", $restoreName, ([System.IO.Path]::GetFullPath($restoreInstallDir)), ([System.IO.Path]::GetFullPath($restoreArchive)), "--version", "2") "restore import args"

        $restoreVhdDryRun = Invoke-Captured $restoreEntryFile @("ctl", "restore", $restoreVhd, "--dry-run") 0 "restore vhd dry-run"
        Assert-True ($restoreVhdDryRun.Contains("--vhd")) "restore vhd dry-run should pass --vhd."

        Invoke-Checked $entryFile @("ctl", "downloads") 1 "reject downloads without dir"
        Invoke-Checked $entryFile @("ctl", "downloads", "dir", "extra") 1 "reject downloads dir extra args"
        Invoke-Checked $entryFile @("ctl", "download", "dir", "extra") 1 "reject download dir extra args"
        $vmStatusOutput = Invoke-Captured $entryFile @("vm", "status") 0 "vm status"
        Assert-True ($vmStatusOutput.Contains("WSL VM: current Windows user")) "vm status should show the VM status heading."
        Assert-True ($vmStatusOutput.Contains("Networking mode:")) "vm status should show networking mode."
        $vmAliveListOutput = Invoke-Captured $entryFile @("vm", "alive", "list") 0 "vm alive list"
        Assert-True ($vmAliveListOutput.Contains("WSL alive tasks: current Windows user")) "vm alive list should show heading."
        Invoke-Checked $entryFile @("vm", "alive", "list", "extra") 1 "reject vm alive list extra args"
        Invoke-Checked $entryFile @("vm", "alive", "off", "wsl01") 1 "reject guessed vm alive task name"
        Invoke-Checked $entryFile @("vm", "alive", "off", "alive_missing") 1 "reject missing vm alive task"
        Invoke-Checked $entryFile @("vm", "shutdown") 0 "vm shutdown"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--shutdown") "vm shutdown args"
        Invoke-Checked $entryFile @("vm", "-t") 0 "vm -t"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--shutdown") "vm -t args"
        Invoke-Checked $entryFile @("vm", "status", "extra") 1 "reject vm status extra args"
        Invoke-Checked $entryFile @("vm", "settings", "extra") 1 "reject vm settings extra args"
        Invoke-Checked $entryFile @("vm", "welcome", "extra") 1 "reject vm welcome extra args"
        Invoke-Checked $entryFile @("vm", "shutdown", "extra") 1 "reject vm shutdown extra args"
        Invoke-Checked $entryFile @("vm", "config") 1 "reject unknown vm command"

        $env:MOCK_WSL_EXIT_CODE = "9"
        Invoke-Checked $entryFile @("ctl", "install") 9 "native install failure preserves exit code"
        $env:MOCK_WSL_EXIT_CODE = $null

        Invoke-Checked $entryFile @("ctl", "install", "--fallback", "--dry-run") 0 "fallback dry-run"
        Invoke-Checked $entryFile @("ctl", "install", "--fallback", "--refresh", "--dry-run") 1 "reject removed fallback refresh"
        $systemdEnableOutput = Invoke-Captured $entryFile @("ctl", "systemd", "enable") 0 "systemd enable success message"
        Assert-True ($systemdEnableOutput.Contains("Systemd enabled in /etc/wsl.conf.")) "systemd enable should print success."
        Assert-True ($systemdEnableOutput.Contains("wsl01 vm shutdown")) "systemd enable should suggest restart command."
        Invoke-Checked $entryFile @("ctl", "ssh", "enable") 1 "reject ssh enable without port"
        Invoke-Checked $entryFile @("ctl", "ssh", "enable", "abc") 1 "reject non-numeric ssh port"
        Invoke-Checked $entryFile @("ctl", "ssh", "enable", "2222", "extra") 1 "reject ssh enable extra args"
        $env:MOCK_WSL_EXIT_CODE = "1"
        Invoke-Checked $entryFile @("ctl", "ssh", "enable", "2222") 1 "reject ssh enable without active systemd"
        $env:MOCK_WSL_EXIT_CODE = $null

        $sshEnableCase = New-SshEnableTestEntryFile $tempRoot
        $sshEnableEntryFile = $sshEnableCase.EntryFile
        $sshEnablePort = [string]$sshEnableCase.Port
        Invoke-Checked $sshEnableEntryFile @("ctl", "ssh", "enable", $sshEnablePort) 0 "ssh enable script generation"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "ssh enable root script prefix"
        Assert-True ($actual.Count -eq 8) "ssh enable should pass a single shell runner."
        $enableScript = Decode-Base64ShRunner $actual[7]
        Assert-True ($enableScript.Contains(('port_input="{0}"' -f $sshEnablePort))) "ssh enable script should use the explicit port argument."
        Assert-True ($enableScript.Contains("dnf install -y openssh-server")) "ssh enable script should support dnf."
        Assert-True ($enableScript.Contains("yum install -y openssh-server")) "ssh enable script should support yum."
        Assert-True ($enableScript.Contains("microdnf install -y openssh-server")) "ssh enable script should support microdnf."
        Assert-True ($enableScript.Contains("ssh-keygen -A")) "ssh enable script should generate host keys."

        if (Test-WslDistributionExists "wsl01") {
            Invoke-Checked $entryFile @("ctl", "ssh", "status") 0 "ssh status"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "ssh status root script prefix"
            Assert-True ($actual.Count -eq 8) "ssh status should pass a single shell runner."

            Invoke-Checked $entryFile @("status", "ssh") 0 "status ssh"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "status ssh root script prefix"
            Assert-True ($actual.Count -eq 8) "status ssh should pass a single shell runner."

            Invoke-Checked $entryFile @("status", "systemd") 0 "status systemd"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "status systemd root script prefix"
            Assert-True ($actual.Count -eq 8) "status systemd should pass a single shell runner."

            Invoke-Checked $entryFile @("ctl", "systemd", "status") 0 "ctl systemd status"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "ctl systemd status root script prefix"
            Assert-True ($actual.Count -eq 8) "ctl systemd status should pass a single shell runner."
        } else {
            Write-Host "ssh/systemd status skipped: wsl01 is not installed" -ForegroundColor Yellow
        }
    } finally {
        $env:PATH = $oldPath
        $env:APPDATA = $oldAppData
        $env:MOCK_WSL_ARGS_PATH = $oldArgsPath
        $env:MOCK_WSL_EXIT_CODE = $oldExitCode
        if ($sshEnableEntryFile -and (Test-Path -LiteralPath $sshEnableEntryFile)) {
            Remove-Item -LiteralPath $sshEnableEntryFile -Force
        }
        if ($restoreEntryFile -and (Test-Path -LiteralPath $restoreEntryFile)) {
            Remove-Item -LiteralPath $restoreEntryFile -Force
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    Write-Host "smoke ok" -ForegroundColor Green
} finally {
    Pop-Location
}

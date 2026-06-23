[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryFile = Join-Path $repoRoot "wsl01.cmd"
$kitCmd = Join-Path $repoRoot "_lib\wsl_instance_kit\kit.cmd"
$kitRoot = Join-Path $repoRoot "_lib\wsl_instance_kit"
. (Join-Path $PSScriptRoot "smoke.relocate.ps1")

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

. (Join-Path $PSScriptRoot "smoke.entry.ps1")
. (Join-Path $PSScriptRoot "smoke.json.ps1")
. (Join-Path $PSScriptRoot "smoke.mock.ps1")
. (Join-Path $PSScriptRoot "smoke.env-user.ps1")
. (Join-Path $PSScriptRoot "smoke.alive.ps1")
. (Join-Path $PSScriptRoot "smoke.port.ps1")

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
    $content = Set-EntryLine $content "WSL_env_file" ""
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
$originalUserProfile = $env:USERPROFILE
$smokeUserProfileRoot = Join-Path $env:TEMP ("wslkit-profile-" + [guid]::NewGuid().ToString("N"))
try {
    Initialize-SmokeUserProfile $smokeUserProfileRoot
    $env:USERPROFILE = $smokeUserProfileRoot
    Write-Host "syntax"
    Test-PowerShellSyntax
    Test-HelpTemplateShape
    Test-GitAttributesCommandLineEndings
    Test-EntryCommandLineEndings @($entryFile, (Join-Path $repoRoot "wsl02.cmd"))
    Test-LineEndingDiagnosticInvalidPath
    Test-PortInventoryDryRun
    Test-WslAliveHeadlessTaskAction

    Write-Host "basic commands"
    $entryTemplate = [System.IO.File]::ReadAllText($entryFile)
    Test-EntryTemplateShape $entryTemplate
    Test-WslNameValidationSlowPath

    Invoke-Checked $entryFile @(".help") 0 "entry dot help"
    $defaultHelpOutput = Invoke-Captured $entryFile @(".help", "en") 0 "entry dot help includes doctor"
    Assert-True ($defaultHelpOutput.Contains("wsl01 .doctor")) "help should show dotted doctor."
    Assert-True ($defaultHelpOutput.Contains("wsl01.cmd")) "help should show the entry file name."
    Assert-True (-not $defaultHelpOutput.Contains("{{ENTRY_FILE}}")) "help should replace the entry-file placeholder."
    Assert-True ($defaultHelpOutput.Contains("wsl01 .help en")) "help should show dotted help."
    Assert-True (-not $defaultHelpOutput.Contains("wsl01 --help")) "help should not promote bare help flags."
    Assert-True ($defaultHelpOutput -match '(?m)^\s*wsl01 \.t\s{2,}') "help should show short terminate command."
    Assert-True ($defaultHelpOutput -match '(?m)^\s*wsl01 \.relocate\s{2,}') "help should show relocate command."
    Assert-True ($defaultHelpOutput.Contains("wsl01 .sshd enable 2222")) "help should show dotted sshd service management."
    Assert-True ($defaultHelpOutput -match '(?m)^\s*wsl01 \.port del 8080\s{2,}') "help should show port del."
    Assert-True (-not $defaultHelpOutput.Contains("wsl01 doctor")) "help should not show bare doctor."
    Assert-True (-not $defaultHelpOutput.Contains("wsl01 ssh enable")) "help should not show bare ssh service management."
    $oldHelpLang = $env:WSL_KIT_HELP_LANG
    try {
        $helpCases = @(
            @{ Args = @(".help", "zh"); Env = "en"; Expected = "version 1.0"; Unexpected = "# Basic usage:"; Label = "entry .help zh" },
            @{ Args = @(".help", "en"); Env = "zh-CN"; Expected = "# Basic usage:"; Unexpected = "# 基本用法:"; Label = "entry .help en" },
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
    $statusOutput = Invoke-Captured $entryFile @(".status") 0 "entry status"
    Assert-True ($statusOutput.Contains("Backup size:")) "status should show instance backup size."
    Assert-True ($statusOutput.Contains("WSL_env_file:")) "status should show WSL_env_file."
    Assert-True ($statusOutput.Contains("WSL_SSH_public_key:")) "status should show WSL_SSH_public_key."
    Assert-True ($statusOutput.Contains("Backup root size:")) "status should show backup root size."
    Assert-True ($statusOutput.Contains("Download cache size:")) "status should show download cache size."
    Assert-True ($statusOutput.Contains("Alive:")) "status should show alive summary."
    Assert-True ($statusOutput.Contains("Port:")) "status should show port summary."
    Assert-True ($statusOutput.Contains("More status:")) "status should show sub-status shortcuts."
    Assert-True ($statusOutput.Contains(".status sshd | port | systemd")) "status should mention status subcommands."
    Test-StatusJsonOutput
    Test-DoctorJsonOutput
    Test-EntryLineEndingStatusDiagnostics
    Invoke-Checked $entryFile @(".doctor", "extra") 1 "reject doctor extra args"
    $directPortStatusOutput = Invoke-Captured $entryFile @(".status", "port") 0 "status port"
    Assert-True ($directPortStatusOutput.Contains("Networking mode:")) "status port should show networking mode."
    Assert-True ($directPortStatusOutput.Contains("Strategy:")) "status port should show selected strategy."
    $portStatusOutput = Invoke-Captured $entryFile @(".port", "status") 0 "port status"
    Assert-True ($portStatusOutput.Contains("Networking mode:")) "port status should show networking mode."
    Assert-True ($portStatusOutput.Contains("Strategy:")) "port status should show selected strategy."
    Invoke-Checked $entryFile @(".dir") 1 "reject dir without target"
    Invoke-Checked $entryFile @(".dir", "install", "extra") 1 "reject dir install extra args"
    Invoke-Checked $entryFile @(".dir", "backup", "extra") 1 "reject dir backup extra args"
    Invoke-Checked $entryFile @(".dir", "downloads", "extra") 1 "reject dir downloads extra args"
    Invoke-Checked $entryFile @(".dir", "config", "extra") 1 "reject dir config extra args"
    Invoke-Checked $entryFile @(".dir", "ssh", "extra") 1 "reject dir ssh extra args"
    $portUsageOutput = Invoke-Captured $entryFile @(".port") 0 "port usage"
    Assert-True ($portUsageOutput.Contains(".port del <listen-port>")) "port usage should show del."
    Invoke-Checked $entryFile @(".port", "expose", "abc") 1 "reject non-numeric port expose"
    Invoke-Checked $entryFile @(".port", "del", "70000") 1 "reject out-of-range port del"
    Invoke-Checked $entryFile @(".port", "status", "70000") 1 "reject out-of-range port status"
    Invoke-Checked $entryFile @(".port", "expose", "8080", "--listen-address", "127.0.0.1", "--dry-run") 1 "reject custom port listen address"
    $oldUserProfile = $env:USERPROFILE
    $tempUserProfile = Join-Path $env:TEMP ("wslkit-profile-" + [guid]::NewGuid().ToString("N"))
    try {
        Initialize-SmokeUserProfile $tempUserProfile

        $env:USERPROFILE = $tempUserProfile
        $natDryRunOutput = Invoke-Captured $entryFile @(".port", "expose", "8080", "80", "--dry-run") 0 "nat port expose dry-run"
        Assert-True ($natDryRunOutput.Contains("listenaddress=0.0.0.0")) "nat dry-run should use the fixed 0.0.0.0 listen address."
        Assert-True ($natDryRunOutput.Contains("connectaddress=<WSL-IP>")) "nat dry-run should not require a live WSL IP."
        Assert-True ($natDryRunOutput.Contains("wsl_instance_kit-")) "nat dry-run should use the wsl_instance_kit rule prefix."
        $natDelDryRunOutput = Invoke-Captured $entryFile @(".port", "del", "8080", "--dry-run") 0 "nat port del dry-run"
        Assert-True ($natDelDryRunOutput.Contains("portproxy delete")) "nat del dry-run should delete the NAT portproxy."
        Assert-True ($natDelDryRunOutput.Contains("Remove-NetFirewallRule")) "nat del dry-run should remove the firewall rule."
        Invoke-Checked $entryFile @(".port", "expose", "8080", "80", "--dry-run", "--uac") 0 "nat port expose dry-run with uac option"

        [System.IO.File]::WriteAllText((Join-Path $tempUserProfile ".wslconfig"), "[wsl2]`r`nnetworkingMode=mirrored # smoke note`r`n", [System.Text.UTF8Encoding]::new($false))
        $mirroredStatusOutput = Invoke-Captured $entryFile @(".port", "status") 0 "port status inline comment mode"
        Assert-True ($mirroredStatusOutput.Contains("Networking mode: mirrored")) "port status should ignore inline comments in networkingMode."
    } finally {
        $env:USERPROFILE = $oldUserProfile
        if (Test-Path -LiteralPath $tempUserProfile) {
            Remove-Item -LiteralPath $tempUserProfile -Recurse -Force
        }
    }
    $installDryRunOutput = Invoke-Captured $entryFile @(".install", "--dry-run") 0 "install dry-run"
    Assert-True ($installDryRunOutput.Contains("automatically try fallback install")) "install dry-run should mention automatic fallback for online sources."
    Invoke-Checked $kitCmd @("--entry-file", $entryFile, ".status") 0 "kit --entry-file status"

    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        Write-Host "mock passthrough skipped: dotnet.exe not found" -ForegroundColor Yellow
        return
    }

    Write-Host "mock passthrough"
    $tempRoot = Join-Path $env:TEMP ("wslkit-smoke-" + [guid]::NewGuid().ToString("N"))
    $argsFile = Join-Path $tempRoot "args.txt"
    $rawCommandLineFile = Join-Path $tempRoot "command-line.txt"
    $oldPath = $env:PATH
    $oldAppData = $env:APPDATA
    $oldArgsPath = $env:MOCK_WSL_ARGS_PATH
    $oldCommandLinePath = $env:MOCK_WSL_COMMAND_LINE_PATH
    $oldExitCode = $env:MOCK_WSL_EXIT_CODE
    $sshEnableEntryFile = $null
    $restoreEntryFile = $null
    $archiveEntryFile = $null
    $unknownSourceEntryFile = $null
    $fastPathEntryFile = $null

    try {
        $shimDir = New-MockWsl $tempRoot
        $tempAppData = Join-Path $tempRoot "appdata"
        New-Item -ItemType Directory -Path $tempAppData -Force | Out-Null

        $env:PATH = "$shimDir;$oldPath"
        $env:APPDATA = $tempAppData
        $env:MOCK_WSL_ARGS_PATH = $argsFile
        $env:MOCK_WSL_COMMAND_LINE_PATH = $rawCommandLineFile

        Test-EnvFileAndUserPasswdSmoke -TempRoot $tempRoot -ArgsFile $argsFile -RawCommandLineFile $rawCommandLineFile
        Test-WslNameValidationFastPath -ArgsFile $argsFile
        Test-WslNameValidationHelpFastPath -ArgsFile $argsFile
        Test-WslNameRequiredHelpFastPath -ArgsFile $argsFile

        $cmdLine = 'call "{0}" alpha "" "two words" omega' -f $entryFile
        & cmd.exe /d /c $cmdLine
        Assert-ExitCode $LASTEXITCODE 0 "passthrough empty arg"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "alpha", "", "two words", "omega") "passthrough empty arg"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $cmdLine = 'call "{0}" "alpha&beta"' -f $entryFile
        & cmd.exe /d /c $cmdLine
        Assert-ExitCode $LASTEXITCODE 0 "passthrough quoted cmd metachar arg"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "alpha&beta") "passthrough quoted cmd metachar arg"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $topInstallOutput = Invoke-Captured $entryFile @(".install", "--dry-run") 0 "dotted install dry-run"
        Assert-True ($topInstallOutput.Contains("automatically try fallback install")) "dotted install should run instance install."
        Assert-MockWslNotCalled $argsFile "dotted install dry-run"

        Test-WslRelocateSmoke -EntryFile $entryFile -TempRoot $tempRoot -ArgsFile $argsFile

        Invoke-Checked $entryFile @(".delete") 1 "delete requires yes"

        $fastPathEntryFile = Join-Path $repoRoot ("wsl.smoke-fast-" + [guid]::NewGuid().ToString("N") + ".cmd")
        $fastPathContent = [System.IO.File]::ReadAllText($entryFile)
        $fastPathContent = Set-EntryLine $fastPathContent "WSL_env_file" ""
        $fastPathContent = $fastPathContent -replace "`r?`n", "`r`n"
        [System.IO.File]::WriteAllText($fastPathEntryFile, $fastPathContent, [System.Text.UTF8Encoding]::new($false))

        $powerShellMarker = Join-Path $tempRoot "powershell-shim-marker.txt"
        Add-FailingPowerShellShim -ShimDir $shimDir -MarkerPath $powerShellMarker
        try {
            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @(".help", "en") 0 "dotted help explicit language fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "explicit help fast path should not start PowerShell."

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @(".t") 0 "dotted t fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "dotted t fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("--terminate", "wsl01") "dotted t args"

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @(".vm", "-s") 0 "vm shutdown fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "vm shutdown fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("--shutdown") "vm -s args"

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @(".vm", "default") 0 "vm default fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "vm default fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("--set-default", "wsl01") "vm default args"

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @() 0 "default shell passthrough fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "default shell fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~") "default shell passthrough args"
            $rawCommandLine = [System.IO.File]::ReadAllText($rawCommandLineFile)
            Assert-True ($rawCommandLine.Contains("-d wsl01")) "default shell fast path should leave the distro name unquoted for wsl.exe command-line parsing."
            Assert-True (-not $rawCommandLine.Contains('-d "wsl01"')) "default shell fast path should not quote the distro name."

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @("config") 0 "native config passthrough fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "native config fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "config") "native config passthrough args"

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @("--", "ssh") 0 "explicit passthrough fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "explicit passthrough fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "--", "ssh") "explicit passthrough control-looking command"
            $rawCommandLine = [System.IO.File]::ReadAllText($rawCommandLineFile)
            Assert-True (-not $rawCommandLine.Contains('"--"')) "explicit passthrough fast path should not quote simple native args."

            Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
            Invoke-Checked $fastPathEntryFile @(".myshell") 0 "unknown dotted command passthrough fast path"
            Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) "unknown dotted fast path should not start PowerShell."
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", ".myshell") "unknown dotted command passthrough args"
        } finally {
            Remove-PowerShellShim -ShimDir $shimDir
            Remove-Item -LiteralPath $powerShellMarker -Force -ErrorAction SilentlyContinue
        }

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $entryFile @("-t") 0 "native -t passthrough"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "-t") "native -t passthrough args"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $entryFile @("-s") 0 "native -s passthrough"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "-s") "native -s passthrough args"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $entryFile @("config") 0 "native config passthrough"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "config") "native config passthrough args"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $entryFile @("ssh", "example.test") 0 "native ssh passthrough"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "ssh", "example.test") "native ssh passthrough args"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $entryFile @(".myshell") 0 "unknown dotted command passthrough"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", ".myshell") "unknown dotted command passthrough args"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $entryFile @(".", "xxx") 0 "standalone dot passthrough"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", ".", "xxx") "standalone dot passthrough args"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $aliveTopOutput = Invoke-Captured $entryFile @(".alive", "600", "--dry-run") 0 "dotted alive dry-run"
        Assert-True ($aliveTopOutput.Contains("sleep 600")) "dotted alive should run instance alive."
        Assert-MockWslNotCalled $argsFile "dotted alive dry-run"

        Invoke-Checked $entryFile @("-u", "root", "--", "whoami") 0 "passthrough native option"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "-u", "root", "--", "whoami") "passthrough native option"

        Invoke-Checked $entryFile @("--", "ssh") 0 "explicit passthrough control-looking command"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl01", "-u", "john", "--cd", "~", "--", "ssh") "explicit passthrough control-looking command"

        Invoke-Checked $entryFile @(".alive", "-1") 1 "reject negative alive duration"
        Invoke-Checked $entryFile @(".alive", "0") 1 "reject zero alive duration"
        Invoke-Checked $entryFile @(".alive", "9") 1 "reject too-short alive duration"
        Invoke-Checked $entryFile @(".alive", "12", "extra") 1 "reject extra alive duration"
        Invoke-Checked $entryFile @(".alive", "12", "--unknown") 1 "reject unknown alive option"

        Remove-Item -LiteralPath $argsFile -Force -ErrorAction SilentlyContinue
        $aliveDryRunOutput = Invoke-Captured $entryFile @(".alive", "123", "--dry-run") 0 "alive dry-run"
        Assert-True ($aliveDryRunOutput.Contains("sleep 123")) "alive dry-run should show the sleep command."
        Assert-True ($aliveDryRunOutput.Contains("wsl_instance_kit_alive_wsl01")) "alive dry-run should include the alive marker."
        Assert-True ($aliveDryRunOutput.Contains("schtasks.exe /Create")) "alive dry-run should show the scheduled task create command."
        Assert-MockWslNotCalled $argsFile "alive dry-run"

        $aliveLogonDryRunOutput = Invoke-Captured $entryFile @(".alive", "--dry-run") 0 "alive logon dry-run"
        Assert-True ($aliveLogonDryRunOutput.Contains("current-user logon")) "bare alive dry-run should configure logon auto-start."
        Assert-True ($aliveLogonDryRunOutput.Contains("while :; do sleep 3600; done")) "bare alive dry-run should use a logon keep-alive loop."

        $aliveStatusOutput = Invoke-Captured $entryFile @(".alive", "status") 0 "alive status"
        Assert-True ($aliveStatusOutput.Contains("WSL alive: wsl01")) "alive status should show heading."
        Assert-True ($aliveStatusOutput.Contains("Alive task:")) "alive status should show the scheduled task name."
        Assert-True ($aliveStatusOutput.Contains("Alive setting:")) "alive status should show the configured mode."
        Assert-True ($aliveStatusOutput.Contains("Task State:")) "alive status should show the scheduled task state."

        $aliveInvalidDurationOutput = Invoke-Captured $entryFile @(".alive", "auto") 1 "reject non-numeric alive duration"
        Assert-True ($aliveInvalidDurationOutput.Contains("duration must be an integer")) "non-numeric alive duration should be rejected."

        $aliveOffOutput = Invoke-Captured $entryFile @(".alive", "off", "--dry-run") 0 "alive off dry-run"
        Assert-True ($aliveOffOutput.Contains("Would disable all WSL alive settings")) "alive off dry-run should report disabled."

        $target = Join-Path $tempRoot "out.tar"
        Invoke-Checked $entryFile @(".backup", $target) 0 "backup explicit path fixed format"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--export", "wsl01", ([System.IO.Path]::GetFullPath($target)), "--format", "tar") "backup explicit path fixed format"

        Invoke-Checked $entryFile @(".backup", "--format", "tar.gz") 1 "reject inline backup format"
        Invoke-Checked $entryFile @(".backup", $target, "extra") 1 "reject backup extra explicit args"
        $restoreName = "wsl.smoke-restore-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $restoreInstallDir = Join-Path $tempRoot "restore-install"
        $restoreBackupDir = Join-Path $tempRoot "restore-backup"
        $restoreEntryFile = New-WslSmokeEntryFile -Name $restoreName -InstallDir $restoreInstallDir -BackupDir $restoreBackupDir -User ""
        New-Item -ItemType Directory -Path $restoreBackupDir -Force | Out-Null

        $backupOutput = Invoke-Captured $restoreEntryFile @(".backup") 0 "backup output path"
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

        $backupListOutput = Invoke-Captured $restoreEntryFile @(".backup", "list") 0 "backup list"
        Assert-True ($backupListOutput.Contains("WSL backups: $restoreName")) "backup list should show the entry name."
        Assert-True ($backupListOutput.Contains((Split-Path -Leaf $restoreArchive))) "backup list should show tar archives. Output: $backupListOutput"
        Assert-True ($backupListOutput.Contains((Split-Path -Leaf $restoreVhd))) "backup list should show vhdx archives. Output: $backupListOutput"
        Invoke-Checked $restoreEntryFile @(".backup", "list", "extra") 1 "reject backup list extra args"
        Invoke-Checked $restoreEntryFile @(".install", (Join-Path $restoreBackupDir "missing.tar")) 1 "reject missing install archive"
        $invalidInstallPathOutput = Invoke-Captured $restoreEntryFile @(".install", ":\not-supported.tar") 1 "reject invalid install archive path"
        Assert-True ($invalidInstallPathOutput.Contains("Invalid install archive path")) "invalid install archive path should be reported without a PowerShell exception. Output: $invalidInstallPathOutput"
        Assert-True (-not $invalidInstallPathOutput.Contains("Exception calling")) "invalid install archive path should not leak a raw .NET exception. Output: $invalidInstallPathOutput"

        Invoke-Checked $restoreEntryFile @(".install", (Split-Path -Leaf $restoreArchive)) 0 "install from backup basename"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--import", $restoreName, ([System.IO.Path]::GetFullPath($restoreInstallDir)), ([System.IO.Path]::GetFullPath($restoreArchive)), "--version", "2") "install archive import args"

        $installVhdDryRun = Invoke-Captured $restoreEntryFile @(".install", $restoreVhd, "--dry-run") 0 "install vhd dry-run"
        Assert-True ($installVhdDryRun.Contains("--vhd")) "install vhd dry-run should pass --vhd."

        $vmStatusOutput = Invoke-Captured $entryFile @(".vm", "status") 0 "vm status"
        Assert-True ($vmStatusOutput.Contains("WSL VM: current Windows user")) "vm status should show the VM status heading."
        Assert-True ($vmStatusOutput.Contains("Networking mode:")) "vm status should show networking mode."
        $vmAliveListOutput = Invoke-Captured $entryFile @(".vm", "alive") 0 "vm alive"
        Assert-True ($vmAliveListOutput.Contains("WSL alive tasks: current Windows user")) "vm alive should show heading."
        Invoke-Checked $entryFile @(".vm", "alive", "extra") 1 "reject unknown vm alive command"
        Invoke-Checked $entryFile @(".vm", "alive", "del", "wsl01") 1 "reject guessed vm alive task name"
        Invoke-Checked $entryFile @(".vm", "alive", "del", "alive_missing") 1 "reject missing vm alive task"
        $vmPortOutput = Invoke-Captured $entryFile @(".vm", "port") 0 "vm port"
        Assert-True ($vmPortOutput.Contains("WSL port rules: current Windows user")) "vm port should show heading."
        Invoke-Checked $entryFile @(".vm", "port", "del", "wsl_instance_kit-missing-port-tcp-0.0.0.0-65535") 1 "reject missing vm port rule"
        Invoke-Checked $entryFile @(".vm", "port", "extra") 1 "reject unknown vm port command"
        Invoke-Checked $entryFile @(".vm", "status", "extra") 1 "reject vm status extra args"
        Invoke-Checked $entryFile @(".vm", "show", "extra") 1 "reject vm show extra args"
        Invoke-Checked $entryFile @(".vm", "default", "extra") 1 "reject vm default extra args"
        Invoke-Checked $entryFile @(".vm", "-s", "extra") 1 "reject vm -s extra args"
        Invoke-Checked $entryFile @(".vm", "config") 1 "reject unknown vm command"

        $archivePath = Join-Path $tempRoot "source.tar"
        [System.IO.File]::WriteAllBytes($archivePath, [byte[]](7, 8, 9))
        $archiveName = "wsl.smoke-archive-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $archiveInstallDir = Join-Path $tempRoot "archive-install"
        $archiveEntryFile = New-WslSmokeEntryFile -Name $archiveName -Source $archivePath -InstallDir $archiveInstallDir -BackupDir (Join-Path $tempRoot "archive-backup") -User ""
        $env:MOCK_WSL_EXIT_CODE = "9"
        Invoke-Checked $archiveEntryFile @(".install") 9 "archive install failure preserves exit code"
        $env:MOCK_WSL_EXIT_CODE = $null

        $unknownSourceName = "wsl.smoke-unknown-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $unknownSourceEntryFile = New-WslSmokeEntryFile -Name $unknownSourceName -Source "NoSuchSmokeDistro" -InstallDir (Join-Path $tempRoot "unknown-install") -BackupDir (Join-Path $tempRoot "unknown-backup") -User ""
        $env:MOCK_WSL_EXIT_CODE = "9"
        $autoFallbackOutput = Invoke-Captured $unknownSourceEntryFile @(".install") 1 "online install failure tries fallback"
        Assert-True ($autoFallbackOutput.Contains("Trying fallback install")) "online install failure should automatically try fallback."
        Assert-True ($autoFallbackOutput.Contains("Distribution not found in DistributionInfo")) "unknown online source should fail inside fallback lookup."
        $env:MOCK_WSL_EXIT_CODE = $null

        $systemdEnableOutput = Invoke-Captured $entryFile @(".systemd", "enable") 0 "systemd enable success message"
        Assert-True ($systemdEnableOutput.Contains("Systemd enabled in /etc/wsl.conf.")) "systemd enable should print success."
        Assert-True ($systemdEnableOutput.Contains("wsl01 .vm -s")) "systemd enable should suggest restart command."
        Invoke-Checked $entryFile @(".sshd", "enable") 1 "reject ssh enable without port"
        Invoke-Checked $entryFile @(".sshd", "enable", "abc") 1 "reject non-numeric ssh port"
        Invoke-Checked $entryFile @(".sshd", "enable", "2222", "extra") 1 "reject ssh enable extra args"
        $env:MOCK_WSL_EXIT_CODE = "1"
        Invoke-Checked $entryFile @(".sshd", "enable", "2222") 1 "reject ssh enable without active systemd"
        $env:MOCK_WSL_EXIT_CODE = $null

        $sshEnableCase = New-SshEnableTestEntryFile $tempRoot
        $sshEnableEntryFile = $sshEnableCase.EntryFile
        $sshEnablePort = [string]$sshEnableCase.Port
        Invoke-Checked $sshEnableEntryFile @(".sshd", "enable", $sshEnablePort) 0 "ssh enable script generation"
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
            Invoke-Checked $entryFile @(".sshd", "status") 0 "ssh status"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "ssh status root script prefix"
            Assert-True ($actual.Count -eq 8) "ssh status should pass a single shell runner."

            Invoke-Checked $entryFile @(".status", "sshd") 0 "status sshd"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "status sshd root script prefix"
            Assert-True ($actual.Count -eq 8) "status sshd should pass a single shell runner."

            Invoke-Checked $entryFile @(".status", "systemd") 0 "status systemd"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "status systemd root script prefix"
            Assert-True ($actual.Count -eq 8) "status systemd should pass a single shell runner."

            Invoke-Checked $entryFile @(".systemd", "status") 0 "systemd status"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl01", "-u", "root", "--", "sh", "-lc") "systemd status root script prefix"
            Assert-True ($actual.Count -eq 8) "systemd status should pass a single shell runner."
        } else {
            Write-Host "ssh/systemd status skipped: wsl01 is not installed" -ForegroundColor Yellow
        }
    } finally {
        $env:PATH = $oldPath
        $env:APPDATA = $oldAppData
        $env:MOCK_WSL_ARGS_PATH = $oldArgsPath
        $env:MOCK_WSL_COMMAND_LINE_PATH = $oldCommandLinePath
        $env:MOCK_WSL_EXIT_CODE = $oldExitCode
        if ($sshEnableEntryFile -and (Test-Path -LiteralPath $sshEnableEntryFile)) {
            Remove-Item -LiteralPath $sshEnableEntryFile -Force
        }
        if ($restoreEntryFile -and (Test-Path -LiteralPath $restoreEntryFile)) {
            Remove-Item -LiteralPath $restoreEntryFile -Force
        }
        if ($archiveEntryFile -and (Test-Path -LiteralPath $archiveEntryFile)) {
            Remove-Item -LiteralPath $archiveEntryFile -Force
        }
        if ($unknownSourceEntryFile -and (Test-Path -LiteralPath $unknownSourceEntryFile)) {
            Remove-Item -LiteralPath $unknownSourceEntryFile -Force
        }
        if ($fastPathEntryFile -and (Test-Path -LiteralPath $fastPathEntryFile)) {
            Remove-Item -LiteralPath $fastPathEntryFile -Force
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    Write-Host "smoke ok" -ForegroundColor Green
} finally {
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $smokeUserProfileRoot) {
        Remove-Item -LiteralPath $smokeUserProfileRoot -Recurse -Force
    }
    Pop-Location
}

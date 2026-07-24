$ErrorActionPreference = "Stop"

$script:EditorRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$script:EditorKitRoot = Join-Path $script:EditorRepoRoot "_lib\ssh_remote_kit"
$script:EditorEntry = Join-Path $script:EditorRepoRoot "vps1.cmd"
$script:EditorKitCmd = Join-Path $script:EditorKitRoot "kit.cmd"
$script:EditorLaunch = Join-Path $script:EditorKitRoot "editor-launch.ps1"

function Assert-EditorTrue {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-EditorContains {
    param(
        [string]$Text,
        [string]$Expected,
        [string]$Message
    )

    Assert-EditorTrue $Text.Contains($Expected) $Message
}

function Assert-EditorArray {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Message
    )

    Assert-EditorTrue ($Actual.Count -eq $Expected.Count) "$Message Expected $($Expected.Count) args, got $($Actual.Count)."
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-EditorTrue ($Actual[$index] -eq $Expected[$index]) "$Message Difference at index $index."
    }
}

function Set-EditorEnvironmentValue {
    param(
        [string]$Name,
        [AllowNull()] [string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
}

function Invoke-EditorCommand {
    param(
        [string]$File,
        [string[]]$Arguments,
        [int]$ExpectedExitCode,
        [string]$Label
    )

    $output = (& $File @Arguments 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    Assert-EditorTrue ($exitCode -eq $ExpectedExitCode) "$Label expected exit code $ExpectedExitCode, got $exitCode.`n$output"
    return $output
}

function Test-RemoteEditorArgumentContract {
    . $script:EditorLaunch -Tool code

    Assert-EditorArray `
        @(Get-RemoteKitEditorLaunchArguments `
            -Editor code `
            -EditorTarget "/var/www" `
            -EditorRemoteAuthority "ssh-remote+root@example.invalid:22") `
        @("--remote=ssh-remote+root@example.invalid:22", "/var/www") `
        "VS Code Remote-SSH arguments are incorrect."

    Assert-EditorArray `
        @(Get-RemoteKitEditorLaunchArguments `
            -Editor code `
            -EditorTarget "/var/www" `
            -EditorRemoteAuthority "ssh-remote+root@example.invalid:22" `
            -ReuseWindow) `
        @("--reuse-window", "--remote=ssh-remote+root@example.invalid:22", "/var/www") `
        "bootstrapped VS Code Remote-SSH arguments are incorrect."

    Assert-EditorArray `
        @(Get-RemoteKitEditorLaunchArguments `
            -Editor cursor `
            -EditorTarget "/srv/app" `
            -EditorRemoteAuthority "ssh-remote+root@example.invalid:22") `
        @("--classic", "--remote=ssh-remote+root@example.invalid:22", "/srv/app") `
        "Cursor Remote-SSH arguments are incorrect."

    Assert-EditorArray `
        @(Get-RemoteKitEditorLaunchArguments `
            -Editor cursor `
            -EditorTarget "C:\workspace" `
            -ReuseWindow) `
        @("--classic", "--reuse-window", "C:\workspace") `
        "bootstrapped Cursor SFTP workspace arguments are incorrect."
}

function Test-RemoteEditorEntryContract {
    $content = [System.IO.File]::ReadAllText($script:EditorEntry)
    $bootstrapIndex = $content.IndexOf(
        "_lib\editor_kit\entry-bootstrap.cmd",
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $protocolIndex = $content.IndexOf(
        'set "REMOTE_KIT_PROTOCOL=2"',
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $configIndex = $content.IndexOf(
        "Host ___self___",
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $runtimeIndex = $content.IndexOf(
        'set "REMOTE_KIT_ENTRY_FILE=',
        [System.StringComparison]::OrdinalIgnoreCase
    )

    Assert-EditorTrue ($bootstrapIndex -ge 0) "vps1.cmd should call the shared editor bootstrap."
    Assert-EditorTrue ($protocolIndex -gt $bootstrapIndex) "Remote Kit protocol must be set after the clean bootstrap."
    Assert-EditorTrue ($configIndex -gt $protocolIndex) "embedded SSH configuration must follow the clean bootstrap."
    Assert-EditorTrue ($runtimeIndex -gt $configIndex) "Remote Kit runtime variables must follow the embedded SSH configuration."
    Assert-EditorContains $content '".%~1" "REMOTE_TARGET"' "vps1.cmd should map bare editor verbs and guard against inherited legacy state."
    Assert-EditorContains $content '"%REMOTE_KIT%" "0" "" "" "__REMOTE_KIT_SSH_CONFIG_IDENTITY__" %*' "vps1.cmd should tail-call the Remote Kit."
    Assert-EditorTrue (-not $content.Contains('call "%REMOTE_KIT%"')) "vps1.cmd must not CALL the Remote Kit and re-expand forwarded arguments."
}

function Test-RemoteEditorCmdLineEndings {
    foreach ($path in @($script:EditorEntry, $script:EditorKitCmd)) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 10) {
                Assert-EditorTrue `
                    ($index -gt 0 -and $bytes[$index - 1] -eq 13) `
                    "$path contains a bare LF line ending."
            }
        }
    }
}

function Test-RemoteEditorBootstrapFailure {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-editor-entry-" + [guid]::NewGuid().ToString("N"))
    $fakePowerShell = Join-Path $tempRoot "PowerShell.cmd"
    $fakePowerShellContent = @'
@echo off
echo BOOTSTRAP_PROTOCOL:%REMOTE_KIT_PROTOCOL%
echo BOOTSTRAP_ENTRY:%REMOTE_KIT_ENTRY_FILE%
echo BOOTSTRAP_TARGET:%REMOTE_TARGET%
exit /b 7
'@ -replace "`n", "`r`n"

    $previousPath = $env:PATH
    $previousProtocol = $env:REMOTE_KIT_PROTOCOL
    $previousEntry = $env:REMOTE_KIT_ENTRY_FILE
    $previousTarget = $env:REMOTE_TARGET
    try {
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        [System.IO.File]::WriteAllText(
            $fakePowerShell,
            $fakePowerShellContent,
            [System.Text.UTF8Encoding]::new($false)
        )

        $env:PATH = "$tempRoot;$previousPath"
        Set-EditorEnvironmentValue "REMOTE_KIT_PROTOCOL" $null
        Set-EditorEnvironmentValue "REMOTE_KIT_ENTRY_FILE" $null
        Set-EditorEnvironmentValue "REMOTE_TARGET" $null

        $output = Invoke-EditorCommand `
            $script:EditorEntry `
            @("code", "/var/www") `
            7 `
            "vps1 editor bootstrap failure"
        Assert-EditorContains $output "BOOTSTRAP_PROTOCOL:`r`n" "bootstrap must not inherit Remote Kit protocol."
        Assert-EditorContains $output "BOOTSTRAP_ENTRY:`r`n" "bootstrap must not inherit Remote Kit entry state."
        Assert-EditorContains $output "BOOTSTRAP_TARGET:`r`n" "bootstrap must not inherit resolved remote state."
    } finally {
        $env:PATH = $previousPath
        Set-EditorEnvironmentValue "REMOTE_KIT_PROTOCOL" $previousProtocol
        Set-EditorEnvironmentValue "REMOTE_KIT_ENTRY_FILE" $previousEntry
        Set-EditorEnvironmentValue "REMOTE_TARGET" $previousTarget
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-RemoteEditorFakeTools {
    param([string]$BinDir)

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $encoding = [System.Text.ASCIIEncoding]::new()
    [System.IO.File]::WriteAllText(
        (Join-Path $BinDir "ssh.cmd"),
        "@echo off`r`necho FAKE_SSH %*>>`"%REMOTE_EDITOR_LOG%`"`r`nexit /b 0`r`n",
        $encoding
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $BinDir "code.cmd"),
        "@echo off`r`necho CODE_BOOTSTRAP:%WIN_RUN_EDITOR_BOOTSTRAP%>>`"%REMOTE_EDITOR_LOG%`"`r`necho CODE_TARGET_BRIDGE:%WIN_RUN_REMOTE_EDITOR_TARGET%>>`"%REMOTE_EDITOR_LOG%`"`r`necho CODE_AUTHORITY_BRIDGE:%WIN_RUN_REMOTE_EDITOR_AUTHORITY%>>`"%REMOTE_EDITOR_LOG%`"`r`necho FAKE_CODE %*>>`"%REMOTE_EDITOR_LOG%`"`r`nexit /b 0`r`n",
        $encoding
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $BinDir "cursor.cmd"),
        "@echo off`r`nif /i `"%~1`"==`"--help`" (`r`n  if defined REMOTE_EDITOR_LEGACY_CURSOR (`r`n    echo   --new-window`r`n  ) else (`r`n    echo   --classic  Open the classic IDE`r`n  )`r`n  exit /b 0`r`n)`r`necho CURSOR_BOOTSTRAP:%WIN_RUN_EDITOR_BOOTSTRAP%>>`"%REMOTE_EDITOR_LOG%`"`r`necho FAKE_CURSOR %*>>`"%REMOTE_EDITOR_LOG%`"`r`nexit /b 0`r`n",
        $encoding
    )
}

function Test-RemoteEditorKitContract {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-editor-kit-" + [guid]::NewGuid().ToString("N"))
    $fakeBin = Join-Path $tempRoot "bin"
    $workspace = Join-Path $tempRoot "workspace"
    $log = Join-Path $tempRoot "editor.log"
    $directArgs = @("22", "example.invalid", "root", "C:\fake-key")

    $previousPath = $env:PATH
    $previousProtocol = $env:REMOTE_KIT_PROTOCOL
    $previousBootstrap = $env:WIN_RUN_EDITOR_BOOTSTRAP
    $previousLog = $env:REMOTE_EDITOR_LOG
    $previousLegacyCursor = $env:REMOTE_EDITOR_LEGACY_CURSOR
    try {
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
        Initialize-RemoteEditorFakeTools $fakeBin
        $env:PATH = "$fakeBin;$previousPath"
        $env:REMOTE_EDITOR_LOG = $log

        Set-EditorEnvironmentValue "REMOTE_KIT_PROTOCOL" $null
        Set-EditorEnvironmentValue "WIN_RUN_EDITOR_BOOTSTRAP" $null
        $output = Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("code", "/var/www")) `
            1 `
            "legacy Remote Kit editor guard"
        Assert-EditorContains $output "predates the clean editor bootstrap" "legacy editor rejection should explain the required entry upgrade."
        Assert-EditorTrue (-not (Test-Path -LiteralPath $log)) "legacy editor rejection must not invoke an editor."

        Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("cursor", "/var/www")) `
            1 `
            "legacy Remote Kit Cursor guard" | Out-Null
        Assert-EditorTrue (-not (Test-Path -LiteralPath $log)) "legacy Cursor rejection must not invoke an editor."

        Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("--", "echo", "OK")) `
            0 `
            "legacy Remote Kit non-editor compatibility" | Out-Null
        Assert-EditorContains ([System.IO.File]::ReadAllText($log)) "FAKE_SSH" "legacy non-editor commands should remain supported."
        Remove-Item -LiteralPath $log -Force

        $env:REMOTE_KIT_PROTOCOL = "2"
        $env:WIN_RUN_EDITOR_BOOTSTRAP = "code"
        Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("code", "/var/www")) `
            0 `
            "bootstrapped VS Code Remote-SSH" | Out-Null
        $logText = [System.IO.File]::ReadAllText($log)
        Assert-EditorContains $logText "CODE_BOOTSTRAP:`r`n" "the internal bootstrap marker must be consumed before editor launch."
        Assert-EditorContains $logText "CODE_TARGET_BRIDGE:`r`n" "the target bridge must be consumed before editor launch."
        Assert-EditorContains $logText "CODE_AUTHORITY_BRIDGE:`r`n" "the authority bridge must be consumed before editor launch."
        Assert-EditorContains $logText "FAKE_CODE --reuse-window --remote=ssh-remote+root@example.invalid:22 /var/www" "VS Code Remote-SSH should reuse the clean bootstrap window."
        Remove-Item -LiteralPath $log -Force

        Set-EditorEnvironmentValue "WIN_RUN_EDITOR_BOOTSTRAP" $null
        Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("cursor", "/srv/app")) `
            0 `
            "existing Cursor Remote-SSH" | Out-Null
        $logText = [System.IO.File]::ReadAllText($log)
        Assert-EditorContains $logText "FAKE_CURSOR --classic --remote=ssh-remote+root@example.invalid:22 /srv/app" "Cursor Remote-SSH should force the classic IDE."
        Remove-Item -LiteralPath $log -Force

        $env:WIN_RUN_EDITOR_BOOTSTRAP = "cursor"
        Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("cursor", ":/var/www", $workspace)) `
            0 `
            "bootstrapped Cursor SFTP workspace" | Out-Null
        $logText = [System.IO.File]::ReadAllText($log)
        Assert-EditorContains $logText "CURSOR_BOOTSTRAP:`r`n" "the Cursor bootstrap marker must be consumed before editor launch."
        Assert-EditorContains $logText "FAKE_CURSOR --classic --reuse-window $workspace" "Cursor SFTP mode should reuse the clean classic IDE window."
        Assert-EditorTrue (-not $logText.Contains("--remote=")) "SFTP workspace launch must not use Remote-SSH arguments."
        Remove-Item -LiteralPath $log -Force

        Set-EditorEnvironmentValue "WIN_RUN_EDITOR_BOOTSTRAP" $null
        $env:REMOTE_EDITOR_LEGACY_CURSOR = "1"
        $output = Invoke-EditorCommand `
            $script:EditorKitCmd `
            ($directArgs + @("cursor", "/legacy")) `
            1 `
            "legacy Cursor capability guard"
        Assert-EditorContains $output "requires the '--classic' CLI option" "unsupported Cursor rejection should explain the missing capability."
        Assert-EditorTrue (-not (Test-Path -LiteralPath $log)) "unsupported Cursor must be rejected before target launch."
    } finally {
        $env:PATH = $previousPath
        Set-EditorEnvironmentValue "REMOTE_KIT_PROTOCOL" $previousProtocol
        Set-EditorEnvironmentValue "WIN_RUN_EDITOR_BOOTSTRAP" $previousBootstrap
        Set-EditorEnvironmentValue "REMOTE_EDITOR_LOG" $previousLog
        Set-EditorEnvironmentValue "REMOTE_EDITOR_LEGACY_CURSOR" $previousLegacyCursor
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-RemoteEditorArgumentContract
Test-RemoteEditorEntryContract
Test-RemoteEditorCmdLineEndings
Test-RemoteEditorBootstrapFailure
Test-RemoteEditorKitContract
Write-Host "ssh remote kit editor smoke ok" -ForegroundColor Green

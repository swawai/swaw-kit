[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryFile = Join-Path $repoRoot "wsl.1.cmd"
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

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function New-SshEnableTestEntryFile {
    param([string]$TempRoot)

    $publicKeyPath = Join-Path $TempRoot "id_wslkit_smoke.pub"
    $publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZha2VLZXlGb3JTbW9rZVRlc3RPbmx5 wsl-kit-smoke"
    [System.IO.File]::WriteAllText($publicKeyPath, "$publicKey`r`n", [System.Text.UTF8Encoding]::new($false))

    $entryPath = Join-Path $repoRoot ("wsl.smoke-" + [guid]::NewGuid().ToString("N") + ".cmd")
    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = [regex]::Replace($content, '(?m)^set "WSL_systemd=.*"\r?$', 'set "WSL_systemd=enable"')
    $content = [regex]::Replace($content, '(?m)^set "WSL_SSH_port=.*"\r?$', ('set "WSL_SSH_port={0}"' -f (Get-FreeTcpPort)))
    $sshKeyLine = 'set "WSL_SSH_key=' + $publicKeyPath + '"'
    $content = [regex]::Replace($content, '(?m)^set "WSL_SSH_key=.*"\r?$', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $sshKeyLine })
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($entryPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $entryPath
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

    Write-Host "basic commands"
    Invoke-Checked $entryFile @("-h") 0 "entry help"
    Invoke-Checked $entryFile @("status") 0 "entry status"
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
    $oldArgsPath = $env:MOCK_WSL_ARGS_PATH
    $oldExitCode = $env:MOCK_WSL_EXIT_CODE
    $sshEnableEntryFile = $null

    try {
        $shimDir = New-MockWsl $tempRoot
        $env:PATH = "$shimDir;$oldPath"
        $env:MOCK_WSL_ARGS_PATH = $argsFile

        $cmdLine = 'call "{0}" alpha "" "two words" omega' -f $entryFile
        & cmd.exe /d /c $cmdLine
        Assert-ExitCode $LASTEXITCODE 0 "passthrough empty arg"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("-d", "wsl.1", "-u", "john", "--cd", "~", "alpha", "", "two words", "omega") "passthrough empty arg"

        $target = Join-Path $tempRoot "out.tar"
        Invoke-Checked $entryFile @("ctl", "export", $target) 0 "export fixed format"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual $actual @("--export", "wsl.1", ([System.IO.Path]::GetFullPath($target)), "--format", "tar") "export fixed format"

        Invoke-Checked $entryFile @("ctl", "export", "--format", "tar.gz", $target) 1 "reject inline export format"
        Invoke-Checked $entryFile @("ctl", "backup", "--format", "tar.gz") 1 "reject inline backup format"

        $env:MOCK_WSL_EXIT_CODE = "9"
        Invoke-Checked $entryFile @("ctl", "install") 9 "native install failure preserves exit code"
        $env:MOCK_WSL_EXIT_CODE = $null

        Invoke-Checked $entryFile @("ctl", "install", "--fallback", "--dry-run") 0 "fallback dry-run"
        Invoke-Checked $entryFile @("ctl", "install", "--fallback", "--refresh", "--dry-run") 1 "reject removed fallback refresh"
        Invoke-Checked $entryFile @("ctl", "ssh", "enable") 1 "reject ssh enable without systemd entry config"
        Invoke-Checked $entryFile @("ctl", "ssh", "enable", "2222") 1 "reject ssh enable without systemd entry config"

        $sshEnableEntryFile = New-SshEnableTestEntryFile $tempRoot
        Invoke-Checked $sshEnableEntryFile @("ctl", "ssh", "enable") 0 "ssh enable script generation"
        $actual = Read-MockWslArgs $argsFile
        Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl.1", "-u", "root", "--", "sh", "-lc") "ssh enable root script prefix"
        Assert-True ($actual.Count -eq 8) "ssh enable should pass a single shell runner."
        $enableScript = Decode-Base64ShRunner $actual[7]
        Assert-True ($enableScript.Contains("dnf install -y openssh-server")) "ssh enable script should support dnf."
        Assert-True ($enableScript.Contains("yum install -y openssh-server")) "ssh enable script should support yum."
        Assert-True ($enableScript.Contains("microdnf install -y openssh-server")) "ssh enable script should support microdnf."
        Assert-True ($enableScript.Contains("ssh-keygen -A")) "ssh enable script should generate host keys."

        if (Test-WslDistributionExists "wsl.1") {
            Invoke-Checked $entryFile @("ctl", "ssh", "status") 0 "ssh status"
            $actual = Read-MockWslArgs $argsFile
            Assert-ArrayEqual @($actual[0..6]) @("-d", "wsl.1", "-u", "root", "--", "sh", "-lc") "ssh status root script prefix"
            Assert-True ($actual.Count -eq 8) "ssh status should pass a single shell runner."
        } else {
            Write-Host "ssh status skipped: wsl.1 is not installed" -ForegroundColor Yellow
        }
    } finally {
        $env:PATH = $oldPath
        $env:MOCK_WSL_ARGS_PATH = $oldArgsPath
        $env:MOCK_WSL_EXIT_CODE = $oldExitCode
        if ($sshEnableEntryFile -and (Test-Path -LiteralPath $sshEnableEntryFile)) {
            Remove-Item -LiteralPath $sshEnableEntryFile -Force
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    Write-Host "smoke ok" -ForegroundColor Green
} finally {
    Pop-Location
}

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

        var commandLinePath = Environment.GetEnvironmentVariable("MOCK_WSL_COMMAND_LINE_PATH");
        if (!string.IsNullOrWhiteSpace(commandLinePath))
        {
            File.WriteAllText(commandLinePath, Environment.CommandLine);
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

function Add-FailingPowerShellShim {
    param(
        [string]$ShimDir,
        [string]$MarkerPath
    )

    $script = @"
@echo off
echo PowerShell fallback invoked>"$MarkerPath"
exit /b 77
"@
    [System.IO.File]::WriteAllText((Join-Path $ShimDir "PowerShell.cmd"), $script, [System.Text.UTF8Encoding]::new($false))
}

function Remove-PowerShellShim {
    param([string]$ShimDir)

    Remove-Item -LiteralPath (Join-Path $ShimDir "PowerShell.cmd") -Force -ErrorAction SilentlyContinue
}

function Assert-MockWslNotCalled {
    param(
        [string]$Path,
        [string]$Label
    )

    Assert-True (-not (Test-Path -LiteralPath $Path)) "$Label should not call wsl.exe."
}

function New-MockWsl {
    param([string]$TempRoot)

    $projectDir = Join-Path $TempRoot "MockWsl"
    $publishDir = Join-Path $TempRoot "publish"
    $shimDir = Join-Path $TempRoot "shim"
    $dotnetHome = Join-Path $TempRoot "dotnet-home"
    $nugetHome = Join-Path $TempRoot "nuget-home"
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
    New-Item -ItemType Directory -Path $dotnetHome -Force | Out-Null
    New-Item -ItemType Directory -Path $nugetHome -Force | Out-Null

    $oldDotnetCliHome = $env:DOTNET_CLI_HOME
    $oldNuGetCliHome = $env:NUGET_CLI_HOME
    $oldNuGetPackages = $env:NUGET_PACKAGES
    $oldNuGetHttpCachePath = $env:NUGET_HTTP_CACHE_PATH
    $oldNuGetPluginsCachePath = $env:NUGET_PLUGINS_CACHE_PATH
    $oldAppData = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    $oldUserProfile = $env:USERPROFILE

    try {
        $env:DOTNET_CLI_HOME = $dotnetHome
        $env:NUGET_CLI_HOME = $nugetHome
        $env:NUGET_PACKAGES = Join-Path $nugetHome "packages"
        $env:NUGET_HTTP_CACHE_PATH = Join-Path $nugetHome "http-cache"
        $env:NUGET_PLUGINS_CACHE_PATH = Join-Path $nugetHome "plugins-cache"
        $env:APPDATA = Join-Path $dotnetHome "appdata"
        $env:LOCALAPPDATA = Join-Path $dotnetHome "localappdata"
        $env:USERPROFILE = $dotnetHome
        New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null

        Push-Location $TempRoot
        try {
            dotnet new console --use-program-main --name MockWsl --output $projectDir | Out-Null
        } finally {
            Pop-Location
        }
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

        var stdinPath = Environment.GetEnvironmentVariable("MOCK_WSL_STDIN_PATH");
        var stdinBytesPath = Environment.GetEnvironmentVariable("MOCK_WSL_STDIN_BYTES_PATH");
        if (!string.IsNullOrWhiteSpace(stdinPath) || !string.IsNullOrWhiteSpace(stdinBytesPath))
        {
            using var stdin = Console.OpenStandardInput();
            using var memory = new MemoryStream();
            stdin.CopyTo(memory);
            var bytes = memory.ToArray();
            if (!string.IsNullOrWhiteSpace(stdinPath))
            {
                File.WriteAllText(stdinPath, Encoding.UTF8.GetString(bytes), new UTF8Encoding(false));
            }
            if (!string.IsNullOrWhiteSpace(stdinBytesPath))
            {
                File.WriteAllText(stdinBytesPath, Convert.ToBase64String(bytes), new UTF8Encoding(false));
            }
        }

        var exitCodeText = Environment.GetEnvironmentVariable("MOCK_WSL_EXIT_CODE");
        return int.TryParse(exitCodeText, out var exitCode) ? exitCode : 0;
    }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $projectDir "Program.cs"), $program, [System.Text.UTF8Encoding]::new($false))
        Push-Location $TempRoot
        try {
            dotnet publish $projectDir -c Release -r win-x64 --self-contained false -o $publishDir | Out-Null
        } finally {
            Pop-Location
        }
    } finally {
        $env:DOTNET_CLI_HOME = $oldDotnetCliHome
        $env:NUGET_CLI_HOME = $oldNuGetCliHome
        $env:NUGET_PACKAGES = $oldNuGetPackages
        $env:NUGET_HTTP_CACHE_PATH = $oldNuGetHttpCachePath
        $env:NUGET_PLUGINS_CACHE_PATH = $oldNuGetPluginsCachePath
        $env:APPDATA = $oldAppData
        $env:LOCALAPPDATA = $oldLocalAppData
        $env:USERPROFILE = $oldUserProfile
    }

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

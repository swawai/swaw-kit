[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tool,

    [switch]$DropFirst,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

function Resolve-GitBash {
    $candidates = @()
    $git = Get-Command "git.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $directory = Split-Path $git.Source -Parent
        for ($i = 0; $i -lt 4 -and $directory; $i++) {
            $candidates += Join-Path $directory "git-bash.exe"
            $parent = Split-Path $directory -Parent
            if ($parent -eq $directory) {
                break
            }
            $directory = $parent
        }
    }

    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles "Git\git-bash.exe"
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "Git\git-bash.exe"
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA "Programs\Git\git-bash.exe"
    }

    $match = $candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $match) {
        throw "Git Bash was not found. Install Git for Windows or repair its installation."
    }
    return [IO.Path]::GetFullPath($match)
}

if ($DropFirst -and $RemainingArgs.Count -gt 0) {
    $RemainingArgs = @($RemainingArgs | Select-Object -Skip 1)
}

$exe = $Tool
$toolArgs = @($RemainingArgs)

switch ($Tool.ToLowerInvariant()) {
    "cmd" {
        $exe = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
        if ($toolArgs.Count -eq 0) {
            $toolArgs = @("/K")
        }
    }
    "powershell" {
        $exe = "powershell.exe"
        if ($toolArgs.Count -eq 0) {
            $toolArgs = @("-NoExit")
        }
    }
    "pwsh" {
        $exe = "pwsh"
        if ($toolArgs.Count -eq 0) {
            $toolArgs = @("-NoExit")
        }
    }
    "gitbash" {
        $exe = Resolve-GitBash
    }
}

try {
    & $exe @toolArgs
    if ($null -ne $global:LASTEXITCODE) {
        exit $global:LASTEXITCODE
    }

    exit 0
} catch {
    Write-Host "[ERROR] Failed to launch ${Tool}: $($_.Exception.Message)"
    exit 1
}

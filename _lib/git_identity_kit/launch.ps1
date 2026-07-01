[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tool,

    [switch]$DropFirst,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

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
    "ps" {
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

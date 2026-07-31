[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\data-root-claim.ps1')

function Assert-ProjClaimTimeoutTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$Stopwatch = [Diagnostics.Stopwatch]::StartNew()
$TimedOutAnswer = Read-ProjTimedClaimAnswerCore `
    -Prompt 'Automated no-input claim check' `
    -TimeoutSeconds 1 `
    -ReadKey { return $null } 6>$null
$Stopwatch.Stop()
Assert-ProjClaimTimeoutTest `
    -Condition ($null -eq $TimedOutAnswer -and
        $Stopwatch.Elapsed.TotalSeconds -ge 0.8 -and
        $Stopwatch.Elapsed.TotalSeconds -lt 3) `
    -Message 'the no-input claim did not honor its deadline'

$Keys = [Collections.Queue]::new()
$Keys.Enqueue([ConsoleKeyInfo]::new(
    'x',
    [ConsoleKey]::X,
    $false,
    $false,
    $false
))
$Keys.Enqueue([ConsoleKeyInfo]::new(
    "`r",
    [ConsoleKey]::Enter,
    $false,
    $false,
    $false
))
$Answered = Read-ProjTimedClaimAnswerCore `
    -Prompt 'Automated answered claim check' `
    -TimeoutSeconds 1 `
    -ReadKey {
        if ($Keys.Count -eq 0) {
            return $null
        }
        return $Keys.Dequeue()
    } 6>$null
Assert-ProjClaimTimeoutTest `
    -Condition ([string]$Answered -ceq 'x') `
    -Message 'the claim reader did not return immediately after Enter'

Write-Host '[PASS] Proj claim confirmation deadline' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
